import 'database.dart';

enum TaskStatus { pending, done }

class Task {
  const Task({
    required this.id,
    required this.title,
    required this.priority,
    required this.status,
    required this.createdAt,
    this.dueDate,
  });

  factory Task.fromRow(Map<String, Object?> r) => Task(
        id: r['id'] as int,
        title: r['title'] as String,
        priority: r['priority'] as String,
        dueDate: r['due_date'] as String?,
        status: r['status'] == 'done' ? TaskStatus.done : TaskStatus.pending,
        createdAt: r['created_at'] as String,
      );

  final int id;
  final String title;

  /// high, medium or low (enforced by the table).
  final String priority;
  final String? dueDate;
  final TaskStatus status;
  final String createdAt;

  bool get isDone => status == TaskStatus.done;
}

/// Tasks for the Tasks screen. Skills write tasks through the `local_db`
/// tool server; this is the UI's side of the same table.
class TaskStore {
  TaskStore(this._db, {this.onChange});

  final AppDatabase _db;

  /// Called after every write, so screens can refresh.
  final void Function()? onChange;

  /// Pending first, then by priority and newest first.
  List<Task> list({TaskStatus? status}) => [
        for (final r in _db.query('''
          SELECT * FROM tasks
          ${status == null ? '' : 'WHERE status = ?'}
          ORDER BY status = 'done',
                   CASE priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 ELSE 2 END,
                   id DESC''', [if (status != null) status.name]))
          Task.fromRow(r),
      ];

  void setStatus(int id, TaskStatus status) {
    _db.execute('UPDATE tasks SET status = ? WHERE id = ?', [status.name, id]);
    onChange?.call();
  }

  void delete(int id) {
    _db.execute('DELETE FROM tasks WHERE id = ?', [id]);
    onChange?.call();
  }

  /// Puts a deleted task back with its original id (for Undo).
  void restore(Task t) {
    _db.execute(
      'INSERT INTO tasks (id, title, priority, due_date, status, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      [t.id, t.title, t.priority, t.dueDate, t.status.name, t.createdAt],
    );
    onChange?.call();
  }

  /// Deletes every done task; returns how many.
  int clearDone() {
    final n = _db.execute("DELETE FROM tasks WHERE status = 'done'").changes;
    onChange?.call();
    return n;
  }
}
