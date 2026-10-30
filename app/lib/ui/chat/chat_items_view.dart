import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../chat/chat_controller.dart';
import '../../chat/chat_models.dart';
import 'output_view.dart';

/// Renders one [ChatItem].
class ChatItemView extends ConsumerWidget {
  const ChatItemView(this.item, {super.key});

  final ChatItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) => switch (item) {
        UserMessage(:final text) => _UserBubble(text),
        AssistantMessage m => _AssistantBubble(m),
        SkillSuggestion s => _SuggestionCard(s),
        SkillRun r => SkillRunCard(r),
      };
}

class _UserBubble extends StatelessWidget {
  const _UserBubble(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(left: 48, top: 4, bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        child: SelectableText(text, style: TextStyle(color: scheme.onPrimaryContainer)),
      ),
    );
  }
}

class _AssistantBubble extends StatelessWidget {
  const _AssistantBubble(this.m);
  final AssistantMessage m;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 32, top: 4, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (m.text.isEmpty && !m.done)
            const Padding(
              padding: EdgeInsets.all(8),
              child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else if (m.text.isNotEmpty)
            MarkdownBody(data: m.text, selectable: true),
          if (m.error != null)
            Text(m.error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
      ),
    );
  }
}

class _SuggestionCard extends ConsumerWidget {
  const _SuggestionCard(this.s);
  final SkillSuggestion s;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = ref.watch(chatControllerProvider.select((c) => c.busy));
    final controller = ref.read(chatControllerProvider.notifier);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('This looks like a job for /${s.skillName}.',
                style: Theme.of(context).textTheme.bodyMedium),
            if (!s.resolved) ...[
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                FilledButton(
                  onPressed: busy ? null : () => controller.acceptSuggestion(s.id),
                  child: Text('Run /${s.skillName}'),
                ),
                OutlinedButton(
                  onPressed: busy ? null : () => controller.declineSuggestion(s.id),
                  child: const Text('Just answer'),
                ),
              ]),
            ],
          ],
        ),
      ),
    );
  }
}

/// A skill run: status, live JSON while generating, tool calls, output.
class SkillRunCard extends StatelessWidget {
  const SkillRunCard(this.run, {super.key});
  final SkillRun run;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, color) = switch (run.status) {
      RunStatus.running => (run.step > 1 ? 'Step ${run.step}' : 'Running', theme.colorScheme.primary),
      RunStatus.finished => ('Done', Colors.green),
      RunStatus.failed => ('Failed', theme.colorScheme.error),
      RunStatus.cancelled => ('Stopped', theme.colorScheme.outline),
    };
    final seconds = run.elapsedMs == null ? null : (run.elapsedMs! / 1000).toStringAsFixed(1);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              const Icon(Icons.bolt, size: 18),
              const SizedBox(width: 6),
              Expanded(child: Text('/${run.skillName}', style: theme.textTheme.titleSmall)),
              if (run.status == RunStatus.running)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                ),
              Text(seconds == null ? label : '$label · ${seconds}s',
                  style: theme.textTheme.labelMedium?.copyWith(color: color)),
            ]),
            for (final w in run.warnings)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(w, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.tertiary)),
              ),
            if (run.status == RunStatus.running && run.streamed.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(run.streamed,
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
              ),
            for (final call in run.toolCalls) _ToolCallRow(call),
            if (run.output != null) ...[
              const Divider(height: 20),
              OutputView(run.output),
            ],
            if (run.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(run.error!, style: TextStyle(color: theme.colorScheme.error)),
              ),
          ],
        ),
      ),
    );
  }
}

class _ToolCallRow extends StatelessWidget {
  const _ToolCallRow(this.call);
  final ToolCallView call;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = call.result;
    final icon = result == null
        ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
        : Icon(result.isError ? Icons.error_outline : Icons.check, size: 16,
            color: result.isError ? theme.colorScheme.error : Colors.green);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: icon),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text.rich(TextSpan(children: [
                TextSpan(text: call.tool, style: const TextStyle(fontWeight: FontWeight.w600)),
                if (call.fromHook)
                  TextSpan(text: '  auto', style: theme.textTheme.labelSmall),
              ])),
              Text(jsonEncode(call.arguments),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
              if (result != null)
                Text(result.text,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: result.isError ? theme.colorScheme.error : null)),
            ]),
          ),
        ],
      ),
    );
  }
}
