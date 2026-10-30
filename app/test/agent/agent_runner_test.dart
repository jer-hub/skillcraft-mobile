import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skillcraft/agent/agent_runner.dart';
import 'package:skillcraft/mcp/mcp_host.dart';
import 'package:skillcraft/skills/skill_compiler.dart';
import 'package:skillcraft/skills/skill_parser.dart';

import '../support/fakes.dart';

const _saveSchema = {
  'type': 'object',
  'properties': {
    'title': {'type': 'string'},
    'priority': {'type': 'string'},
    'due_date': {'type': 'string'},
  },
  'required': ['title', 'priority'],
};

final _withTools = parseSkill('''
---
name: plan-day
description: Plans the day.
inputs:
  goal: {type: string, required: true}
tools: [list_tasks]
output_schema:
  type: object
  properties:
    summary: {type: string}
  required: [summary]
---
Look at the tasks, then summarize.
''');

final _withHook = parseSkill('''
---
name: save-tasks
description: Extracts and saves tasks.
inputs:
  raw_text: {type: string, required: true}
on_output:
  tool: save_task_to_db
  for_each: tasks
output_schema:
  type: object
  properties:
    tasks:
      type: array
      items:
        type: object
        properties:
          title: {type: string}
          priority: {type: string}
          extra: {type: string}
        required: [title, priority]
---
Extract tasks.
''');

void main() {
  late McpHost mcp;
  late FakeMcpTransport server;

  setUp(() async {
    mcp = McpHost();
    server = FakeMcpTransport('DB', {
      'list_tasks': (_) => '{"tasks":[{"title":"Ship"}]}',
      'save_task_to_db': (args) =>
          args['title'] == 'fail' ? throw 'constraint failed' : 'saved ${args['title']}',
    }, schemas: {'save_task_to_db': _saveSchema});
    await mcp.connect('db', server);
  });
  tearDown(() => mcp.dispose());

  AgentRunner runner(FakeEngine engine, {int maxSteps = 3}) => AgentRunner(
      engine: engine, compiler: SkillCompiler(engine), mcp: mcp, maxSteps: maxSteps);

  test('output-only skill finishes in one step', () async {
    final skill =
        parseSkill(File('assets/skills/extract-tasks.md').readAsStringSync());
    final engine = FakeEngine(['{"tasks":[{"title":"A","priority":"low"}]}']);

    final events = await runner(engine).run(skill, {'raw_text': 'notes'}).toList();

    final finished = events.last as AgentFinished;
    expect(finished.steps, 1);
    expect((finished.output as Map)['tasks'], hasLength(1));
    expect(events.whereType<AgentToolCall>(), isEmpty);
    expect(engine.prompts, hasLength(1));
  });

  test('calls a tool, feeds the result back, then finishes', () async {
    final engine = FakeEngine([
      '{"type":"tool_call","tool":"list_tasks","arguments":{}}',
      '{"type":"final","output":{"summary":"One task: Ship"}}',
    ]);

    final events = await runner(engine).run(_withTools, {'goal': 'focus'}).toList();

    expect(events.map((e) => e.runtimeType.toString()).where((t) => t != 'AgentToken'), [
      'AgentCompiled',
      'AgentStepStarted',
      'AgentToolCall',
      'AgentToolResult',
      'AgentStepStarted',
      'AgentFinished',
    ]);
    expect((events.last as AgentFinished).output, {'summary': 'One task: Ship'});
    // Step 2's prompt extends step 1's (prefix-cache friendly) with the result.
    expect(engine.prompts[1], startsWith(engine.prompts[0].substring(0, 200)));
    expect(engine.prompts[1], contains('<tool_response>\n{"tasks":[{"title":"Ship"}]}'));
  });

  test('last step only allows a final answer', () async {
    final engine = FakeEngine([
      '{"type":"tool_call","tool":"list_tasks","arguments":{}}',
      '{"type":"final","output":{"summary":"done"}}',
    ]);

    final events =
        await runner(engine, maxSteps: 2).run(_withTools, {'goal': 'g'}).toList();

    final steps = events.whereType<AgentStepStarted>().toList();
    expect(steps.map((s) => s.finalOnly), [false, true]);
    expect(engine.optionsSeen[0].grammar, isNot(engine.optionsSeen[1].grammar));
    expect(events.last, isA<AgentFinished>());
  });

  test('on_output calls the tool per item with declared fields only', () async {
    final engine = FakeEngine([
      '{"tasks":[{"title":"A","priority":"high","extra":"x"},'
          '{"title":"fail","priority":"low"}]}',
    ]);

    final events = await runner(engine).run(_withHook, {'raw_text': 't'}).toList();

    expect(server.calls.map((c) => c.$2), [
      {'title': 'A', 'priority': 'high'},
      {'title': 'fail', 'priority': 'low'},
    ]);
    final results = events.whereType<AgentToolResult>().toList();
    expect(results.every((r) => r.fromHook), isTrue);
    expect(results.map((r) => r.result.isError), [false, true]);
    expect(events.last, isA<AgentFinished>());
  });

  test('tool errors are fed back to the model as text', () async {
    server.tools['list_tasks'] = (_) => throw 'database locked';
    final engine = FakeEngine([
      '{"type":"tool_call","tool":"list_tasks","arguments":{}}',
      '{"type":"final","output":{"summary":"could not read tasks"}}',
    ]);

    await runner(engine).run(_withTools, {'goal': 'g'}).toList();

    expect(engine.prompts[1], contains('Error: database locked'));
  });

  test('invalid output and missing inputs end in AgentFailed', () async {
    final bad = await runner(FakeEngine(['{"summary": 5}']))
        .run(_withTools, {'goal': 'g'})
        .toList();
    expect(bad.last, isA<AgentFailed>());

    final missing = await runner(FakeEngine()).run(_withTools, {}).toList();
    expect(missing.single, isA<AgentFailed>());
    expect((missing.single as AgentFailed).error, isA<SkillInputException>());
  });

  test('a repetition loop is stopped and the complete items are kept', () async {
    final skill =
        parseSkill(File('assets/skills/extract-tasks.md').readAsStringSync());
    final looped = '{"tasks":[{"title":"Pay tuition","priority":"high"},'
        '${List.filled(30, '{"title":"Buy supplies","priority":"high"}').join(',')}]}';
    final engine = FakeEngine([looped]);

    final events = await runner(engine).run(skill, {'raw_text': 'x'}).toList();

    final done = events.last as AgentFinished;
    expect(done.partial, isTrue);
    expect(((done.output as Map)['tasks'] as List).map((t) => t['title']),
        ['Pay tuition', 'Buy supplies']);
    final streamed = events.whereType<AgentToken>().map((t) => t.text).join();
    expect(streamed.length, lessThan(looped.length ~/ 2), reason: 'stopped early');
  });

  test('output cut off by the token limit is salvaged', () async {
    final skill =
        parseSkill(File('assets/skills/extract-tasks.md').readAsStringSync());
    final engine = FakeEngine(['{"tasks":[{"title":"A","priority":"low"},{"title":"B","pri']);

    final done = (await runner(engine).run(skill, {'raw_text': 'x'}).toList()).last as AgentFinished;

    expect(done.partial, isTrue);
    expect(done.output, {
      'tasks': [
        {'title': 'A', 'priority': 'low'},
      ],
    });
  });

  test('the reply may use all context left after the prompt', () async {
    final skill =
        parseSkill(File('assets/skills/extract-tasks.md').readAsStringSync());
    final engine = FakeEngine(['{"tasks":[]}']);
    final compiler = SkillCompiler(engine);
    final events = await AgentRunner(engine: engine, compiler: compiler, mcp: mcp)
        .run(skill, {'raw_text': 'x'})
        .toList();
    final prompt = (events.first as AgentCompiled).compiled.promptTokens;
    expect(engine.optionsSeen.single.maxTokens, compiler.config.contextTokens - prompt - 8);
    expect(engine.optionsSeen.single.maxTokens, greaterThan(compiler.maxOutputTokens));
  });

  test('cancel stops the run', () async {
    final engine = FakeEngine(['{"type":"final","output":{"summary":"long answer here"}}']);
    final r = runner(engine);
    final events = <AgentEvent>[];
    await for (final e in r.run(_withTools, {'goal': 'g'})) {
      events.add(e);
      if (e is AgentToken) r.cancel();
    }
    final failed = events.last as AgentFailed;
    expect(failed.cancelled, isTrue);
  });
}
