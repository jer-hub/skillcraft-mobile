import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skillcraft/models/model_download.dart';

/// Serves [data] with Range support behind one redirect, like Hugging Face.
class _Server {
  _Server(this.data);

  final Uint8List data;
  late HttpServer _http;

  /// Drop the connection after this many bytes of a response.
  int? cutAfter;
  bool ignoreRange = false;
  int status = 200;
  final ranges = <String?>[];

  Uri get url => Uri.parse('http://127.0.0.1:${_http.port}/resolve/model.gguf');

  Future<void> start() async {
    _http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _http.listen((req) async {
      final res = req.response;
      if (req.uri.path.startsWith('/resolve/')) {
        res.statusCode = HttpStatus.found;
        res.headers.set(HttpHeaders.locationHeader, '/cdn/model.gguf?signed=1');
        await res.close();
        return;
      }
      if (status != 200) {
        res.statusCode = status;
        await res.close();
        return;
      }
      final range = req.headers.value(HttpHeaders.rangeHeader);
      ranges.add(range);
      var from = 0;
      if (range != null && !ignoreRange) {
        from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
        res.statusCode = HttpStatus.partialContent;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $from-${data.length - 1}/${data.length}');
      }
      res.contentLength = data.length - from;
      final cut = cutAfter;
      if (cut != null) {
        // Promise the whole file, send part of it, then drop the connection.
        final socket = await res.detachSocket();
        socket.add(data.sublist(from, from + cut));
        await socket.flush();
        socket.destroy();
        return;
      }
      for (var i = from; i < data.length; i += 4096) {
        res.add(data.sublist(i, i + 4096 > data.length ? data.length : i + 4096));
        await res.flush();
        await Future<void>.delayed(Duration.zero);
      }
      await res.close();
    });
  }

  Future<void> close() => _http.close(force: true);
}

void main() {
  late Directory tmp;
  late _Server server;
  late File target;
  final data = Uint8List.fromList(List.generate(300000, (i) => (i * 31 + 7) & 0xff));
  final hash = sha256.convert(data).toString();

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('download_test');
    target = File('${tmp.path}/models/model.gguf');
    server = _Server(data);
    await server.start();
  });
  tearDown(() async {
    await server.close();
    tmp.deleteSync(recursive: true);
  });

  Future<DownloadResult> download({
    int free = 1 << 40,
    String? sha,
    DownloadControl? control,
    void Function(String, double)? onProgress,
  }) =>
      downloadFile(server.url, target,
          bytes: data.length,
          sha256: sha ?? hash,
          freeBytes: () async => free,
          control: control,
          onProgress: onProgress,
          stallTimeout: const Duration(seconds: 5));

  File part() => File('${target.path}.part');

  test('downloads through a redirect, verifies, and moves into place', () async {
    final stages = <String>{};
    final r = await download(onProgress: (s, _) => stages.add(s));

    expect(r, isA<DownloadDone>());
    expect(target.readAsBytesSync(), data);
    expect(part().existsSync(), isFalse);
    expect(stages, {'download', 'verify'});
    expect(server.ranges, [null], reason: 'nothing to resume');
  });

  test('a dropped connection keeps the partial file; the retry resumes with Range', () async {
    server.cutAfter = 100000;
    final first = await download();
    expect(first, isA<DownloadFailed>());
    final kept = part().lengthSync();
    expect(kept, inInclusiveRange(1, 100000), reason: 'what arrived before the drop is kept');

    server.cutAfter = null;
    final second = await download();
    expect(second, isA<DownloadDone>());
    expect(server.ranges.last, 'bytes=$kept-');
    expect(target.readAsBytesSync(), data);
  });

  test('a server that ignores Range starts over instead of corrupting the file', () async {
    part()
      ..createSync(recursive: true)
      ..writeAsBytesSync(data.sublist(0, 5000));
    server.ignoreRange = true;

    expect(await download(), isA<DownloadDone>());
    expect(target.readAsBytesSync(), data);
  });

  test('a checksum mismatch deletes the file', () async {
    final r = await download(sha: '0' * 64);
    expect(r, isA<DownloadFailed>());
    expect((r as DownloadFailed).reason, contains('checksum'));
    expect(part().existsSync(), isFalse);
    expect(target.existsSync(), isFalse);
  });

  test('not enough space fails before downloading anything', () async {
    final r = await download(free: data.length);
    expect((r as DownloadFailed).reason, contains('Not enough storage'));
    expect(server.ranges, isEmpty);
  });

  test('pause keeps the partial file; cancel deletes it', () async {
    final control = DownloadControl();
    final paused = await download(control: control, onProgress: (_, _) => control.pause());
    expect(paused, isA<DownloadStopped>());
    expect((paused as DownloadStopped).paused, isTrue);
    final kept = part().lengthSync();
    expect(kept, inExclusiveRange(0, data.length));

    final control2 = DownloadControl();
    final cancelled = await download(control: control2, onProgress: (_, _) => control2.cancel());
    expect((cancelled as DownloadStopped).paused, isFalse);
    expect(server.ranges.last, 'bytes=$kept-', reason: 'the second attempt resumed');
    expect(part().existsSync(), isFalse);
    expect(target.existsSync(), isFalse);
  });

  test('server errors are reported and keep what was downloaded', () async {
    part()
      ..createSync(recursive: true)
      ..writeAsBytesSync(data.sublist(0, 5000));
    server.status = 503;
    final r = await download();
    expect((r as DownloadFailed).reason, contains('503'));
    expect(part().lengthSync(), 5000);
  });
}
