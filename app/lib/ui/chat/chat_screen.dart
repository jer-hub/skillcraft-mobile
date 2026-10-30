import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/chat_controller.dart';
import '../../chat/chat_models.dart';
import '../../skills/skill.dart';
import '../nav.dart';
import 'chat_items_view.dart';
import 'skill_input_form.dart';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _input.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _send() {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    ref.read(chatControllerProvider.notifier).submit(text);
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatControllerProvider);
    final deps = ref.watch(chatDepsProvider);
    final skills = deps.value?.skills ?? const <Skill>[];

    ref.listen(chatControllerProvider.select((s) => s.items), (_, _) => _scrollToEnd());
    ref.listen(chatControllerProvider.select((s) => s.inputRequest), (_, request) {
      if (request != null) _showForm(request);
    });
    ref.listen(composerDraftProvider, (_, draft) {
      if (draft == null) return;
      _input.text = draft;
      _input.selection = TextSelection.collapsed(offset: draft.length);
      ref.read(composerDraftProvider.notifier).clear();
      _focus.requestFocus();
    });

    final slash = _slashQuery(_input.text);
    final matches = slash == null
        ? const <Skill>[]
        : skills.where((s) => s.name.startsWith(slash)).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('SkillCraft'),
        actions: [
          IconButton(
            tooltip: 'Clear conversation',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: chat.busy || chat.items.isEmpty
                ? null
                : () => ref.read(chatControllerProvider.notifier).clear(),
          ),
        ],
      ),
      body: Column(
        children: [
          if (deps.hasError)
            MaterialBanner(
              content: Text('Tools or skills failed to load: ${deps.error}'),
              actions: [
                TextButton(onPressed: () => ref.invalidate(chatDepsProvider), child: const Text('Retry')),
              ],
            ),
          Expanded(
            child: chat.items.isEmpty
                ? _EmptyState(skills: skills, onPick: _fill)
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: chat.items.length,
                    itemBuilder: (_, i) => ChatItemView(chat.items[i]),
                  ),
          ),
          if (matches.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: Material(
                elevation: 2,
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final s in matches)
                      ListTile(
                        dense: true,
                        title: Text(s.command),
                        subtitle: Text(s.description, maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () => _fill('${s.command} '),
                      ),
                  ],
                ),
              ),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('composer'),
                      controller: _input,
                      focusNode: _focus,
                      minLines: 1,
                      maxLines: 6,
                      textInputAction: TextInputAction.newline,
                      decoration: const InputDecoration(
                        hintText: 'Message, or / for skills',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  chat.busy
                      ? IconButton.filledTonal(
                          tooltip: 'Stop',
                          icon: const Icon(Icons.stop),
                          onPressed: () => ref.read(chatControllerProvider.notifier).cancel(),
                        )
                      : IconButton.filled(
                          tooltip: 'Send',
                          icon: const Icon(Icons.send),
                          onPressed: deps.hasValue && _input.text.trim().isNotEmpty ? _send : null,
                        ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _fill(String text) {
    _input.text = text;
    _input.selection = TextSelection.collapsed(offset: text.length);
    _focus.requestFocus();
  }

  /// The partial skill name while typing "/name" (before any space).
  static String? _slashQuery(String text) {
    final m = RegExp(r'^/([a-z0-9-]*)$').firstMatch(text);
    return m?.group(1);
  }

  Future<void> _showForm(InputRequest request) async {
    final controller = ref.read(chatControllerProvider.notifier);
    var submitted = false;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SkillInputForm(
        skill: request.skill,
        initial: request.initial,
        problems: request.problems,
        onSubmit: (inputs) {
          submitted = true;
          Navigator.of(ctx).pop();
          controller.submitInputs(request.skill, inputs);
        },
      ),
    );
    if (!submitted) controller.dismissInputRequest();
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.skills, required this.onPick});
  final List<Skill> skills;
  final void Function(String) onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Icon(Icons.auto_awesome, size: 40, color: theme.colorScheme.primary),
        const SizedBox(height: 12),
        Text('Ask anything, or run a skill.', textAlign: TextAlign.center, style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text('Everything stays on this phone.', textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
        const SizedBox(height: 20),
        for (final s in skills)
          Card(
            child: ListTile(
              leading: const Icon(Icons.bolt),
              title: Text(s.command),
              subtitle: Text(s.description),
              onTap: () => onPick('${s.command} '),
            ),
          ),
      ],
    );
  }
}
