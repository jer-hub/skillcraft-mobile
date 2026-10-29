import 'package:sqlite3/sqlite3.dart';

/// Schema steps, applied in order; `PRAGMA user_version` records progress.
const _migrations = <String>[
  // 1: tasks from the spec, notes for the vector tools.
  '''
  CREATE TABLE tasks (
    id INTEGER PRIMARY KEY,
    title TEXT NOT NULL,
    priority TEXT NOT NULL CHECK (priority IN ('high', 'medium', 'low')),
    due_date TEXT,
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'done')),
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
  );
  CREATE TABLE notes (
    id INTEGER PRIMARY KEY,
    text TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
  );
  CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
  ''',
];

/// The app's SQLite database.
class AppDatabase {
  AppDatabase._(this.db) {
    _migrate();
  }

  /// Opens (creating if needed) the database at [path] and migrates it.
  factory AppDatabase.open(String path) => AppDatabase._(sqlite3.open(path));

  factory AppDatabase.inMemory() => AppDatabase._(sqlite3.openInMemory());

  final Database db;

  int get schemaVersion => db.userVersion;

  /// Whether sqlite-vec is registered in this process.
  bool get hasVectorSupport {
    try {
      db.select('SELECT vec_version()');
      return true;
    } on SqliteException {
      return false;
    }
  }

  List<Map<String, Object?>> query(String sql, [List<Object?> params = const []]) =>
      [for (final row in db.select(sql, params)) Map.of(row)];

  /// Runs a write statement; returns the change count and last rowid.
  ({int changes, int lastInsertRowId}) execute(String sql,
      [List<Object?> params = const []]) {
    db.execute(sql, params);
    return (changes: db.updatedRows, lastInsertRowId: db.lastInsertRowId);
  }

  String? metaValue(String key) =>
      query('SELECT value FROM meta WHERE key = ?', [key]).firstOrNull?['value']
          as String?;

  void setMeta(String key, String value) => db.execute(
      'INSERT INTO meta (key, value) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [key, value]);

  void close() => db.close();

  void _migrate() {
    db.execute('PRAGMA foreign_keys = ON');
    for (var v = db.userVersion; v < _migrations.length; v++) {
      db.execute('BEGIN');
      try {
        db.execute(_migrations[v]);
        db.userVersion = v + 1;
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
    }
  }
}
