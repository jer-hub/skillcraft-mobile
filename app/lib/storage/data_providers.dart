import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../mcp/mcp_providers.dart';
import 'data_version.dart';
import 'note_store.dart';
import 'storage_providers.dart';
import 'task_store.dart';

export 'data_version.dart';

final taskStoreProvider = FutureProvider<TaskStore>((ref) async => TaskStore(
      await ref.watch(databaseProvider.future),
      onChange: ref.read(dataVersionProvider.notifier).bump,
    ));

final noteStoreProvider = FutureProvider<NoteStore>((ref) async => NoteStore(
      await ref.watch(databaseProvider.future),
      onChange: ref.read(dataVersionProvider.notifier).bump,
    ));

final tasksProvider = FutureProvider.family<List<Task>, TaskStatus?>((ref, status) async {
  ref.watch(dataVersionProvider);
  return (await ref.watch(taskStoreProvider.future)).list(status: status);
});

/// Notes matching [query]: by meaning when the embedding model is loaded,
/// otherwise by plain text. An empty query lists all notes.
final notesProvider = FutureProvider.family<List<Note>, String>((ref, query) async {
  ref.watch(dataVersionProvider);
  final store = await ref.watch(noteStoreProvider.future);
  final q = query.trim();
  if (q.isEmpty) return store.list();
  final vectors = await ref.watch(vectorStoreProvider.future);
  if (vectors == null) return store.list(contains: q);
  final hits = await vectors.search(q, k: 20);
  return [for (final h in hits) Note(h.id, h.text, h.createdAt, score: h.score)];
});
