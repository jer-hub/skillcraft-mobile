import 'database.dart';

class Note {
  const Note(this.id, this.text, this.createdAt, {this.score});

  final int id;
  final String text;
  final String createdAt;

  /// Similarity to the search query, when it came from a semantic search.
  final double? score;
}

/// Notes for the Tasks screen. The `notes` tool server adds notes (with
/// embeddings) through VectorStore; this lists, filters and deletes them.
class NoteStore {
  NoteStore(this._db, {this.onChange});

  final AppDatabase _db;
  final void Function()? onChange;

  static const _embeddings = 'note_embeddings';

  /// Newest first; [contains] filters by plain text (case-insensitive).
  List<Note> list({String? contains}) {
    final q = contains?.trim() ?? '';
    final rows = q.isEmpty
        ? _db.query('SELECT id, text, created_at FROM notes ORDER BY id DESC')
        : _db.query(
            "SELECT id, text, created_at FROM notes WHERE text LIKE ? ESCAPE '\\' ORDER BY id DESC",
            ['%${_escapeLike(q)}%'],
          );
    return [for (final r in rows) Note(r['id'] as int, r['text'] as String, r['created_at'] as String)];
  }

  /// Deletes the note and its embedding, if the vector index exists.
  void delete(int id) {
    _db.db.execute('BEGIN');
    try {
      _db.execute('DELETE FROM notes WHERE id = ?', [id]);
      if (_hasEmbeddings) {
        _db.execute('DELETE FROM $_embeddings WHERE rowid = ?', [id]);
      }
      _db.db.execute('COMMIT');
    } catch (_) {
      _db.db.execute('ROLLBACK');
      rethrow;
    }
    onChange?.call();
  }

  bool get _hasEmbeddings =>
      _db.query('SELECT 1 FROM sqlite_master WHERE name = ?', [_embeddings]).isNotEmpty;

  static String _escapeLike(String s) =>
      s.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');
}
