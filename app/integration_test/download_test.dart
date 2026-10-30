// Downloads the embedding model (80 MB) from its pinned Hugging Face URL on
// the phone: pauses partway, resumes with a Range request, and checks the
// SHA-256. Works in a temporary folder; the installed models are untouched.
// Needs Wi-Fi.
//
//   flutter test integration_test/download_test.dart -d <device> --no-uninstall
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skillcraft/core/device_services.dart';
import 'package:skillcraft/models/model_download.dart';
import 'package:skillcraft/models/model_manager.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('pinned download pauses, resumes and verifies', (tester) async {
    final device = PlatformDeviceServices();
    final dir = Directory.systemTemp.createTempSync('download_test');
    final known = knownFor(ModelRole.embedding);
    final target = File('${dir.path}/${known.fileName}');
    try {
      final free = await device.freeBytes(dir.path);
      final metered = await device.isMeteredNetwork();
      // ignore: avoid_print
      print('DOWNLOAD free=${free >> 20}MB metered=$metered');
      expect(free, greaterThan(known.bytes));

      Future<DownloadResult> run(DownloadControl control, {double pauseAt = 2}) =>
          downloadFile(Uri.parse(known.url), target,
              bytes: known.bytes,
              sha256: known.sha256,
              freeBytes: () => device.freeBytes(dir.path),
              control: control, onProgress: (stage, f) {
            if (stage == 'download' && f >= pauseAt) control.pause();
          });

      final sw = Stopwatch()..start();
      final first = await run(DownloadControl(), pauseAt: 0.3);
      expect(first, isA<DownloadStopped>());
      final kept = File('${target.path}.part').lengthSync();
      expect(kept, greaterThan(known.bytes * 0.25));

      final second = await run(DownloadControl());
      expect(second, isA<DownloadDone>(), reason: '$second');
      expect(target.lengthSync(), known.bytes);
      // ignore: avoid_print
      print('DOWNLOAD done in ${sw.elapsedMilliseconds}ms, resumed at ${kept >> 20}MB');
    } finally {
      dir.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}
