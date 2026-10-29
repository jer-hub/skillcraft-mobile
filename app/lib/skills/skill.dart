/// JSON types a skill input may declare.
enum InputType { string, number, integer, boolean, array, object }

/// One entry of a skill's `inputs:` frontmatter block.
class SkillInput {
  const SkillInput({
    required this.name,
    required this.type,
    this.description = '',
    this.required = false,
    this.enumValues,
    this.defaultValue,
  });

  final String name;
  final InputType type;
  final String description;
  final bool required;
  final List<Object?>? enumValues;
  final Object? defaultValue;

  /// JSON Schema for this input, used for validation and tool-style prompts.
  Map<String, Object?> toJsonSchema() => {
        'type': type.name,
        if (description.isNotEmpty) 'description': description,
        if (enumValues != null) 'enum': enumValues,
      };
}

/// SkillCraft extension: call a tool deterministically for each item of an
/// output array, so a small model doesn't have to emit N tool calls.
class OnOutput {
  const OnOutput({required this.tool, this.forEach});

  final String tool;

  /// Top-level array property of the output to iterate; null calls the tool
  /// once with the whole output.
  final String? forEach;
}

/// A parsed skill playbook (mattpocock/skills format plus SkillCraft fields).
class Skill {
  const Skill({
    required this.name,
    required this.description,
    required this.inputs,
    required this.outputSchema,
    required this.instructions,
    required this.source,
    this.tools = const [],
    this.onOutput,
    this.path,
  });

  /// Kebab-case identifier, also the slash command (`/name`).
  final String name;
  final String description;

  /// Inputs in declaration order.
  final List<SkillInput> inputs;

  /// JSON Schema the final output must satisfy.
  final Map<String, Object?> outputSchema;

  /// Markdown body after the frontmatter.
  final String instructions;

  /// Tool names the model may call (SkillCraft extension).
  final List<String> tools;
  final OnOutput? onOutput;

  /// Full file text, used for change detection and caching.
  final String source;
  final String? path;

  String get command => '/$name';

  SkillInput? input(String name) {
    for (final i in inputs) {
      if (i.name == name) return i;
    }
    return null;
  }
}
