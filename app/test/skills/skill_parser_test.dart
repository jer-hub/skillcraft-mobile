import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skillcraft/skills/skill.dart';
import 'package:skillcraft/skills/skill_parser.dart';

List<SkillIssue> issuesOf(String source) {
  try {
    parseSkill(source);
  } on SkillFormatException catch (e) {
    return e.issues;
  }
  fail('expected SkillFormatException');
}

const _minimal = '''
---
name: summarize
description: Summarizes text.
output_schema:
  type: object
  properties:
    summary:
      type: string
---
Summarize it.
''';

void main() {
  test('parses the bundled extract-tasks skill', () {
    final skill =
        parseSkill(File('assets/skills/extract-tasks.md').readAsStringSync());

    expect(skill.name, 'extract-tasks');
    expect(skill.command, '/extract-tasks');
    expect(skill.inputs.single.name, 'raw_text');
    expect(skill.inputs.single.type, InputType.string);
    expect(skill.inputs.single.required, isTrue);
    expect(
      ((skill.outputSchema['oneOf'] as List)[1]['properties'] as Map)['tasks'],
      containsPair('minItems', 1),
    );
    expect(skill.instructions, startsWith('# Instructions'));
    expect(skill.tools, isEmpty);
  });

  test('handles CRLF line endings and a BOM', () {
    final skill = parseSkill('﻿${_minimal.replaceAll('\n', '\r\n')}');
    expect(skill.name, 'summarize');
    expect(skill.instructions, 'Summarize it.');
  });

  test('reads SkillCraft extensions', () {
    final skill = parseSkill('''
---
name: save-tasks
description: Extracts and saves tasks.
tools: [save_task_to_db]
on_output:
  tool: save_task_to_db
  for_each: tasks
output_schema:
  type: object
  properties:
    tasks:
      type: array
      items: {type: object}
---
Do it.
''');
    expect(skill.tools, ['save_task_to_db']);
    expect(skill.onOutput?.tool, 'save_task_to_db');
    expect(skill.onOutput?.forEach, 'tasks');
  });

  test('rejects a file without frontmatter', () {
    expect(issuesOf('# Just markdown').single.line, 1);
  });

  test('rejects unclosed frontmatter', () {
    expect(issuesOf('---\nname: x\n').single.message, contains('closing'));
  });

  test('reports YAML syntax errors with the file line', () {
    final issue = issuesOf('---\nname: a\ndescription: [unclosed\n---\n').single;
    expect(issue.line, greaterThanOrEqualTo(3));
  });

  test('collects every problem with line numbers', () {
    final issues = issuesOf('''
---
name: Bad Name
inputs:
  count:
    type: float
output_schema:
  type: object
  minimum: 1
  exclusiveMinimum: "x"
---
''');
    final messages = issues.map((i) => i.message).join('\n');
    expect(messages, contains('kebab-case'));
    expect(messages, contains('Missing "description"'));
    expect(messages, contains('unsupported type "float"'));
    expect(issues.firstWhere((i) => i.message.contains('kebab')).line, 2);
    expect(issues.firstWhere((i) => i.message.contains('float')).line, 5);
  });

  test('rejects an invalid output_schema', () {
    final issues = issuesOf('''
---
name: x
description: y
output_schema:
  type: object
  properties: 5
---
''');
    expect(issues.single.message, contains('not valid JSON Schema'));
    expect(issues.single.line, 5);
  });

  test('on_output.for_each must name an array property', () {
    final issues = issuesOf(_minimal.replaceFirst(
        'output_schema:', 'on_output:\n  tool: t\n  for_each: summary\noutput_schema:'));
    expect(issues.single.message, contains('array property'));
  });
}
