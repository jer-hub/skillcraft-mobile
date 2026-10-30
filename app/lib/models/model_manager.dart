import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../core/config.dart';
import '../core/device_services.dart';
import 'model_download.dart';

export 'model_download.dart' show DownloadControl, DownloadDone, DownloadFailed, DownloadResult, DownloadStopped;

enum ModelRole { chat, embedding }

/// A model file SkillCraft knows the exact bytes of.
class KnownModel {
  const KnownModel(this.role, this.fileName, this.bytes, this.sha256, this.label, this.url);

  final ModelRole role;

  /// Name it is stored under in the models folder.
  final String fileName;
  final int bytes;
  final String sha256;
  final String label;

  /// Pinned to a Hugging Face commit, so the bytes never change under [sha256].
  final String url;
}

/// Verified with the published Hugging Face hashes (2026-10-30). The URLs name
/// a commit rather than `main`, so they keep matching these hashes.
const knownModels = [
  KnownModel(ModelRole.chat, AppPaths.defaultModelFile, 1117320736,
      '6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e',
      'Qwen2.5 1.5B Instruct (Q4_K_M)',
      'https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/'
          '91cad51170dc346986eccefdc2dd33a9da36ead9/qwen2.5-1.5b-instruct-q4_k_m.gguf'),
  KnownModel(ModelRole.embedding, AppPaths.embeddingModelFile, 84106624,
      'd4e388894e09cf3816e8b0896d81d265b55e7a9fff9ab03fe8bf4ef5e11295ac',
      'nomic-embed-text v1.5 (Q4_K_M)',
      'https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/'
          '0188c9bf409793f810680a5a431e7b899c46104c/nomic-embed-text-v1.5.Q4_K_M.gguf'),
];

KnownModel knownFor(ModelRole role) => knownModels.firstWhere((m) => m.role == role);

/// Outcome of an import.
sealed class ImportResult {
  const ImportResult();
}

final class ImportCancelled extends ImportResult {
  const ImportCancelled();
}

final class ImportDone extends ImportResult {
  const ImportDone(this.file, {required this.verified});
  final File file;

  /// Bytes match the known model; false for other (but valid) GGUF files.
  final bool verified;
}

final class ImportRejected extends ImportResult {
  const ImportRejected(this.reason);
  final String reason;
}

/// Finds, imports and verifies model files in the app's models folder.
class ModelManager {
  ModelManager(this.dir, this._device);

  final Directory dir;
  final DeviceServices _device;

  File fileFor(ModelRole role) => File(p.join(dir.path, knownFor(role).fileName));

  File? installed(ModelRole role) {
    final f = fileFor(role);
    return f.existsSync() ? f : null;
  }

  /// Lets the user pick a file, streams it into place, and checks it.
  /// [onProgress] gets (stage, fraction) for 'copy' then 'verify'.
  Future<ImportResult> import(ModelRole role,
      {void Function(String stage, double fraction)? onProgress}) async {
    await dir.create(recursive: true);
    final target = fileFor(role);
    final staging = File('${target.path}.import');
    final sub = _device.importProgress.listen((e) {
      if (e.total > 0) onProgress?.call('copy', e.copied / e.total);
    });
    try {
      final picked = await _device.importDocument(staging.path);
      if (picked == null) return const ImportCancelled();

      if (!await isGguf(staging)) {
        await staging.delete();
        return ImportRejected('"${picked.name}" is not a GGUF model file');
      }
      onProgress?.call('verify', 0);
      final known = knownFor(role);
      final verified = picked.bytes == known.bytes &&
          await sha256Of(staging, onProgress: (f) => onProgress?.call('verify', f)) ==
              known.sha256;
      if (await target.exists()) await target.delete();
      await staging.rename(target.path);
      return ImportDone(target, verified: verified);
    } catch (e) {
      if (await staging.exists()) await staging.delete();
      return ImportRejected(e.toString());
    } finally {
      await sub.cancel();
    }
  }

  /// Downloads the known file for [role] (see [downloadFile]).
  Future<DownloadResult> download(ModelRole role,
      {void Function(String stage, double fraction)? onProgress, DownloadControl? control}) async {
    final known = knownFor(role);
    await dir.create(recursive: true);
    return downloadFile(Uri.parse(known.url), fileFor(role),
        bytes: known.bytes,
        sha256: known.sha256,
        freeBytes: () => _device.freeBytes(dir.path),
        onProgress: onProgress,
        control: control);
  }

  /// Bytes of an unfinished download for [role] (0 when there is none).
  int partialDownload(ModelRole role) {
    final part = File('${fileFor(role).path}.part');
    return part.existsSync() ? part.lengthSync() : 0;
  }

  Future<void> discardPartialDownload(ModelRole role) async {
    final part = File('${fileFor(role).path}.part');
    if (await part.exists()) await part.delete();
  }

  Future<void> remove(ModelRole role) async {
    final f = fileFor(role);
    if (await f.exists()) await f.delete();
  }

  /// GGUF files start with the ASCII magic "GGUF".
  static Future<bool> isGguf(File f) async {
    final raf = await f.open();
    try {
      final head = await raf.read(4);
      return head.length == 4 && String.fromCharCodes(head) == 'GGUF';
    } finally {
      await raf.close();
    }
  }

  /// SHA-256 on a background isolate; [onProgress] gets 0..1.
  static Future<String> sha256Of(File f, {void Function(double)? onProgress}) async {
    final progress = ReceivePort();
    final done = Completer<String>();
    progress.listen((m) {
      if (m is double) {
        onProgress?.call(m);
      } else if (m is String) {
        done.complete(m);
      }
    });
    await Isolate.spawn(_hashWorker, (f.path, progress.sendPort),
        onError: progress.sendPort, debugName: 'sha256');
    try {
      return await done.future;
    } finally {
      progress.close();
    }
  }
}

Future<void> _hashWorker((String, SendPort) args) async {
  final (path, port) = args;
  final file = File(path);
  final total = await file.length();
  final out = _DigestSink();
  final input = sha256.startChunkedConversion(out);
  var read = 0;
  var lastReport = 0;
  await for (final chunk in file.openRead()) {
    input.add(chunk);
    read += chunk.length;
    if (read - lastReport > 32 << 20) {
      lastReport = read;
      port.send(read / total);
    }
  }
  input.close();
  port.send(out.value.toString());
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
