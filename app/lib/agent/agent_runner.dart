import 'dart:async';

import 'package:llama_ffi/llama_ffi.dart' show GenerationOptions, LlamaException;

import '../inference/chat_template.dart';
import '../inference/llama_engine.dart';
import '../mcp/mcp_host.dart';
import '../skills/skill.dart';
import '../skills/json_stream.dart';
import '../skills/skill_compiler.dart';

/// Progress of one skill run, in order.
sealed class AgentEvent {
  const AgentEvent();
}

final class AgentCompiled extends AgentEvent {
  const AgentCompiled(this.compiled);
  final CompiledSkill compiled;
}

final class AgentStepStarted extends AgentEvent {
  const AgentStepStarted(this.step, {required this.finalOnly});
  final int step;

  /// The grammar only allows a final answer on this step.
  final bool finalOnly;
}

final class AgentToken extends AgentEvent {
  const AgentToken(this.text);
  final String text;
}

/// A model-requested tool call ([fromHook] false) or an `on_output` call.
final class AgentToolCall extends AgentEvent {
  const AgentToolCall(this.tool, this.arguments, {this.fromHook = false});
  final String tool;
  final Map<String, Object?> arguments;
  final bool fromHook;
}

final class AgentToolResult extends AgentEvent {
  const AgentToolResult(this.tool, this.result, {this.fromHook = false});
  final String tool;
  final ToolResult result;
  final bool fromHook;
}

final class AgentFinished extends AgentEvent {
  const AgentFinished(this.output, {required this.steps, this.partial = false});
  final Object? output;
  final int steps;

  /// The model's reply was cut short (loop or length limit); [output] holds
  /// the items that were complete.
  final bool partial;
}

final class AgentFailed extends AgentEvent {
  const AgentFailed(this.error, {this.cancelled = false});
  final Object error;
  final bool cancelled;
}

/// Runs a skill end to end: compile, constrained generation, tool dispatch
/// through MCP, repeat (bounded), then the deterministic `on_output` hook.
class AgentRunner {
  AgentRunner({
    required this._engine,
    required this._compiler,
    required this._mcp,
    this.maxSteps = 3,
    this.maxToolResultChars = 1500,
  });

  final InferenceEngine _engine;
  final SkillCompiler _compiler;
  final McpHost _mcp;

  /// Generation rounds per run (2048-token context keeps this small).
  final int maxSteps;

  /// Tool output fed back to the model is clipped to this length.
  final int maxToolResultChars;

  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    _engine.cancel();
  }

  /// Runs [skill]. The stream always ends with [AgentFinished] or
  /// [AgentFailed]; it does not emit errors.
  Stream<AgentEvent> run(Skill skill, Map<String, Object?> inputs) async* {
    _cancelled = false;
    try {
      final compiled =
          await _compiler.compile(skill, inputs, availableTools: _mcp.tools);
      yield AgentCompiled(compiled);

      final messages = List.of(compiled.messages);
      final lastStep = compiled.tools.isEmpty ? 1 : maxSteps;
      for (var step = 1; step <= lastStep; step++) {
        final finalOnly = step == lastStep;
        yield AgentStepStarted(step, finalOnly: finalOnly);

        final prompt = step == 1 ? compiled.prompt : QwenChatTemplate.render(messages);
        var promptTokens = compiled.promptTokens;
        if (step > 1) {
          promptTokens = await _engine.tokenCount(prompt);
          if (promptTokens > _compiler.promptBudget) {
            throw SkillInputException([
              'Context full after step ${step - 1}: $promptTokens tokens '
                  '(limit ${_compiler.promptBudget})',
            ]);
          }
        }

        // Let the reply use whatever context is left, not a fixed slice.
        final base = finalOnly ? compiled.finalOnlyOptions : compiled.generationOptions;
        final options = GenerationOptions(
          temperature: base.temperature,
          topP: base.topP,
          seed: base.seed,
          grammar: base.grammar,
          maxTokens: _compiler.config.contextTokens - promptTokens - 8,
        );

        final raw = StringBuffer();
        final scanner = JsonStreamScanner();
        var loopStopped = false;
        try {
          await for (final piece in _engine.generate(prompt, options)) {
            raw.write(piece);
            scanner.add(piece);
            yield AgentToken(piece);
            if (!loopStopped && scanner.isLooping) {
              loopStopped = true;
              _engine.cancel();
            }
          }
        } on LlamaException catch (e) {
          // Our own loop stop surfaces as a cancellation; anything else is real.
          if (!(loopStopped && e.isCancelled && !_cancelled)) rethrow;
        }
        if (_cancelled) throw const _Cancelled();

        final (:response, :partial) = compiled.parseOrSalvage(raw.toString(), scanner);
        switch (response) {
          case FinalOutput(:final output):
            yield* _runHook(skill, output);
            yield AgentFinished(output, steps: step, partial: partial);
            return;
          case ToolCallRequest(:final tool, :final arguments):
            yield AgentToolCall(tool, arguments);
            final result = await _call(tool, arguments);
            yield AgentToolResult(tool, result);
            if (_cancelled) throw const _Cancelled();
            messages
              ..add(ChatMessage.assistant(raw.toString()))
              ..add(ChatMessage.tool(_clip(
                  result.isError ? 'Error: ${result.text}' : result.text)));
        }
      }
      // Unreachable: the last step's grammar only allows a final answer.
      throw StateError('Agent ended without a final answer');
    } on _Cancelled {
      yield const AgentFailed('Cancelled', cancelled: true);
    } on LlamaException catch (e) {
      yield AgentFailed(e, cancelled: e.isCancelled || _cancelled);
    } catch (e) {
      yield AgentFailed(e, cancelled: _cancelled);
    }
  }

  /// `on_output`: call the hook tool once, or once per item of an array.
  Stream<AgentEvent> _runHook(Skill skill, Object? output) async* {
    final hook = skill.onOutput;
    if (hook == null) return;
    final spec = _mcp.tool(hook.tool);
    if (spec == null) throw McpException('on_output tool "${hook.tool}" is not available');

    final List<Object?> items;
    if (hook.forEach == null) {
      items = [output];
    } else {
      final list = output is Map ? output[hook.forEach] : null;
      items = list is List ? list : const [];
    }
    // Pass only the properties the tool declares.
    final allowed = (spec.inputSchema['properties'] as Map?)?.keys.toSet();
    for (final item in items) {
      if (_cancelled) throw const _Cancelled();
      if (item is! Map) continue;
      final args = {
        for (final MapEntry(:key, :value) in item.cast<String, Object?>().entries)
          if (allowed == null || allowed.contains(key)) key: value,
      };
      yield AgentToolCall(hook.tool, args, fromHook: true);
      yield AgentToolResult(hook.tool, await _call(hook.tool, args), fromHook: true);
    }
  }

  Future<ToolResult> _call(String tool, Map<String, Object?> args) async {
    try {
      return await _mcp.callTool(tool, args);
    } on McpException catch (e) {
      return ToolResult(text: e.message, isError: true);
    }
  }

  String _clip(String text) => text.length <= maxToolResultChars
      ? text
      : '${text.substring(0, maxToolResultChars)}\n[...truncated]';
}

class _Cancelled implements Exception {
  const _Cancelled();
}
