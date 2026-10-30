import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../skills/skill_providers.dart';
import '../../skills/skill_repository.dart';
import '../nav.dart';
import 'skill_editor_screen.dart';

class SkillsScreen extends ConsumerWidget {
  const SkillsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(skillEntriesProvider);
    final folder = ref.watch(skillsDirectoryProvider).value?.path;

    return Scaffold(
      appBar: AppBar(title: const Text('Skills')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('New skill'),
        onPressed: () => _open(context, 'new-skill.md', newSkillTemplate, isNew: true),
      ),
      body: entries.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Could not read skills: $e')),
        data: (list) => ListView(
          padding: const EdgeInsets.only(bottom: 88),
          children: [
            if (folder != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text('Folder: $folder', style: Theme.of(context).textTheme.bodySmall),
              ),
            if (list.isEmpty)
              const Padding(padding: EdgeInsets.all(24), child: Text('No skills yet.')),
            for (final e in list) _SkillTile(e, onOpen: () => _open(context, e.fileName, e.source)),
          ],
        ),
      ),
    );
  }

  void _open(BuildContext context, String fileName, String source, {bool isNew = false}) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SkillEditorScreen(fileName: fileName, source: source, isNew: isNew),
    ));
  }
}

class _SkillTile extends ConsumerWidget {
  const _SkillTile(this.entry, {required this.onOpen});
  final SkillEntry entry;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final skill = entry.skill;
    return ListTile(
      leading: Icon(entry.isValid ? Icons.bolt : Icons.error_outline,
          color: entry.isValid ? theme.colorScheme.primary : theme.colorScheme.error),
      title: Text(skill?.command ?? entry.fileName),
      subtitle: Text(
        entry.isValid ? skill!.description : entry.issues.first.toString(),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: onOpen,
      trailing: PopupMenuButton<String>(
        onSelected: (action) async {
          switch (action) {
            case 'run':
              ref.read(composerDraftProvider.notifier).set('${skill!.command} ');
              ref.read(homeTabProvider.notifier).show(HomeTab.chat);
            case 'delete':
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text('Delete ${entry.fileName}?'),
                  content: const Text('The file is removed from the skills folder.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                    TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
                  ],
                ),
              );
              if (ok == true) {
                await (await ref.read(skillRepositoryProvider.future)).delete(entry.fileName);
              }
          }
        },
        itemBuilder: (_) => [
          if (entry.isValid) const PopupMenuItem(value: 'run', child: Text('Run in chat')),
          const PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
    );
  }
}
