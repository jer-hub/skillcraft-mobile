import 'package:flutter_test/flutter_test.dart';
import 'package:skillcraft/mcp/host_api.dart';
import 'package:skillcraft/storage/database.dart';
import 'package:skillcraft/storage/note_store.dart';
import 'package:skillcraft/storage/task_store.dart';

void main() {
  late AppDatabase db;
  late int changes;
  setUp(() {
    db = AppDatabase.inMemory();
    changes = 0;
  });
  tearDown(() => db.close());

  void addTask(String title, String priority, {String status = 'pending', String? due}) =>
      db.execute('INSERT INTO tasks (title, priority, due_date, status) VALUES (?, ?, ?, ?)',
          [title, priority, due, status]);

  group('TaskStore', () {
    test('lists pending first, then by priority, newest first', () {
      addTask('low old', 'low');
      addTask('high', 'high', due: 'Friday');
      addTask('done high', 'high', status: 'done');
      addTask('low new', 'low');
      final store = TaskStore(db);

      expect(store.list().map((t) => t.title), ['high', 'low new', 'low old', 'done high']);
      expect(store.list(status: TaskStatus.done).single.title, 'done high');
      expect(store.list(status: TaskStatus.pending), hasLength(3));
      expect(store.list().first.dueDate, 'Friday');
    });

    test('tick, delete, undo and clear done all notify', () {
      addTask('a', 'high');
      addTask('b', 'low');
      final store = TaskStore(db, onChange: () => changes++);
      final a = store.list().firstWhere((t) => t.title == 'a');

      store.setStatus(a.id, TaskStatus.done);
      expect(store.list(status: TaskStatus.done).single.title, 'a');

      final done = store.list(status: TaskStatus.done).single;
      store.delete(done.id);
      expect(store.list().map((t) => t.title), ['b']);

      store.restore(done);
      final back = store.list(status: TaskStatus.done).single;
      expect((back.id, back.title, back.createdAt), (done.id, done.title, done.createdAt));

      expect(store.clearDone(), 1);
      expect(store.list().map((t) => t.title), ['b']);
      expect(changes, 4);
    });
  });

  group('NoteStore', () {
    test('lists newest first and filters by text, treating % and _ literally', () {
      for (final t in ['Gate code 4412', 'Buy 100% juice', 'call_mom tomorrow']) {
        db.execute('INSERT INTO notes (text) VALUES (?)', [t]);
      }
      final store = NoteStore(db);

      expect(store.list().map((n) => n.text).first, 'call_mom tomorrow');
      expect(store.list(contains: 'gate').single.text, 'Gate code 4412');
      expect(store.list(contains: '100%').single.text, 'Buy 100% juice');
      expect(store.list(contains: '%'), hasLength(1), reason: '% is not a wildcard');
      expect(store.list(contains: '_mom').single.text, 'call_mom tomorrow');
    });

    test('delete also removes the embedding row when the index exists', () {
      // Stand-in for the vec0 table (sqlite-vec is not loaded in host tests).
      db.execute('CREATE TABLE note_embeddings (embedding BLOB)');
      final id = db.execute("INSERT INTO notes (text) VALUES ('x')").lastInsertRowId;
      db.execute('INSERT INTO note_embeddings (rowid, embedding) VALUES (?, ?)', [id, 'v']);
      final store = NoteStore(db, onChange: () => changes++);

      store.delete(id);

      expect(db.query('SELECT * FROM notes'), isEmpty);
      expect(db.query('SELECT * FROM note_embeddings'), isEmpty);
      expect(changes, 1);
    });

    test('delete works without a vector index', () {
      final id = db.execute("INSERT INTO notes (text) VALUES ('x')").lastInsertRowId;
      NoteStore(db).delete(id);
      expect(db.query('SELECT * FROM notes'), isEmpty);
    });
  });

  test('tool-server SQL writes notify; reads and no-op writes do not', () async {
    final fns = sqlFunctions(db, onWrite: () => changes++);
    await fns['sql.query']!({'sql': 'SELECT * FROM tasks'});
    await fns['sql.execute']!({'sql': "UPDATE tasks SET status = 'done' WHERE id = 99"});
    expect(changes, 0);

    await fns['sql.execute']!({
      'sql': 'INSERT INTO tasks (title, priority) VALUES (?, ?)',
      'params': ['From a skill', 'high'],
    });
    expect(changes, 1);
  });
}
