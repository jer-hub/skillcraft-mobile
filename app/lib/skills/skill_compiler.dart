import 'dart:convert';

import 'package:json_schema/json_schema.dart';
import 'package:llama_ffi/llama_ffi.dart' show GenerationOptions;

import '../core/config.dart';
import '../inference/chat_template.dart';
import '../inference/llama_engine.dart';
import '../mcp/tool_spec.dart';
import 'json_stream.dart';
import 'skill.dart';

/// Inputs that are missing, unknown or of the wrong type.
class SkillInputException implements Exception {
  const SkillInputException(this.problems);

  final List<String> problems;

  @override
  String toString() => problems.join('\n');
}

/// Model output that is not valid JSON or does not match the schema.
class SkillOutputException implements Exception {
  const SkillOutputException(this.message, this.raw);

  final String message;
  final String raw;

  @override
  String toString() => message;
}

/// What the model asked for in one step.
sealed class SkillResponse {
  const SkillResponse();
}

final class FinalOutput extends SkillResponse {
  const FinalOutput(this.output);
  final Object? output;
}

final class ToolCallRequest extends SkillResponse {
  const ToolCallRequest(this.tool, this.arguments);
  final String tool;
  final Map<String, Object?> arguments;
}

/// A skill ready to run: prompt, grammar and output validation.
class CompiledSkill {
  CompiledSkill._({
    required this.skill,
    required this.inputs,
    required this.tools,
    required this.messages,
    required this.prompt,
    required this.promptTokens,
    required this.responseSchema,
    required this.grammar,
    required this.generationOptions,
    required this.finalOnlyOptions,
    required this.warnings,
    required this._validator,
  });

  final Skill skill;

  /// Resolved inputs (coerced, defaults applied, possibly truncated).
  final Map<String, Object?> inputs;

  /// Tools offered to the model (empty: output-only skill).
  final List<ToolSpec> tools;
  final List<ChatMessage> messages;

  /// Rendered ChatML prompt, ending with an open assistant turn.
  final String prompt;
  final int promptTokens;

  /// Schema the raw model reply must match (the envelope when tools exist).
  final Map<String, Object?> responseSchema;
  final String grammar;

  /// Sampling settings to run this skill with (grammar included).
  final GenerationOptions generationOptions;

  /// Like [generationOptions], but the grammar only allows a final answer.
  /// The agent uses it on its last step so a run always terminates.
  final GenerationOptions finalOnlyOptions;

  /// Non-fatal adjustments, e.g. truncated inputs.
  final List<String> warnings;

  final JsonSchema _validator;

  /// Like [parse], but if the reply is unfinished (a repetition loop was
  /// stopped, or the token limit cut it off) falls back to the most complete
  /// prefix from [scanner] that closes cleanly and validates.
  ({SkillResponse response, bool partial}) parseOrSalvage(String raw, JsonStreamScanner scanner) {
    try {
      return (response: parse(raw), partial: false);
    } on SkillOutputException {
      for (final candidate in scanner.salvageCandidates().take(25)) {
        try {
          return (response: parse(candidate), partial: true);
        } on SkillOutputException {
          continue;
        }
      }
      rethrow;
    }
  }

  /// Parses and validates a model reply.
  ///
  /// Throws [SkillOutputException] if it is not valid against the schema;
  /// with the grammar active that indicates a converter gap, not the model.
  SkillResponse parse(String raw) {
    final Object? value;
    try {
      value = jsonDecode(raw);
    } on FormatException catch (e) {
      throw SkillOutputException('Reply is not JSON: ${e.message}', raw);
    }
    stripPlaceholders(value, responseSchema);
    final result = _validator.validate(value);
    if (!result.isValid) {
      throw SkillOutputException(
          'Reply does not match the schema: ${result.errors.join('; ')}', raw);
    }
    if (tools.isEmpty) return FinalOutput(value);

    final envelope = value as Map<String, Object?>;
    return envelope['type'] == 'tool_call'
        ? ToolCallRequest(envelope['tool'] as String,
            (envelope['arguments'] as Map).cast<String, Object?>())
        : FinalOutput(envelope['output']);
  }
}

final _placeholder = RegExp(
    r'^\s*(none|null|n/?a|tbd|tba|unknown|not (specified|mentioned|given)|-+)?\s*$',
    caseSensitive: false);

/// Removes optional string properties whose value is a placeholder such as
/// "None", "N/A" or "". Small models tend to fill every key they are shown,
/// and the grammar cannot express "any string except None". Required
/// properties are never touched. Mutates [value] in place.
void stripPlaceholders(Object? value, Map<String, Object?> schema) {
  final variants = schema['oneOf'] ?? schema['anyOf'];
  if (variants is List) {
    for (final v in variants.whereType<Map<String, Object?>>()) {
      if (_constsMatch(value, v)) stripPlaceholders(value, v);
    }
    return;
  }
  if (value is Map<String, Object?>) {
    final props = schema['properties'];
    if (props is! Map) return;
    final required = (schema['required'] as List?)?.toSet() ?? const {};
    value.removeWhere((key, v) =>
        props.containsKey(key) &&
        !required.contains(key) &&
        v is String &&
        _placeholder.hasMatch(v));
    for (final MapEntry(:key, value: child) in value.entries) {
      final sub = props[key];
      if (sub is Map<String, Object?>) stripPlaceholders(child, sub);
    }
  } else if (value is List) {
    final items = schema['items'];
    if (items is Map<String, Object?>) {
      // An item whose required text is a placeholder ({"title": "None"}) says
      // nothing; small models emit it when there is nothing to extract.
      value.removeWhere((item) => _hasPlaceholderRequired(item, items));
      for (final item in value) {
        stripPlaceholders(item, items);
      }
    }
  }
}

bool _hasPlaceholderRequired(Object? item, Map<String, Object?> schema) {
  if (item is! Map) return false;
  final required = schema['required'];
  if (required is! List) return false;
  return required.any((key) {
    final v = item[key];
    return v is String && _placeholder.hasMatch(v);
  });
}

/// Whether [value] carries every `const` property the [variant] demands.
bool _constsMatch(Object? value, Map<String, Object?> variant) {
  final props = variant['properties'];
  if (value is! Map || props is! Map) return false;
  return props.entries.every((e) {
    final sub = e.value;
    return sub is! Map || !sub.containsKey('const') || value[e.key] == sub['const'];
  });
}

/// Turns a [Skill] plus user inputs into a [CompiledSkill].
class SkillCompiler {
  SkillCompiler(
    this._engine, {
    this.config = const EngineConfig(),
    this.maxOutputTokens = 512,
    this.temperature = 0,
  });

  final InferenceEngine _engine;
  final EngineConfig config;

  /// Context reserved for the reply; the prompt gets the rest.
  final int maxOutputTokens;

  /// Skills decode greedily by default: on device, sampling at 0.2 made the
  /// same notes yield different (sometimes invented) due dates between runs.
  final double temperature;

  final _grammarCache = <String, String>{};

  int get promptBudget => config.contextTokens - maxOutputTokens;

  /// Maps the text after `/skill-name` onto the skill's inputs: a JSON object
  /// is used as-is; otherwise free text goes to the skill's only string input
  /// (or its only required one). Returns an empty map for empty [args].
  static Map<String, Object?> parseArguments(Skill skill, String args) {
    final text = args.trim();
    if (text.isEmpty) return {};
    if (text.startsWith('{')) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map) return decoded.cast<String, Object?>();
      } on FormatException {
        // Not JSON after all; treat as free text.
      }
    }
    final strings = skill.inputs.where((i) => i.type == InputType.string);
    final required = skill.inputs.where((i) => i.required);
    final target = strings.length == 1
        ? strings.single
        : required.length == 1
            ? required.single
            : null;
    if (target == null) {
      throw SkillInputException([
        '${skill.command} has several inputs; pass a JSON object or use the form',
      ]);
    }
    return {target.name: text};
  }

  /// Splits `/name rest of line` into the skill name and its argument text.
  static (String name, String args)? parseInvocation(String line) {
    final m = RegExp(r'^/([a-z0-9-]+)(?:\s+([\s\S]*))?$').firstMatch(line.trim());
    return m == null ? null : (m.group(1)!, m.group(2) ?? '');
  }

  Future<CompiledSkill> compile(
    Skill skill,
    Map<String, Object?> rawInputs, {
    List<ToolSpec> availableTools = const [],
  }) async {
    final inputs = resolveInputs(skill, rawInputs);
    final tools = [
      for (final name in skill.tools)
        ...availableTools.where((t) => t.name == name),
    ];
    final missingTools = skill.tools
        .where((name) => !tools.any((t) => t.name == name))
        .toList();
    final warnings = [
      if (missingTools.isNotEmpty)
        'Unavailable tools skipped: ${missingTools.join(', ')}',
    ];

    final system = buildSystemPrompt(skill, tools);
    var messages = [
      ChatMessage.system(system),
      ChatMessage.user(buildUserMessage(skill, inputs)),
    ];
    var prompt = QwenChatTemplate.render(messages);
    var tokens = await _engine.tokenCount(prompt);

    // Over budget: shorten the longest string input and try again.
    for (var attempt = 0; tokens > promptBudget && attempt < 4; attempt++) {
      final longest = _longestStringInput(inputs);
      if (longest == null) break;
      final value = inputs[longest] as String;
      final overflow = tokens - promptBudget;
      // ~4 chars per token for English; cut a little extra to converge fast.
      final keep = value.length - (overflow * 4 + 64);
      if (keep <= 0) break;
      inputs[longest] = '${value.substring(0, keep)}\n[...truncated]';
      messages = [messages.first, ChatMessage.user(buildUserMessage(skill, inputs))];
      prompt = QwenChatTemplate.render(messages);
      tokens = await _engine.tokenCount(prompt);
      if (!warnings.any((w) => w.startsWith('Input "$longest"'))) {
        warnings.add('Input "$longest" was truncated to fit the '
            '${config.contextTokens}-token context');
      }
    }
    if (tokens > promptBudget) {
      throw SkillInputException([
        'Prompt is $tokens tokens; the limit is $promptBudget. '
            'Shorten the skill instructions or inputs.',
      ]);
    }

    final responseSchema = buildResponseSchema(skill, tools);
    final grammar = await _grammarFor(responseSchema);
    // Last agent step: same envelope, but only the `final` branch.
    final finalGrammar = tools.isEmpty
        ? grammar
        : await _grammarFor((responseSchema['oneOf'] as List).first as Map<String, Object?>);

    return CompiledSkill._(
      skill: skill,
      inputs: inputs,
      tools: tools,
      messages: messages,
      prompt: prompt,
      promptTokens: tokens,
      responseSchema: responseSchema,
      grammar: grammar,
      generationOptions: GenerationOptions(
        temperature: temperature,
        maxTokens: maxOutputTokens,
        grammar: grammar,
      ),
      finalOnlyOptions: GenerationOptions(
        temperature: temperature,
        maxTokens: maxOutputTokens,
        grammar: finalGrammar,
      ),
      warnings: warnings,
      validator: JsonSchema.create(responseSchema),
    );
  }

  Future<String> _grammarFor(Map<String, Object?> schema) async {
    final json = jsonEncode(schema);
    return _grammarCache[json] ??= await _engine.schemaToGbnf(json);
  }

  /// Applies defaults, checks required inputs and coerces string values to
  /// the declared types. Throws [SkillInputException] listing all problems.
  static Map<String, Object?> resolveInputs(
      Skill skill, Map<String, Object?> raw) {
    final problems = <String>[
      for (final key in raw.keys)
        if (skill.input(key) == null) 'Unknown input "$key"',
    ];
    final resolved = <String, Object?>{};
    for (final input in skill.inputs) {
      var value = raw[input.name] ?? input.defaultValue;
      if (value is String && value.trim().isEmpty && input.type != InputType.string) {
        value = null;
      }
      if (value == null || (value is String && value.trim().isEmpty)) {
        if (input.required) problems.add('Missing required input "${input.name}"');
        continue;
      }
      final coerced = _coerce(input, value);
      if (coerced == null) {
        problems.add('Input "${input.name}" must be ${input.type.name}');
        continue;
      }
      if (input.enumValues != null && !input.enumValues!.contains(coerced)) {
        problems.add(
            'Input "${input.name}" must be one of ${input.enumValues!.join(', ')}');
        continue;
      }
      resolved[input.name] = coerced;
    }
    if (problems.isNotEmpty) throw SkillInputException(problems);
    return resolved;
  }

  /// System prompt: static per skill (and tool set), so the engine's
  /// prefix cache can reuse it across runs.
  static String buildSystemPrompt(Skill skill, List<ToolSpec> tools) {
    final b = StringBuffer()
      ..writeln('You run the skill "${skill.name}": ${skill.description}')
      ..writeln()
      ..writeln(skill.instructions)
      ..writeln();
    if (tools.isEmpty) {
      b
        ..writeln('Reply with one JSON value matching this schema, nothing else:')
        ..write(jsonEncode(skill.outputSchema));
    } else {
      b.writeln('Tools you may call:');
      for (final t in tools) {
        b.writeln('- ${t.name}: ${t.description} '
            'Arguments: ${jsonEncode(t.inputSchema)}');
      }
      b
        ..writeln()
        ..writeln('Reply with JSON only. To call one tool: '
            '{"type":"tool_call","tool":"<name>","arguments":{...}}')
        ..writeln('To finish: {"type":"final","output":<output>} where output '
            'matches: ${jsonEncode(skill.outputSchema)}');
    }
    return b.toString().trimRight();
  }

  /// User turn: the inputs, last, so the system prompt stays cacheable.
  static String buildUserMessage(Skill skill, Map<String, Object?> inputs) {
    if (inputs.isEmpty) return 'Run the skill.';
    final b = StringBuffer('Inputs:');
    for (final MapEntry(:key, :value) in inputs.entries) {
      b
        ..writeln()
        ..writeln()
        ..writeln('$key:')
        ..write(value is String ? value : jsonEncode(value));
    }
    return b.toString();
  }

  /// The skill's output schema, or a `final | tool_call` envelope when the
  /// model may call tools.
  static Map<String, Object?> buildResponseSchema(
      Skill skill, List<ToolSpec> tools) {
    if (tools.isEmpty) return skill.outputSchema;
    return {
      'oneOf': [
        {
          'type': 'object',
          'properties': {
            'type': {'const': 'final'},
            'output': skill.outputSchema,
          },
          'required': ['type', 'output'],
          'additionalProperties': false,
        },
        for (final t in tools)
          {
            'type': 'object',
            'properties': {
              'type': {'const': 'tool_call'},
              'tool': {'const': t.name},
              'arguments': t.inputSchema,
            },
            'required': ['type', 'tool', 'arguments'],
            'additionalProperties': false,
          },
      ],
    };
  }

  static String? _longestStringInput(Map<String, Object?> inputs) {
    String? best;
    var bestLen = 0;
    for (final MapEntry(:key, :value) in inputs.entries) {
      if (value is String && value.length > bestLen) {
        best = key;
        bestLen = value.length;
      }
    }
    return best;
  }

  static Object? _coerce(SkillInput input, Object value) {
    switch (input.type) {
      case InputType.string:
        return value is String ? value : jsonEncode(value);
      case InputType.number:
        return value is num ? value : num.tryParse(value.toString().trim());
      case InputType.integer:
        if (value is int) return value;
        if (value is double && value == value.truncateToDouble()) return value.toInt();
        return int.tryParse(value.toString().trim());
      case InputType.boolean:
        if (value is bool) return value;
        return switch (value.toString().trim().toLowerCase()) {
          'true' || 'yes' || '1' => true,
          'false' || 'no' || '0' => false,
          _ => null,
        };
      case InputType.array:
      case InputType.object:
        Object? v = value;
        if (v is String) {
          try {
            v = jsonDecode(v);
          } on FormatException {
            return null;
          }
        }
        final ok = input.type == InputType.array ? v is List : v is Map;
        return ok ? v : null;
    }
  }
}
