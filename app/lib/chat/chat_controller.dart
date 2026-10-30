import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:llama_ffi/llama_ffi.dart' show GenerationOptions, LlamaException;

import '../agent/agent_runner.dart';
import '../core/device_services.dart';
import '../inference/chat_template.dart';
import '../inference/engine_providers.dart';
import '../inference/llama_engine.dart';
import '../mcp/mcp_host.dart';
import '../mcp/mcp_providers.dart';
import '../models/model_providers.dart';
import '../settings/app_settings.dart';
import '../skills/skill.dart';
import '../skills/skill_compiler.dart';
import '../skills/skill_providers.dart';
import 'chat_models.dart';
import 'skill_matcher.dart';

/// Everything the chat needs, gathered in one place so tests can swap it.
class ChatDeps {
  const ChatDeps({
    required this.engine,
    required this.compiler,
    required this.mcp,
    required this.skills,
    required this.device,
    required this.settings,
    this.matcher,
  });

  final InferenceEngine engine;
  final SkillCompiler compiler;
  final McpHost mcp;

  /// Valid skills only.
  final List<Skill> skills;
  final DeviceServices device;
  final AppSettings settings;

  /// Null when no embedding model is available (no suggestions then).
  final SkillMatcher? matcher;
}

final chatDepsProvider = FutureProvider<ChatDeps>((ref) async {
  final entries = await ref.watch(skillEntriesProvider.future);
  final vectors = await ref.watch(vectorStoreProvider.future);
  return ChatDeps(
    engine: ref.watch(inferenceEngineProvider),
    compiler: ref.watch(skillCompilerProvider),
    mcp: (await ref.watch(toolServersProvider.future)).host,
    skills: [for (final e in entries) if (e.skill != null && e.isValid) e.skill!],
    device: ref.watch(deviceServicesProvider),
    settings: await ref.watch(settingsProvider.future),
    matcher: vectors == null ? null : SkillMatcher(ref.watch(embeddingEngineProvider)),
  );
});

const _chatSystemPrompt = 'You are SkillCraft, a helpful assistant running fully on this '
    'phone. Answer clearly and briefly. If the user wants something done that a '
    'skill can do, mention its /command.';

class ChatController extends Notifier<ChatState> {
  int _nextId = 0;
  AgentRunner? _runner;
  InferenceEngine? _plainEngine;

  @override
  ChatState build() => const ChatState();

  /// Handles a line from the composer.
  Future<void> submit(String text) async {
    final line = text.trim();
    if (line.isEmpty || state.busy) return;
    final deps = await ref.read(chatDepsProvider.future);

    final invocation = SkillCompiler.parseInvocation(line);
    if (invocation != null) {
      _add(UserMessage(_id(), line));
      final (name, args) = invocation;
      final skill = deps.skills.where((s) => s.name == name).firstOrNull;
      if (skill == null) {
        _add(AssistantMessage(_id(), '', done: true,
            error: 'No skill named /$name. Type / to see the available skills.'));
        return;
      }
      Map<String, Object?> inputs;
      try {
        inputs = SkillCompiler.parseArguments(skill, args);
        SkillCompiler.resolveInputs(skill, inputs);
      } on SkillInputException catch (e) {
        state = state.copyWith(inputRequest: InputRequest(skill, const {}, problems: e.problems));
        return;
      }
      await _runSkill(deps, skill, inputs);
      return;
    }

    _add(UserMessage(_id(), line));
    final match = await _suggest(deps, line);
    if (match != null) {
      _add(SkillSuggestion(_id(), match.skill.name, line, match.score));
      return;
    }
    await _answer(deps);
  }

  /// Runs a suggested skill with the original message as its input.
  Future<void> acceptSuggestion(int id) async {
    final s = _resolve(id);
    if (s == null || state.busy) return;
    final deps = await ref.read(chatDepsProvider.future);
    final skill = deps.skills.where((k) => k.name == s.skillName).firstOrNull;
    if (skill == null) return;
    try {
      final inputs = SkillCompiler.parseArguments(skill, s.message);
      SkillCompiler.resolveInputs(skill, inputs);
      await _runSkill(deps, skill, inputs);
    } on SkillInputException {
      state = state.copyWith(inputRequest: InputRequest(skill, const {}));
    }
  }

  /// Answers the suggested message as plain chat instead.
  Future<void> declineSuggestion(int id) async {
    if (_resolve(id) == null || state.busy) return;
    await _answer(await ref.read(chatDepsProvider.future));
  }

  /// Runs the skill from a completed input form.
  Future<void> submitInputs(Skill skill, Map<String, Object?> inputs) async {
    state = state.copyWith(clearInputRequest: true);
    _add(UserMessage(_id(), '${skill.command} (form)'));
    await _runSkill(await ref.read(chatDepsProvider.future), skill, inputs);
  }

  void dismissInputRequest() => state = state.copyWith(clearInputRequest: true);

  void cancel() {
    _runner?.cancel();
    _plainEngine?.cancel();
  }

  void clear() {
    if (!state.busy) state = const ChatState();
  }

  // -------------------------------------------------------------------------

  Future<SkillMatch?> _suggest(ChatDeps deps, String message) async {
    final matcher = deps.matcher;
    if (matcher == null) return null;
    try {
      final best = await matcher.best(message, deps.skills);
      return best != null && best.score >= deps.settings.suggestThreshold ? best : null;
    } catch (_) {
      return null; // suggestions are best-effort
    }
  }

  Future<void> _runSkill(ChatDeps deps, Skill skill, Map<String, Object?> inputs) async {
    final id = _id();
    _add(SkillRun(id, skill.name));
    final runner = AgentRunner(engine: deps.engine, compiler: deps.compiler, mcp: deps.mcp);
    _runner = runner;
    final sw = Stopwatch()..start();
    await _busy(deps, () async {
      await for (final event in runner.run(skill, inputs)) {
        final run = _item<SkillRun>(id);
        if (run == null) continue;
        _replace(switch (event) {
          AgentCompiled(:final compiled) =>
            run.copyWith(promptTokens: compiled.promptTokens, warnings: compiled.warnings),
          AgentStepStarted(:final step) => run.copyWith(step: step, streamed: ''),
          AgentToken(:final text) => run.copyWith(streamed: run.streamed + text),
          AgentToolCall(:final tool, :final arguments, :final fromHook) => run.copyWith(
              toolCalls: [...run.toolCalls, ToolCallView(tool, arguments, fromHook: fromHook)]),
          AgentToolResult(:final result) => run.copyWith(toolCalls: [
              ...run.toolCalls.take(run.toolCalls.length - 1),
              run.toolCalls.last.withResult(result),
            ]),
          AgentFinished(:final output, :final partial) => run.copyWith(
              status: RunStatus.finished,
              output: output,
              elapsedMs: sw.elapsedMilliseconds,
              warnings: partial
                  ? [
                      ...run.warnings,
                      'The model started repeating itself or ran out of room, so the '
                          'reply was cut short. Showing the items that were complete.',
                    ]
                  : null),
          AgentFailed(:final error, :final cancelled) => run.copyWith(
              status: cancelled ? RunStatus.cancelled : RunStatus.failed,
              error: cancelled ? null : _describe(error),
              elapsedMs: sw.elapsedMilliseconds),
        });
      }
    });
    _runner = null;
    final done = _item<SkillRun>(id);
    // One line per run, for profiling with `adb logcat -s flutter`.
    debugPrint('SKILL_RUN /${skill.name} ${done?.status.name} ${sw.elapsedMilliseconds}ms '
        'prompt=${done?.promptTokens}tok out=${done?.streamed.length}chars '
        'reused=${deps.engine.lastReusedTokens}tok');
  }

  /// Plain reply using recent plain-chat history within the context budget.
  Future<void> _answer(ChatDeps deps) async {
    final id = _id();
    _add(AssistantMessage(id, ''));
    final engine = deps.engine;
    _plainEngine = engine;
    await _busy(deps, () async {
      try {
        final prompt = await _chatPrompt(deps);
        await for (final piece in engine.generate(
            prompt,
            GenerationOptions(
                temperature: deps.settings.chatTemperature, maxTokens: deps.compiler.maxOutputTokens))) {
          final m = _item<AssistantMessage>(id);
          if (m != null) _replace(m.copyWith(text: m.text + piece));
        }
        final m = _item<AssistantMessage>(id);
        if (m != null) _replace(m.copyWith(done: true));
      } catch (e) {
        final m = _item<AssistantMessage>(id);
        final cancelled = e is LlamaException && e.isCancelled;
        if (m != null) {
          _replace(m.copyWith(done: true, error: cancelled ? 'Stopped' : _describe(e)));
        }
      }
    });
    _plainEngine = null;
  }

  Future<String> _chatPrompt(ChatDeps deps) async {
    final turns = <ChatMessage>[];
    for (final item in state.items.reversed.skip(1)) {
      final m = switch (item) {
        UserMessage(:final text) when !text.startsWith('/') => ChatMessage.user(text),
        AssistantMessage(:final text, :final error) when error == null && text.isNotEmpty =>
          ChatMessage.assistant(text),
        _ => null,
      };
      if (m != null) turns.insert(0, m);
      if (turns.length >= 12) break;
    }
    // Drop the oldest turns until the prompt fits.
    while (true) {
      final prompt =
          QwenChatTemplate.render([const ChatMessage.system(_chatSystemPrompt), ...turns]);
      if (turns.length <= 1 || await deps.engine.tokenCount(prompt) <= deps.compiler.promptBudget) {
        return prompt;
      }
      turns.removeAt(0);
    }
  }

  Future<void> _busy(ChatDeps deps, Future<void> Function() work) async {
    state = state.copyWith(busy: true);
    await _keepScreenOn(deps, true);
    try {
      await work();
    } finally {
      await _keepScreenOn(deps, false);
      state = state.copyWith(busy: false);
    }
  }

  Future<void> _keepScreenOn(ChatDeps deps, bool on) async {
    try {
      await deps.device.setKeepScreenOn(on);
    } catch (_) {
      // Not fatal: the run is just slower if the screen turns off.
    }
  }

  SkillSuggestion? _resolve(int id) {
    final s = _item<SkillSuggestion>(id);
    if (s == null || s.resolved) return null;
    _replace(SkillSuggestion(s.id, s.skillName, s.message, s.score, resolved: true));
    return s;
  }

  static String _describe(Object e) => switch (e) {
        SkillInputException(:final problems) => problems.join('\n'),
        SkillOutputException(:final message) => message,
        McpException(:final message) => message,
        LlamaException(:final message) => message,
        StateError(:final message) => message,
        _ => e.toString(),
      };

  int _id() => _nextId++;

  void _add(ChatItem item) => state = state.copyWith(items: [...state.items, item]);

  void _replace(ChatItem item) => state = state.copyWith(
      items: [for (final i in state.items) i.id == item.id ? item : i]);

  T? _item<T extends ChatItem>(int id) {
    for (final i in state.items) {
      if (i.id == id && i is T) return i;
    }
    return null;
  }
}

final chatControllerProvider =
    NotifierProvider<ChatController, ChatState>(ChatController.new);
