/// sqlite-vec (vector search for SQLite) for the `sqlite3` Dart package.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

bool _registered = false;

/// Registers sqlite-vec as an auto-extension, so every database opened with
/// `package:sqlite3` afterwards has `vec0` tables and `vec_*` functions.
/// Safe to call more than once.
void registerSqliteVec() {
  if (_registered) return;
  final DynamicLibrary lib;
  if (Platform.isAndroid || Platform.isLinux) {
    lib = DynamicLibrary.open('libsqlite_vec.so');
  } else if (Platform.isWindows) {
    lib = DynamicLibrary.open('sqlite_vec.dll');
  } else {
    throw UnsupportedError('sqlite-vec: unsupported platform');
  }
  sqlite3.ensureExtensionLoaded(
      SqliteExtension.inLibrary(lib, 'sqlite3_vec_init'));
  _registered = true;
}
