import 'package:json_schema/json_schema.dart';
import 'package:yaml/yaml.dart';

import 'skill.dart';

/// A problem in a skill file. [line] is 1-based within the whole file.
class SkillIssue {
  const SkillIssue(this.message, {this.line});

  final String message;
  final int? line;

  @override
  String toString() => line == null ? message : 'line $line: $message';
}

class SkillFormatException implements Exception {
  const SkillFormatException(this.issues);

  final List<SkillIssue> issues;

  @override
  String toString() => 'Invalid skill:\n${issues.join('\n')}';
}

final _namePattern = RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$');
final _delimiter = RegExp(r'^---\s*$');

/// Parses a skill Markdown file: YAML frontmatter between `---` lines, then
/// the instruction body. Reports every problem found, not just the first.
///
/// Throws [SkillFormatException].
Skill parseSkill(String source, {String? path}) {
  final text = source.replaceAll('\r\n', '\n').replaceFirst('﻿', '');
  final lines = text.split('\n');

  if (lines.isEmpty || !_delimiter.hasMatch(lines.first)) {
    throw const SkillFormatException(
        [SkillIssue('File must start with a "---" frontmatter line', line: 1)]);
  }
  final close = lines.indexWhere(_delimiter.hasMatch, 1);
  if (close < 0) {
    throw const SkillFormatException(
        [SkillIssue('Frontmatter is missing its closing "---" line')]);
  }

  // YAML line 0 is file line 2.
  const lineOffset = 2;
  final YamlNode root;
  try {
    root = loadYamlNode(lines.sublist(1, close).join('\n'));
  } on YamlException catch (e) {
    throw SkillFormatException([
      SkillIssue(e.message,
          line: e.span == null ? null : e.span!.start.line + lineOffset),
    ]);
  }
  if (root is! YamlMap) {
    throw const SkillFormatException(
        [SkillIssue('Frontmatter must be a YAML mapping', line: 2)]);
  }
  final YamlMap doc = root;

  final issues = <SkillIssue>[];
  int? lineOf(YamlNode? node) =>
      node == null ? null : node.span.start.line + lineOffset;
  void issue(String message, [YamlNode? node]) =>
      issues.add(SkillIssue(message, line: lineOf(node ?? doc)));

  String? requiredString(String key) {
    final node = doc.nodes[key];
    final value = node?.value;
    if (value is String && value.trim().isNotEmpty) return value.trim();
    issue(node == null ? 'Missing "$key"' : '"$key" must be a non-empty string',
        node);
    return null;
  }

  final name = requiredString('name');
  if (name != null && !_namePattern.hasMatch(name)) {
    issue('"name" must be kebab-case (a-z, 0-9, -), got "$name"',
        doc.nodes['name']);
  }
  final description = requiredString('description');

  final inputs = _parseInputs(doc.nodes['inputs'], issue);

  final schemaNode = doc.nodes['output_schema'];
  Map<String, Object?> outputSchema = const {};
  if (schemaNode == null) {
    issue('Missing "output_schema"');
  } else if (schemaNode is! YamlMap) {
    issue('"output_schema" must be a mapping', schemaNode);
  } else {
    outputSchema = _toPlain(schemaNode) as Map<String, Object?>;
    try {
      JsonSchema.create(outputSchema);
    } on FormatException catch (e) {
      issue('"output_schema" is not valid JSON Schema: ${e.message}',
          schemaNode);
    }
  }

  final tools = <String>[];
  final toolsNode = doc.nodes['tools'];
  if (toolsNode != null) {
    if (toolsNode is YamlList && toolsNode.nodes.every((n) => n.value is String)) {
      tools.addAll(toolsNode.nodes.map((n) => n.value as String));
    } else {
      issue('"tools" must be a list of tool names', toolsNode);
    }
  }

  final onOutput =
      _parseOnOutput(doc.nodes['on_output'], outputSchema, issue);

  if (issues.isNotEmpty) throw SkillFormatException(issues);

  return Skill(
    name: name!,
    description: description!,
    inputs: inputs,
    outputSchema: outputSchema,
    instructions: lines.sublist(close + 1).join('\n').trim(),
    tools: tools,
    onOutput: onOutput,
    source: source,
    path: path,
  );
}

List<SkillInput> _parseInputs(
    YamlNode? node, void Function(String, [YamlNode?]) issue) {
  if (node == null) return const [];
  if (node is! YamlMap) {
    issue('"inputs" must be a mapping of input names', node);
    return const [];
  }
  final inputs = <SkillInput>[];
  for (final entry in node.nodes.entries) {
    final key = (entry.key as YamlNode).value;
    final spec = entry.value;
    if (key is! String || spec is! YamlMap) {
      issue('Input "$key" must be a mapping with a "type"', entry.value);
      continue;
    }
    final typeName = spec['type'];
    final type = InputType.values.where((t) => t.name == typeName).firstOrNull;
    if (type == null) {
      issue('Input "$key" has unsupported type "$typeName" '
          '(use ${InputType.values.map((t) => t.name).join(', ')})',
          spec.nodes['type'] ?? spec);
      continue;
    }
    final enumNode = spec.nodes['enum'];
    if (enumNode != null && enumNode is! YamlList) {
      issue('Input "$key": "enum" must be a list', enumNode);
    }
    final requiredValue = spec['required'] ?? false;
    if (requiredValue is! bool) {
      issue('Input "$key": "required" must be true or false',
          spec.nodes['required']);
    }
    inputs.add(SkillInput(
      name: key,
      type: type,
      description: (spec['description'] as Object?)?.toString() ?? '',
      required: requiredValue == true,
      enumValues: enumNode is YamlList ? _toPlain(enumNode) as List<Object?> : null,
      defaultValue: _toPlain(spec.nodes['default']),
    ));
  }
  return inputs;
}

OnOutput? _parseOnOutput(YamlNode? node, Map<String, Object?> outputSchema,
    void Function(String, [YamlNode?]) issue) {
  if (node == null) return null;
  if (node is! YamlMap || node['tool'] is! String) {
    issue('"on_output" must be a mapping with a "tool" name', node);
    return null;
  }
  final tool = node['tool'] as String;
  final forEach = node['for_each'];
  if (forEach != null && forEach is! String) {
    issue('"on_output.for_each" must be a property name', node.nodes['for_each']);
    return null;
  }
  if (forEach is String) {
    final props = outputSchema['properties'];
    final prop = props is Map ? props[forEach] : null;
    if (prop is! Map || prop['type'] != 'array') {
      issue('"on_output.for_each" must name an array property of output_schema',
          node.nodes['for_each']);
    }
  }
  return OnOutput(tool: tool, forEach: forEach as String?);
}

/// Converts YAML nodes into plain Dart maps/lists for JSON use.
Object? _toPlain(Object? node) => switch (node) {
      YamlMap m => <String, Object?>{
          for (final e in m.nodes.entries)
            (e.key as YamlNode).value.toString(): _toPlain(e.value),
        },
      YamlList l => [for (final n in l.nodes) _toPlain(n)],
      YamlScalar s => s.value,
      _ => node,
    };
