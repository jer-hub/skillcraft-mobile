import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skillcraft/models/model_manager.dart';
import 'package:skillcraft/models/model_providers.dart';
import 'package:skillcraft/ui/setup/model_import_tile.dart';

import '../support/fakes.dart';

/// Reports half done, then waits for the test to [release] a result.
class _FakeManager extends ModelManager {
  _FakeManager(super.dir, super.device);

  final started = Completer<void>();
  final release = Completer<DownloadResult>();
  int downloads = 0;

  @override
  Future<DownloadResult> download(ModelRole role,
      {void Function(String stage, double fraction)? onProgress, DownloadControl? control}) async {
    downloads++;
    onProgress?.call('download', 0.5);
    started.complete();
    final r = await release.future;
    if (r is DownloadDone) fileFor(role).createSync(recursive: true);
    return r;
  }
}

void main() {
  late Directory tmp;
  late FakeDeviceServices device;
  late _FakeManager manager;
  var installed = 0;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tile_test');
    device = FakeDeviceServices();
    manager = _FakeManager(Directory('${tmp.path}/models'), device);
    installed = 0;
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  /// Lets the tile finish its real async work (file checks) after a result.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
  }

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        deviceServicesProvider.overrideWithValue(device),
        modelManagerProvider.overrideWith((ref) async => manager),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: ModelImportTile(role: ModelRole.embedding, onInstalled: () async => installed++),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('download shows progress, keeps the run service up, then installs', (tester) async {
    await pump(tester);
    await tester.tap(find.textContaining('Download ('));
    await tester.runAsync(() => manager.started.future);
    await tester.pump();

    expect(find.textContaining('Downloading 40 of 80 MB'), findsOneWidget);
    expect(find.text('Pause'), findsOneWidget);
    expect(device.runEvents.single, startsWith('start:'));
    expect(device.keepScreenOn, [true]);

    manager.release.complete(DownloadDone(manager.fileFor(ModelRole.embedding)));
    await settle(tester);

    expect(find.text('Verified: matches the published file.'), findsOneWidget);
    expect(installed, 1);
    expect(device.runEvents.last, 'stop');
    expect(device.keepScreenOn, [true, false]);
    expect(find.textContaining('Download ('), findsNothing, reason: 'installed now');
  });

  testWidgets('on mobile data it asks first; "Not now" downloads nothing', (tester) async {
    device.metered = true;
    await pump(tester);
    await tester.tap(find.textContaining('Download ('));
    await tester.pumpAndSettle();

    expect(find.text('Download on mobile data?'), findsOneWidget);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(manager.downloads, 0);
  });

  testWidgets('failures are shown and a partial file offers Resume', (tester) async {
    File('${manager.fileFor(ModelRole.embedding).path}.part')
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(1 << 20, 0));
    await pump(tester);
    expect(find.text('Paused at 1.0 of 80 MB'), findsOneWidget);

    await tester.tap(find.text('Resume'));
    await tester.runAsync(() => manager.started.future);
    manager.release.complete(const DownloadFailed('No connection. Tap Resume to continue.'));
    await settle(tester);
    expect(find.text('No connection. Tap Resume to continue.'), findsOneWidget);
    expect(find.text('Resume'), findsOneWidget);
  });
}
