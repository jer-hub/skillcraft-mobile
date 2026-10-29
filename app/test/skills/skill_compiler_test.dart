import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skillcraft/core/config.dart';
import 'package:skillcraft/mcp/tool_spec.dart';
import 'package:skillcraft/skills/skill.dart';
import 'package:skillcraft/skills/skill_compiler.dart';
import 'package:skillcraft/skills/skill_parser.dart';

import '../support/fakes.dart';

const saveTool = ToolSpec(
  name: 'save_task_to_db',
  description: 'Saves a task.',
  inputSchema: {
    'type': 'object',
    'properties': {
      'title': {'type': 'string'},
      'priority': {'type': 'string'},
    },
    'required': ['title', 'priority'],
  },
);

void main() {
  final extractTasks =
      parseSkill(File('assets/skills/extract-tasks.md').readAsStringSync());
  final multiInput = parseSkill('''
---
name: plan
description: Plans.
inputs:
  goal: {type: string, required: true}
  days: {type: integer, default: 3}
  strict: {type: boolean}
  mode: {type: string, enum: [fast, careful]}
tools: [save_task_to_db, missing_tool]
output_schema:
  type: object
  properties:
    steps: {type: array, items: {type: string}}
  required: [steps]
---
Make a plan.
''');

  late FakeEngine engine;
  late SkillCompiler compiler;

  setUp(() {
    engine = FakeEngine();
    compiler = SkillCompiler(engine);
  });

  group('invocation parsing', () {
    test('splits slash commands', () {
      expect(SkillCompiler.parseInvocation('/extract-tasks call Ana\nby Friday'),
          ('extract-tasks', 'call Ana\nby Friday'));
      expect(SkillCompiler.parseInvocation('/extract-tasks'), ('extract-tasks', ''));
      expect(SkillCompiler.parseInvocation('hello'), isNull);
    });

    test('free text goes to the single string input', () {
      expect(SkillCompiler.parseArguments(extractTasks, ' notes here '),
          {'raw_text': 'notes here'});
    });

    test('JSON objects map directly', () {
      expect(SkillCompiler.parseArguments(multiInput, '{"goal":"x","days":2}'),
          {'goal': 'x', 'days': 2});
    });

    test('ambiguous free text is rejected', () {
      final twoStrings = parseSkill('''
---
name: two
description: d
inputs:
  a: {type: string, required: true}
  b: {type: string, required: true}
output_schema: {type: object, properties: {}}
---
''');
      expect(() => SkillCompiler.parseArguments(twoStrings, 'text'),
          throwsA(isA<SkillInputException>()));
    });
  });

  group('input resolution', () {
    test('coerces strings, applies defaults', () {
      final inputs = SkillCompiler.resolveInputs(
          multiInput, {'goal': 'ship', 'strict': 'yes', 'mode': 'fast'});
      expect(inputs, {'goal': 'ship', 'days': 3, 'strict': true, 'mode': 'fast'});
    });

    test('reports all problems at once', () {
      try {
        SkillCompiler.resolveInputs(
            multiInput, {'days': 'soon', 'mode': 'reckless', 'extra': 1});
        fail('expected SkillInputException');
      } on SkillInputException catch (e) {
        expect(e.problems, hasLength(4));
        expect(e.toString(), contains('Missing required input "goal"'));
        expect(e.toString(), contains('"days" must be integer'));
        expect(e.toString(), contains('must be one of fast, careful'));
        expect(e.toString(), contains('Unknown input "extra"'));
      }
    });
  });

  group('compile', () {
    test('output-only skill uses its schema directly as the grammar', () async {
      final compiled = await compiler.compile(extractTasks, {'raw_text': 'Call Ana.'});

      expect(compiled.tools, isEmpty);
      expect(compiled.responseSchema, extractTasks.outputSchema);
      expect(engine.schemasConverted.single,
          jsonEncode(extractTasks.outputSchema));
      expect(compiled.prompt, startsWith('<|im_start|>system\nYou run the skill'));
      expect(compiled.prompt, contains('raw_text:\nCall Ana.'));
      expect(compiled.prompt, endsWith('<|im_start|>assistant\n'));
      expect(compiled.generationOptions.temperature, 0, reason: 'greedy');
      expect(compiled.generationOptions.grammar, compiled.grammar);
      expect(compiled.generationOptions.maxTokens, compiler.maxOutputTokens);
    });

    test('system prompt does not depend on inputs (prefix-cache friendly)',
        () async {
      final a = await compiler.compile(extractTasks, {'raw_text': 'one'});
      final b = await compiler.compile(extractTasks, {'raw_text': 'two'});
      expect(a.messages.first.content, b.messages.first.content);
      expect(engine.schemasConverted, hasLength(1), reason: 'grammar cached');
    });

    test('tools produce a final|tool_call envelope; unknown tools warn',
        () async {
      final compiled = await compiler.compile(multiInput, {'goal': 'x'},
          availableTools: const [saveTool]);

      expect(compiled.tools.map((t) => t.name), ['save_task_to_db']);
      expect(compiled.warnings.single, contains('missing_tool'));
      final variants = compiled.responseSchema['oneOf'] as List;
      expect(variants, hasLength(2));
      expect(compiled.messages.first.content, contains('save_task_to_db: Saves a task.'));
    });

    test('truncates the longest string input to fit the context', () async {
      final small = SkillCompiler(engine,
          config: const EngineConfig(contextTokens: 1024), maxOutputTokens: 256);
      final compiled =
          await small.compile(extractTasks, {'raw_text': 'word ' * 2000});

      expect(compiled.promptTokens, lessThanOrEqualTo(small.promptBudget));
      expect(compiled.inputs['raw_text'], endsWith('[...truncated]'));
      expect(compiled.warnings.single, contains('"raw_text" was truncated'));
    });
  });

  group('parse', () {
    test('accepts schema-valid output', () async {
      final compiled = await compiler.compile(extractTasks, {'raw_text': 'x'});
      final response = compiled.parse(
          '{"tasks":[{"title":"Send budget","priority":"high","due_date":"Friday"}]}');
      expect((response as FinalOutput).output, isA<Map>());
    });

    test('rejects non-JSON and schema violations', () async {
      final compiled = await compiler.compile(extractTasks, {'raw_text': 'x'});
      expect(() => compiled.parse('Sure! Here are your tasks'),
          throwsA(isA<SkillOutputException>()));
      expect(
          () => compiled.parse('{"tasks":[{"title":"x","priority":"urgent"}]}'),
          throwsA(isA<SkillOutputException>()));
    });

    test('drops placeholder values from optional fields only', () async {
      final compiled = await compiler.compile(extractTasks, {'raw_text': 'x'});
      final response = compiled.parse('{"tasks":['
          '{"title":"A","priority":"high","due_date":"None"},'
          '{"title":"B","priority":"low","due_date":" n/a "},'
          '{"title":"C","priority":"low","due_date":""},'
          '{"title":"D","priority":"medium","due_date":"Nov 15"},'
          '{"title":"None","priority":"low"}]}');

      final tasks = ((response as FinalOutput).output as Map)['tasks'] as List;
      expect(tasks.map((t) => (t as Map).containsKey('due_date')),
          [false, false, false, true, false]);
      expect(tasks[3]['due_date'], 'Nov 15');
      expect(tasks[4]['title'], 'None', reason: 'required fields are kept');
    });

    test('strips placeholders inside a tool-call envelope', () async {
      final compiled = await compiler.compile(multiInput, {'goal': 'x'},
          availableTools: const [saveTool]);
      final call = compiled.parse('{"type":"tool_call","tool":"save_task_to_db",'
          '"arguments":{"title":"t","priority":"low","note":"N/A"}}');
      expect((call as ToolCallRequest).arguments,
          {'title': 't', 'priority': 'low', 'note': 'N/A'},
          reason: 'unknown keys are left alone');
    });

    test('distinguishes tool calls from final output', () async {
      final compiled = await compiler.compile(multiInput, {'goal': 'x'},
          availableTools: const [saveTool]);

      final call = compiled.parse('{"type":"tool_call","tool":"save_task_to_db",'
          '"arguments":{"title":"t","priority":"low"}}');
      expect(call, isA<ToolCallRequest>());
      expect((call as ToolCallRequest).arguments['title'], 't');

      final done = compiled.parse('{"type":"final","output":{"steps":["a"]}}');
      expect((done as FinalOutput).output, {'steps': ['a']});
    });
  });

  test('input JSON schema reflects declared metadata', () {
    final mode = multiInput.input('mode')!;
    expect(mode.toJsonSchema(), {
      'type': 'string',
      'enum': ['fast', 'careful'],
    });
    expect(multiInput.inputs.map((i) => i.type),
        [InputType.string, InputType.integer, InputType.boolean, InputType.string]);
  });
}
