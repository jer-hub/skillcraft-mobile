import 'dart:async';
import 'dart:io';

import 'model_manager.dart';

/// Outcome of a download.
sealed class DownloadResult {
  const DownloadResult();
}

final class DownloadDone extends DownloadResult {
  const DownloadDone(this.file);
  final File file;
}

/// Paused or cancelled by the user. After a pause the partial file stays,
/// so the next download resumes; after a cancel it is deleted.
final class DownloadStopped extends DownloadResult {
  const DownloadStopped({required this.paused});
  final bool paused;
}

/// The partial file is kept unless it was damaged, so a retry resumes.
final class DownloadFailed extends DownloadResult {
  const DownloadFailed(this.reason);
  final String reason;
}

/// Lets the UI pause or cancel a running download.
class DownloadControl {
  bool _paused = false;
  bool _cancelled = false;
  HttpClientRequest? _request;

  bool get stopped => _paused || _cancelled;

  void pause() => _stop(() => _paused = true);
  void cancel() => _stop(() => _cancelled = true);

  void _stop(void Function() mark) {
    mark();
    _request?.abort(); // wakes a stalled read at once
  }
}

/// Room kept free beyond the file itself, so the phone is not left full.
const downloadHeadroom = 200 << 20;

/// Downloads [url] into [target], resuming from `<target>.part` with an HTTP
/// Range request when one exists, then checks [bytes] and [sha256] before
/// moving it into place. [onProgress] gets ('download', fraction), then
/// ('verify', fraction). [freeBytes] reports free space in the target folder.
Future<DownloadResult> downloadFile(
  Uri url,
  File target, {
  required int bytes,
  required String sha256,
  required Future<int> Function() freeBytes,
  void Function(String stage, double fraction)? onProgress,
  DownloadControl? control,
  HttpClient? client,
  Duration stallTimeout = const Duration(seconds: 30),
}) async {
  control ??= DownloadControl();
  final part = File('${target.path}.part');
  await target.parent.create(recursive: true);
  var have = await part.exists() ? await part.length() : 0;
  if (have > bytes) {
    await part.delete();
    have = 0;
  }

  final free = await freeBytes();
  final needed = bytes - have + downloadHeadroom;
  if (free < needed) {
    return DownloadFailed('Not enough storage: needs ${_mb(needed)} MB free, '
        'the phone has ${_mb(free)} MB.');
  }

  final http = client ?? HttpClient();
  try {
    if (have < bytes) {
      final failure = await _fetch(http, url, part, have, bytes, control, stallTimeout, onProgress);
      if (control._cancelled) {
        if (await part.exists()) await part.delete();
        return const DownloadStopped(paused: false);
      }
      if (control._paused) return const DownloadStopped(paused: true);
      if (failure != null) return DownloadFailed(failure);
    }

    onProgress?.call('verify', 0);
    final ok = await part.length() == bytes &&
        await ModelManager.sha256Of(part, onProgress: (f) => onProgress?.call('verify', f)) ==
            sha256;
    if (!ok) {
      await part.delete();
      return const DownloadFailed('The download was damaged (checksum mismatch). Try again.');
    }
    if (await target.exists()) await target.delete();
    await part.rename(target.path);
    return DownloadDone(target);
  } finally {
    if (client == null) http.close(force: true);
  }
}

/// Appends the rest of the file to [part]. Returns an error message, or null
/// when it finished or was stopped through [control].
Future<String?> _fetch(HttpClient http, Uri url, File part, int have, int bytes,
    DownloadControl control, Duration stallTimeout, void Function(String, double)? onProgress) async {
  IOSink? sink;
  try {
    // Redirects are followed by hand so the Range header reaches the CDN.
    late HttpClientResponse response;
    var at = url;
    for (var hop = 0;; hop++) {
      final request = await http.getUrl(at);
      control._request = request;
      request.followRedirects = false;
      if (have > 0) request.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
      if (control.stopped) request.abort();
      response = await request.close().timeout(stallTimeout);
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (!response.isRedirect || location == null) break;
      await response.drain<void>();
      if (hop == 5) return 'Too many redirects.';
      at = at.resolve(location);
    }

    switch (response.statusCode) {
      case HttpStatus.partialContent:
        final range = response.headers.value(HttpHeaders.contentRangeHeader) ?? '';
        if (!range.startsWith('bytes $have-')) {
          await response.drain<void>();
          return 'The server resumed at the wrong place. Try again.';
        }
        sink = part.openWrite(mode: FileMode.append);
      case HttpStatus.ok:
        have = 0; // no resume support: start over
        sink = part.openWrite();
      case HttpStatus.requestedRangeNotSatisfiable when have == bytes:
        await response.drain<void>();
        return null;
      default:
        await response.drain<void>();
        return 'The server answered ${response.statusCode}. Try again later.';
    }

    var got = have;
    var reported = 0;
    final step = bytes ~/ 500 < 1 << 20 ? bytes ~/ 500 : 1 << 20; // 0.2% or 1 MB
    await for (final chunk in response.timeout(stallTimeout)) {
      if (control.stopped) break;
      sink.add(chunk);
      got += chunk.length;
      if (got - reported >= step || got == bytes) {
        reported = got;
        onProgress?.call('download', got / bytes);
      }
    }
    if (control.stopped) return null;
    if (got != bytes) return 'The connection ended early. Tap Resume to continue.';
    return null;
  } on TimeoutException {
    return 'The connection stalled. Tap Resume to continue.';
  } on HttpException catch (e) {
    return control.stopped ? null : 'Network error: ${e.message}. Tap Resume to continue.';
  } on SocketException catch (e) {
    return control.stopped ? null : 'No connection (${e.osError?.message ?? e.message}). '
        'Tap Resume to continue.';
  } on IOException catch (e) {
    return control.stopped ? null : 'Download failed: $e';
  } finally {
    control._request = null;
    await sink?.flush();
    await sink?.close();
  }
}

int _mb(int bytes) => (bytes / (1 << 20)).ceil();
