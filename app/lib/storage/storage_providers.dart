import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite_vec_ffi/sqlite_vec_ffi.dart';

import '../core/config.dart';
import 'database.dart';

/// The app database in private app storage (not visible over USB).
final databaseProvider = FutureProvider<AppDatabase>((ref) async {
  try {
    registerSqliteVec();
  } catch (e) {
    // Vector tools stay off; everything else still works.
    debugPrint('sqlite-vec unavailable: $e');
  }
  final dir = await getApplicationSupportDirectory();
  final db = AppDatabase.open(p.join(dir.path, AppPaths.databaseFile));
  ref.onDispose(db.close);
  return db;
});
