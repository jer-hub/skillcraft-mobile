import 'dart:typed_data';

import '../inference/llama_engine.dart';
import 'database.dart';

/// Task prefixes an embedding model expects (nomic-embed-text uses these).
class EmbeddingProfile {
  const EmbeddingProfile({
    this.documentPrefix = 'search_document: ',
    this.queryPrefix = 'search_query: ',
  });

  final String documentPrefix;
  final String queryPrefix;
}

class NoteHit {
  const NoteHit(this.id, this.text, this.score, this.createdAt);

  final int id;
  final String text;

  /// Cosine similarity in [-1, 1]; higher is closer.
  final double score;
  final String createdAt;

  Map<String, Object?> toJson() =>
      {'id': id, 'text': text, 'score': score, 'created_at': createdAt};
}

/// Notes with semantic search: rows in `notes`, vectors in a sqlite-vec
/// `vec0` table keyed by note id.
class VectorStore {
  VectorStore(this._db, this._embedder,
      {this.profile = const EmbeddingProfile(), this.onChange});

  final AppDatabase _db;
  final EmbeddingEngine _embedder;
  final EmbeddingProfile profile;

  /// Called after a note is added, so screens can refresh.
  final void Function()? onChange;

  static const _table = 'note_embeddings';
  static const _dimKey = 'embedding_dim';

  /// Creates the index for the loaded model; rebuilds it (re-embedding every
  /// note) when the model's dimensions changed since last time.
  Future<void> open() async {
    final dim = _embedder.embeddingDimensions;
    if (dim <= 0) throw StateError('No embedding model loaded');
    final previous = int.tryParse(_db.metaValue(_dimKey) ?? '');
    final exists = _db
        .query("SELECT 1 FROM sqlite_master WHERE name = ?", [_table]).isNotEmpty;
    if (exists && previous == dim) return;

    _db.execute('DROP TABLE IF EXISTS $_table');
    _db.execute('CREATE VIRTUAL TABLE $_table USING vec0(embedding float[$dim])');
    _db.setMeta(_dimKey, '$dim');
    for (final row in _db.query('SELECT id, text FROM notes ORDER BY id')) {
      await _index(row['id'] as int, row['text'] as String);
    }
  }

  /// Saves [text] as a note and indexes it; returns the note id.
  Future<int> remember(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) throw ArgumentError('text is empty');
    // Embed first so a failure leaves no unindexed note behind.
    final vector = await _embedder.embed('${profile.documentPrefix}$trimmed');
    final id = _db.execute('INSERT INTO notes (text) VALUES (?)', [trimmed]).lastInsertRowId;
    _db.execute('INSERT INTO $_table (rowid, embedding) VALUES (?, ?)', [id, _blob(vector)]);
    onChange?.call();
    return id;
  }

  /// The [k] notes closest in meaning to [query], best first.
  Future<List<NoteHit>> search(String query, {int k = 5}) async {
    if (query.trim().isEmpty) throw ArgumentError('query is empty');
    final limit = k.clamp(1, 50);
    final vector = await _embedder.embed('${profile.queryPrefix}${query.trim()}');
    final rows = _db.query('''
      WITH hits AS (
        SELECT rowid, distance FROM $_table WHERE embedding MATCH ? AND k = ?
      )
      SELECT n.id, n.text, n.created_at, hits.distance
      FROM hits JOIN notes n ON n.id = hits.rowid
      ORDER BY hits.distance
    ''', [_blob(vector), limit]);
    return [
      for (final r in rows)
        NoteHit(
          r['id'] as int,
          r['text'] as String,
          // Vectors are unit length, so L2 distance d gives cos = 1 - d²/2.
          1 - (r['distance'] as num).toDouble() * (r['distance'] as num).toDouble() / 2,
          r['created_at'] as String,
        ),
    ];
  }

  Future<void> _index(int id, String text) async {
    final vector = await _embedder.embed('${profile.documentPrefix}$text');
    _db.execute('INSERT INTO $_table (rowid, embedding) VALUES (?, ?)', [id, _blob(vector)]);
  }

  /// sqlite-vec accepts float32 vectors as little-endian blobs.
  static Uint8List _blob(List<double> v) => Float32List.fromList(v).buffer.asUint8List();
}
