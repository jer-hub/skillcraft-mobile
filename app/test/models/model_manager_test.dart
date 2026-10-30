import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skillcraft/core/device_services.dart';
import 'package:skillcraft/models/model_manager.dart';

import '../support/fakes.dart';

void main() {
  late Directory tmp;
  late FakeDeviceServices device;
  late ModelManager manager;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('models_test');
    device = FakeDeviceServices();
    manager = ModelManager(Directory('${tmp.path}/models'), device);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('nothing installed at first; cancelled import changes nothing', () async {
    expect(manager.installed(ModelRole.chat), isNull);
    expect(await manager.import(ModelRole.chat), isA<ImportCancelled>());
    expect(manager.installed(ModelRole.chat), isNull);
  });

  test('imports a GGUF file; unknown bytes are installed but unverified', () async {
    device.importBytes = [...ascii.encode('GGUF'), 3, 0, 0, 0, 1, 2, 3];
    final stages = <String>{};

    final r = await manager.import(ModelRole.embedding, onProgress: (s, _) => stages.add(s));

    expect(r, isA<ImportDone>());
    expect((r as ImportDone).verified, isFalse);
    expect(manager.installed(ModelRole.embedding)?.lengthSync(), 11);
    expect(stages, containsAll(['copy']));
    expect(Directory('${tmp.path}/models').listSync().map((f) => f.path.split(RegExp(r'[\\/]')).last),
        [knownFor(ModelRole.embedding).fileName], reason: 'no staging file left behind');
  });

  test('rejects files that are not GGUF and cleans up', () async {
    device.importBytes = utf8.encode('<html>not a model</html>');
    device.importName = 'page.html';

    final r = await manager.import(ModelRole.chat);

    expect(r, isA<ImportRejected>());
    expect((r as ImportRejected).reason, contains('page.html'));
    expect(manager.installed(ModelRole.chat), isNull);
    expect(Directory('${tmp.path}/models').listSync(), isEmpty);
  });

  test('sha256Of matches package:crypto and reports progress', () async {
    final f = File('${tmp.path}/blob')..writeAsBytesSync(List.generate(100000, (i) => i % 251));
    final hash = await ModelManager.sha256Of(f);
    expect(hash, sha256.convert(f.readAsBytesSync()).toString());
  });

  test('known models carry the published hashes', () {
    expect(knownFor(ModelRole.chat).sha256,
        '6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e');
    expect(knownFor(ModelRole.embedding).bytes, 84106624);
  });

  test('reads MemTotal and MemAvailable', () {
    final m = readMemInfo('MemTotal:        7833748 kB\nMemFree:  1 kB\nMemAvailable:    3000000 kB\n');
    expect(m.total, 7833748 * 1024);
    expect(m.available, 3000000 * 1024);
  });
}
