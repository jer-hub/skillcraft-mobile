import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../mcp/mcp_providers.dart';
import '../../storage/data_providers.dart';
import '../../storage/note_store.dart';
import '../../storage/task_store.dart';

/// Saved tasks and notes. Skills add them through tool calls (e.g.
/// /capture-tasks); here they can be ticked off, searched and deleted.
class TasksScreen extends StatelessWidget {
  const TasksScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Saved'),
          actions: const [_ClearDoneButton()],
          bottom: const TabBar(tabs: [Tab(text: 'Tasks'), Tab(text: 'Notes')]),
        ),
        body: const TabBarView(children: [_TasksTab(), _NotesTab()]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tasks

class _TaskFilter extends Notifier<TaskStatus?> {
  @override
  TaskStatus? build() => null;

  void set(TaskStatus? status) => state = status;
}

final _taskFilterProvider = NotifierProvider<_TaskFilter, TaskStatus?>(_TaskFilter.new);

class _TasksTab extends ConsumerWidget {
  const _TasksTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(_taskFilterProvider);
    final tasks = ref.watch(tasksProvider(filter));

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: SegmentedButton<TaskStatus?>(
            segments: const [
              ButtonSegment(value: null, label: Text('All')),
              ButtonSegment(value: TaskStatus.pending, label: Text('Pending')),
              ButtonSegment(value: TaskStatus.done, label: Text('Done')),
            ],
            selected: {filter},
            onSelectionChanged: (s) => ref.read(_taskFilterProvider.notifier).set(s.first),
          ),
        ),
        Expanded(
          child: tasks.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Could not load tasks: $e')),
            data: (list) => list.isEmpty
                ? _Empty(
                    icon: Icons.task_alt,
                    text: filter == TaskStatus.done
                        ? 'No finished tasks yet.'
                        : 'No tasks yet. Try /capture-tasks in Chat with some meeting notes.',
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: list.length,
                    itemBuilder: (_, i) => _TaskTile(list[i]),
                  ),
          ),
        ),
      ],
    );
  }
}

class _TaskTile extends ConsumerWidget {
  const _TaskTile(this.task);
  final Task task;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final color = switch (task.priority) {
      'high' => theme.colorScheme.error,
      'medium' => theme.colorScheme.tertiary,
      _ => theme.colorScheme.outline,
    };
    return Dismissible(
      key: ValueKey('task-${task.id}'),
      direction: DismissDirection.endToStart,
      background: const _DeleteBackground(),
      onDismissed: (_) async {
        final store = await ref.read(taskStoreProvider.future);
        store.delete(task.id);
        if (!context.mounted) return;
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(
            content: Text('Deleted "${task.title}"'),
            action: SnackBarAction(label: 'Undo', onPressed: () => store.restore(task)),
          ));
      },
      child: CheckboxListTile(
        key: ValueKey('task-check-${task.id}'),
        value: task.isDone,
        controlAffinity: ListTileControlAffinity.leading,
        onChanged: (done) async => (await ref.read(taskStoreProvider.future))
            .setStatus(task.id, done == true ? TaskStatus.done : TaskStatus.pending),
        title: Text(
          task.title,
          style: task.isDone
              ? TextStyle(decoration: TextDecoration.lineThrough, color: theme.colorScheme.outline)
              : null,
        ),
        subtitle: Row(children: [
          Icon(Icons.flag, size: 14, color: color),
          const SizedBox(width: 4),
          Text(task.priority),
          if (task.dueDate != null) ...[
            const SizedBox(width: 12),
            const Icon(Icons.event, size: 14),
            const SizedBox(width: 4),
            Flexible(child: Text(task.dueDate!, overflow: TextOverflow.ellipsis)),
          ],
        ]),
      ),
    );
  }
}

class _ClearDoneButton extends ConsumerWidget {
  const _ClearDoneButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final done = ref.watch(tasksProvider(TaskStatus.done)).value ?? const [];
    return PopupMenuButton<String>(
      onSelected: (_) async {
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Delete ${done.length} finished task${done.length == 1 ? '' : 's'}?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
            ],
          ),
        );
        if (ok == true) (await ref.read(taskStoreProvider.future)).clearDone();
      },
      itemBuilder: (_) => [
        PopupMenuItem(value: 'clear', enabled: done.isNotEmpty, child: const Text('Clear done tasks')),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Notes

class _NoteQuery extends Notifier<String> {
  @override
  String build() => '';

  void set(String q) => state = q;
}

final _noteQueryProvider = NotifierProvider<_NoteQuery, String>(_NoteQuery.new);

class _NotesTab extends ConsumerWidget {
  const _NotesTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = ref.watch(_noteQueryProvider);
    final notes = ref.watch(notesProvider(query));
    final semantic = ref.watch(vectorStoreProvider).value != null;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: TextField(
            key: const ValueKey('note-search'),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: semantic ? 'Search notes by meaning' : 'Search notes',
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onSubmitted: (q) => ref.read(_noteQueryProvider.notifier).set(q),
            onChanged: (q) {
              if (q.isEmpty) ref.read(_noteQueryProvider.notifier).set('');
            },
          ),
        ),
        Expanded(
          child: notes.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Could not load notes: $e')),
            data: (list) => list.isEmpty
                ? _Empty(
                    icon: Icons.sticky_note_2_outlined,
                    text: query.isEmpty
                        ? 'No notes yet. Skills can save notes with the remember_note tool.'
                        : 'No notes match "$query".',
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: list.length,
                    itemBuilder: (_, i) => _NoteTile(list[i]),
                  ),
          ),
        ),
      ],
    );
  }
}

class _NoteTile extends ConsumerWidget {
  const _NoteTile(this.note);
  final Note note;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Dismissible(
      key: ValueKey('note-${note.id}'),
      direction: DismissDirection.endToStart,
      background: const _DeleteBackground(),
      // A note's embedding cannot be restored cheaply, so ask instead of Undo.
      confirmDismiss: (_) async =>
          await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Delete this note?'),
              content: Text(note.text, maxLines: 4, overflow: TextOverflow.ellipsis),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
              ],
            ),
          ) ??
          false,
      onDismissed: (_) async => (await ref.read(noteStoreProvider.future)).delete(note.id),
      child: ListTile(
        title: Text(note.text),
        subtitle: Text(note.createdAt),
        trailing: note.score == null ? null : Text(note.score!.toStringAsFixed(2)),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _DeleteBackground extends StatelessWidget {
  const _DeleteBackground();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.errorContainer,
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 24),
      child: Icon(Icons.delete_outline, color: scheme.onErrorContainer),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 40, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
          ]),
        ),
      );
}
