import 'package:flutter_test/flutter_test.dart';
import 'package:skillcraft/mcp/host_api.dart';
import 'package:skillcraft/storage/database.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase.inMemory());
  tearDown(() => db.close());

  test('migrates to the latest schema', () {
    expect(db.schemaVersion, 1);
    final tables = db
        .query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        .map((r) => r['name']);
    expect(tables, containsAll(['meta', 'notes', 'tasks']));
  });

  test('enforces task constraints', () {
    final r = db.execute(
        "INSERT INTO tasks (title, priority) VALUES ('Ship', 'high')");
    expect(r.changes, 1);
    expect(db.query('SELECT status FROM tasks').single['status'], 'pending');
    expect(
        () => db.execute("INSERT INTO tasks (title, priority) VALUES ('x', 'urgent')"),
        throwsA(isA<SqliteException>()));
  });

  test('stores meta values', () {
    expect(db.metaValue('k'), isNull);
    db.setMeta('k', 'a');
    db.setMeta('k', 'b');
    expect(db.metaValue('k'), 'b');
  });

  group('sql host functions', () {
    test('execute and query with parameters', () async {
      final fns = sqlFunctions(db);
      final r = await fns['sql.execute']!({
        'sql': 'INSERT INTO tasks (title, priority, due_date) VALUES (?, ?, ?)',
        'params': ['Call Ana', 'low', null],
      }) as Map;
      expect(r, {'changes': 1, 'lastInsertRowId': 1});

      final rows = await fns['sql.query']!({
        'sql': 'SELECT title, due_date FROM tasks WHERE priority = ?',
        'params': ['low'],
      }) as List;
      expect(rows, [
        {'title': 'Call Ana', 'due_date': null},
      ]);
    });

    test('reject bad input', () {
      final fns = sqlFunctions(db);
      expect(() => fns['sql.query']!({}), throwsArgumentError);
      expect(
          () => fns['sql.query']!({
                'sql': 'SELECT 1',
                'params': [
                  {'nested': true},
                ],
              }),
          throwsArgumentError);
    });
  });
}
