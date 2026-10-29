import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../inference/engine_providers.dart';
import '../../skills/skill_compiler.dart';
import '../../skills/skill_providers.dart';
import '../../skills/skill_repository.dart';

/// Phase 2 exit check: run a slash command through the skill compiler with
/// grammar-constrained generation and validate the result.
class SkillDebugScreen extends ConsumerStatefulWidget {
  const SkillDebugScreen({super.key});

  @override
  ConsumerState<SkillDebugScreen> createState() => _SkillDebugScreenState();
}

class _SkillDebugScreenState extends ConsumerState<SkillDebugScreen> {
  static const _sampleNotes =
      '/extract-tasks Weekly sync, Oct 28. '
      'Ana will send the revised budget to finance by Friday, this is urgent. '
      'Ben should book the venue for the December workshop. '
      'Someone needs to update the onboarding guide eventually. '
      'Carla to review the vendor contract before Nov 15.';

  final _commandCtrl = TextEditingController(text: _sampleNotes);
  final _output = StringBuffer();
  final _log = <String>[];
  StreamSubscription<String>? _run;
  bool _busy = false;

  @override
  void dispose() {
    _run?.cancel();
    _commandCtrl.dispose();
    super.dispose();
  }

  void _addLog(String line) => setState(() => _log.insert(0, line));

  Future<void> _runSkill(List<SkillEntry> entries) async {
    final engine = ref.read(inferenceEngineProvider);
    final compiler = ref.read(skillCompilerProvider);

    final invocation = SkillCompiler.parseInvocation(_commandCtrl.text);
    if (invocation == null) {
      _addLog('Start with /skill-name');
      return;
    }
    final (name, args) = invocation;
    final skill = entries
        .map((e) => e.skill)
        .where((s) => s?.name == name)
        .firstOrNull;
    if (skill == null) {
      _addLog('No valid skill named "$name"');
      return;
    }

    setState(() {
      _busy = true;
      _output.clear();
    });
    final CompiledSkill compiled;
    final compileTimer = Stopwatch()..start();
    try {
      compiled = await compiler.compile(
        skill,
        SkillCompiler.parseArguments(skill, args),
      );
    } catch (e) {
      _addLog('Compile failed: $e');
      setState(() => _busy = false);
      return;
    }
    for (final w in compiled.warnings) {
      _addLog('Warning: $w');
    }
    _addLog(
      'Compiled in ${compileTimer.elapsedMilliseconds} ms · '
      'prompt ${compiled.promptTokens} tok · '
      'grammar ${compiled.grammar.length} chars',
    );

    final raw = StringBuffer();
    final sw = Stopwatch()..start();
    int? firstTokenMs;
    var pieces = 0;
    _run = engine
        .generate(compiled.prompt, compiled.generationOptions)
        .listen(
          (piece) {
            firstTokenMs ??= sw.elapsedMilliseconds;
            pieces++;
            raw.write(piece);
            setState(() => _output.write(piece));
          },
          onError: (Object e) {
            _addLog('Generation error: $e');
            setState(() => _busy = false);
          },
          onDone: () {
            final genMs = sw.elapsedMilliseconds - (firstTokenMs ?? 0);
            final tps = pieces > 1 && genMs > 0
                ? ((pieces - 1) * 1000 / genMs).toStringAsFixed(1)
                : '-';
            String verdict;
            try {
              final response = compiled.parse(raw.toString());
              // One line so `adb logcat -s flutter` captures it whole.
              debugPrint(
                'SKILL_OUTPUT ${skill.name}: ${switch (response) {
                  FinalOutput(:final output) => jsonEncode(output),
                  ToolCallRequest(:final tool, :final arguments) => 'tool_call $tool ${jsonEncode(arguments)}',
                }}',
              );
              verdict = switch (response) {
                FinalOutput(:final output) =>
                  'SCHEMA VALID · '
                      '${_countItems(output)}',
                ToolCallRequest(:final tool) =>
                  'SCHEMA VALID · tool call $tool',
              };
              if (response case FinalOutput(:final output)) {
                setState(
                  () => _output
                    ..clear()
                    ..write(const JsonEncoder.withIndent('  ').convert(output)),
                );
              }
            } on SkillOutputException catch (e) {
              debugPrint(
                'SKILL_OUTPUT ${skill.name}: INVALID '
                '${raw.toString().replaceAll('\n', ' ')}',
              );
              verdict = 'INVALID: ${e.message}';
            }
            _addLog(
              '${engine.lastReusedTokens} cached · first token '
              '${firstTokenMs ?? '-'} ms · ~$tps tok/s · '
              'total ${sw.elapsedMilliseconds} ms · $verdict',
            );
            setState(() => _busy = false);
          },
        );
  }

  static String _countItems(Object? output) {
    if (output is Map) {
      final lists = output.entries.where((e) => e.value is List);
      if (lists.isNotEmpty) {
        return lists
            .map((e) => '${(e.value as List).length} ${e.key}')
            .join(', ');
      }
    }
    return 'output ok';
  }

  @override
  Widget build(BuildContext context) {
    final engine = ref.watch(inferenceEngineProvider);
    final entries = ref.watch(skillEntriesProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Skill debug')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ...entries.when(
            data: (list) => [
              Text(
                '${list.length} skill file(s)',
                style: theme.textTheme.titleSmall,
              ),
              for (final e in list)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    e.isValid ? Icons.check_circle : Icons.error,
                    color: e.isValid ? Colors.green : theme.colorScheme.error,
                  ),
                  title: Text(e.skill?.command ?? e.fileName),
                  subtitle: Text(
                    e.isValid ? e.skill!.description : e.issues.join('\n'),
                  ),
                ),
            ],
            loading: () => [const LinearProgressIndicator()],
            error: (err, _) => [Text('Skills unavailable: $err')],
          ),
          const Divider(height: 32),
          TextField(
            controller: _commandCtrl,
            minLines: 3,
            maxLines: 8,
            decoration: const InputDecoration(labelText: 'Slash command'),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: !_busy && engine.isLoaded && entries.hasValue
                      ? () => _runSkill(entries.requireValue)
                      : null,
                  child: Text(
                    engine.isLoaded ? 'Run skill' : 'Load a model first',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _busy ? engine.cancel : null,
                child: const Text('Cancel'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SelectableText(
            _output.toString(),
            style: const TextStyle(fontFamily: 'monospace'),
          ),
          const Divider(height: 32),
          for (final line in _log) Text(line, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}
