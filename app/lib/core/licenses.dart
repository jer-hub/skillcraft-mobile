import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Native code and model notices that Flutter's license page cannot discover
/// on its own (it only knows Dart packages). Texts live in assets/licenses/.
const _notices = <(String asset, List<String> packages)>[
  ('assets/licenses/llama.cpp.txt', ['llama.cpp (native)']),
  ('assets/licenses/nlohmann-json.txt', ['nlohmann/json (native, via llama.cpp)']),
  ('assets/licenses/cpp-httplib.txt', ['cpp-httplib (native, via llama.cpp)']),
  ('assets/licenses/quickjs-ng.txt', ['QuickJS-ng (native)']),
  ('assets/licenses/sqlite-vec.txt', ['sqlite-vec (native)']),
  ('assets/licenses/sqlite.txt', ['SQLite (native)']),
  ('assets/licenses/models.txt', ['Models (downloaded separately)']),
];

/// Adds the bundled notices to [LicenseRegistry]; call once at startup.
void registerBundledLicenses({AssetBundle? bundle}) {
  LicenseRegistry.addLicense(() async* {
    for (final (asset, packages) in _notices) {
      final text = await (bundle ?? rootBundle).loadString(asset);
      yield LicenseEntryWithLineBreaks(packages, text);
    }
  });
}
