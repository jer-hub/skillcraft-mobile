import '../mcp/mcp_host.dart';
import '../skills/skill.dart';

/// One entry in the conversation. Items are immutable; the controller
/// replaces an item (same [id]) when it changes.
sealed class ChatItem {
  const ChatItem(this.id);
  final int id;
}

final class UserMessage extends ChatItem {
  const UserMessage(super.id, this.text);
  final String text;
}

/// A plain (unconstrained) model reply.
final class AssistantMessage extends ChatItem {
  const AssistantMessage(super.id, this.text, {this.done = false, this.error});
  final String text;
  final bool done;
  final String? error;

  AssistantMessage copyWith({String? text, bool? done, String? error}) =>
      AssistantMessage(id, text ?? this.text, done: done ?? this.done, error: error ?? this.error);
}

/// "Run /skill?" offered for a plain message; nothing runs until accepted.
final class SkillSuggestion extends ChatItem {
  const SkillSuggestion(super.id, this.skillName, this.message, this.score,
      {this.resolved = false});
  final String skillName;

  /// The user's message, used as the skill's argument text if accepted.
  final String message;
  final double score;
  final bool resolved;
}

enum RunStatus { running, finished, failed, cancelled }

class ToolCallView {
  const ToolCallView(this.tool, this.arguments, {this.fromHook = false, this.result});
  final String tool;
  final Map<String, Object?> arguments;
  final bool fromHook;

  /// Null while the call is in flight.
  final ToolResult? result;

  ToolCallView withResult(ToolResult r) =>
      ToolCallView(tool, arguments, fromHook: fromHook, result: r);
}

/// A skill run, built up from agent events.
final class SkillRun extends ChatItem {
  const SkillRun(
    super.id,
    this.skillName, {
    this.status = RunStatus.running,
    this.step = 0,
    this.streamed = '',
    this.toolCalls = const [],
    this.output,
    this.error,
    this.warnings = const [],
    this.promptTokens,
    this.elapsedMs,
  });

  final String skillName;
  final RunStatus status;
  final int step;

  /// Raw model output of the current step (JSON as it streams in).
  final String streamed;
  final List<ToolCallView> toolCalls;
  final Object? output;
  final String? error;
  final List<String> warnings;
  final int? promptTokens;
  final int? elapsedMs;

  SkillRun copyWith({
    RunStatus? status,
    int? step,
    String? streamed,
    List<ToolCallView>? toolCalls,
    Object? output,
    String? error,
    List<String>? warnings,
    int? promptTokens,
    int? elapsedMs,
  }) =>
      SkillRun(
        id,
        skillName,
        status: status ?? this.status,
        step: step ?? this.step,
        streamed: streamed ?? this.streamed,
        toolCalls: toolCalls ?? this.toolCalls,
        output: output ?? this.output,
        error: error ?? this.error,
        warnings: warnings ?? this.warnings,
        promptTokens: promptTokens ?? this.promptTokens,
        elapsedMs: elapsedMs ?? this.elapsedMs,
      );
}

/// Inputs still needed before a skill can run (shown as a form).
class InputRequest {
  const InputRequest(this.skill, this.initial, {this.problems = const []});
  final Skill skill;
  final Map<String, Object?> initial;
  final List<String> problems;
}

class ChatState {
  const ChatState({this.items = const [], this.busy = false, this.inputRequest});

  final List<ChatItem> items;
  final bool busy;
  final InputRequest? inputRequest;

  ChatState copyWith({List<ChatItem>? items, bool? busy, InputRequest? inputRequest,
          bool clearInputRequest = false}) =>
      ChatState(
        items: items ?? this.items,
        busy: busy ?? this.busy,
        inputRequest: clearInputRequest ? null : inputRequest ?? this.inputRequest,
      );
}
