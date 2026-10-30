import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skillcraft/core/licenses.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('native and model notices are registered with their texts', () async {
    registerBundledLicenses();
    final entries = await LicenseRegistry.licenses.toList();
    String textOf(String package) {
      final e = entries.firstWhere((e) => e.packages.contains(package),
          orElse: () => throw TestFailure('no license entry for $package'));
      return e.paragraphs.map((p) => p.text).join('\n');
    }

    expect(textOf('llama.cpp (native)'), contains('MIT License'));
    expect(textOf('QuickJS-ng (native)'), contains('MIT License'));
    expect(textOf('sqlite-vec (native)'), contains('MIT License'));
    expect(textOf('nlohmann/json (native, via llama.cpp)'), contains('Niels Lohmann'));
    expect(textOf('cpp-httplib (native, via llama.cpp)'), contains('yhirose'));
    expect(textOf('SQLite (native)'), contains('public domain'));
    expect(textOf('Models (downloaded separately)'), contains('Apache License 2.0'));
  });
}
