import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skillcraft/chat/chat_controller.dart';
import 'package:skillcraft/chat/chat_models.dart';
import 'package:skillcraft/chat/skill_matcher.dart';
import 'package:skillcraft/mcp/mcp_host.dart';
import 'package:skillcraft/settings/app_settings.dart';
import 'package:skillcraft/skills/skill_compiler.dart';
import 'package:skillcraft/skills/skill_parser.dart';

import '../support/fakes.dart';

final _capture = parseSkill(File('assets/skills/capture-tasks.md').readAsStringSync());
final _twoInputs = parseSkill('''
---
name: email-reply
description: Drafts a reply to an email message in a chosen tone.
inputs:
  email: {type: string, required: true}
  tone: {type: string, enum: [formal, friendly], required: true}
output_schema:
  type: object
  properties:
    reply: {type: string}
  required: [reply]
---
Write the reply.
''');

void main() {
  late FakeEngine engine;
  late FakeDeviceServices device;
  late McpHost mcp;
  late FakeMcpTransport db;
  late ProviderContainer container;

  ProviderContainer make({bool withMatcher = true, List<String> replies = const []}) {
    engine = FakeEngine(replies);
    final deps = ChatDeps(
      engine: engine,
      compiler: SkillCompiler(engine),
      mcp: mcp,
      skills: [_capture, _twoInputs],
      device: device,
      settings: const AppSettings(suggestThreshold: 0.3),
      matcher: withMatcher ? SkillMatcher(engine) : null,
    );
    return ProviderContainer(overrides: [chatDepsProvider.overrideWith((ref) async => deps)]);
  }

  setUp(() async {
    device = FakeDeviceServices();
    mcp = McpHost();
    db = FakeMcpTransport('DB', {'save_task_to_db': (a) => 'saved ${a['title']}'},
        schemas: {
          'save_task_to_db': {
            'type': 'object',
            'properties': {
              'title': {'type': 'string'},
              'priority': {'type': 'string'},
              'due_date': {'type': 'string'},
            },
          },
        });
    await mcp.connect('db', db);
  });
  tearDown(() async {
    container.dispose();
    await mcp.dispose();
  });

  ChatController ctl() => container.read(chatControllerProvider.notifier);
  List<ChatItem> items() => container.read(chatControllerProvider).items;

  test('a slash command runs the skill and its on_output hook', () async {
    container = make(replies: ['{"has_actions":true,"tasks":[{"title":"Call Ana","priority":"high"}]}']);

    await ctl().submit('/capture-tasks Call Ana today');

    expect(items().first, isA<UserMessage>());
    final run = items().last as SkillRun;
    expect(run.status, RunStatus.finished);
    expect(run.output, {
      'has_actions': true,
      'tasks': [
        {'title': 'Call Ana', 'priority': 'high'},
      ],
    });
    expect(run.toolCalls.single.fromHook, isTrue);
    expect(run.toolCalls.single.result?.text, 'saved Call Ana');
    expect(db.calls.single.$2['title'], 'Call Ana');
    expect(device.keepScreenOn, [true, false], reason: 'screen kept on only while running');
    expect(container.read(chatControllerProvider).busy, isFalse);
  });

  test('unknown skills get an error reply', () async {
    container = make();
    await ctl().submit('/nope do it');
    expect((items().last as AssistantMessage).error, contains('No skill named /nope'));
  });

  test('missing or ambiguous inputs open the form; submitting runs it', () async {
    container = make(replies: ['{"reply":"Thanks!"}']);

    await ctl().submit('/email-reply');
    final request = container.read(chatControllerProvider).inputRequest!;
    expect(request.skill.name, 'email-reply');
    expect(items().whereType<SkillRun>(), isEmpty);

    await ctl().submitInputs(request.skill, {'email': 'Hi', 'tone': 'friendly'});
    expect(container.read(chatControllerProvider).inputRequest, isNull);
    expect((items().last as SkillRun).output, {'reply': 'Thanks!'});
  });

  test('a plain message matching a skill gets a suggestion, not a run', () async {
    container = make(replies: ['{"has_actions":false,"tasks":[]}']);

    await ctl().submit('extract the actionable tasks from these meeting notes');

    final s = items().last as SkillSuggestion;
    expect(s.skillName, 'capture-tasks');
    expect(engine.prompts, isEmpty, reason: 'nothing ran yet');

    await ctl().acceptSuggestion(s.id);
    expect((items().whereType<SkillSuggestion>().single).resolved, isTrue);
    final run = items().last as SkillRun;
    expect(run.status, RunStatus.finished);
    expect(engine.prompts.single, contains('raw_text:\nextract the actionable tasks'));
  });

  test('declining a suggestion answers as plain chat', () async {
    container = make(replies: ['Here is a short answer.']);

    await ctl().submit('extract the actionable tasks from these meeting notes');
    await ctl().declineSuggestion((items().last as SkillSuggestion).id);

    final reply = items().last as AssistantMessage;
    expect(reply.text, 'Here is a short answer.');
    expect(reply.done, isTrue);
    expect(engine.optionsSeen.single.grammar, isNull, reason: 'plain chat is unconstrained');
    expect(engine.optionsSeen.single.temperature, const AppSettings().chatTemperature);
  });

  test('without an embedding model, plain messages go straight to chat', () async {
    container = make(withMatcher: false, replies: ['Hello!']);

    await ctl().submit('extract the actionable tasks from these meeting notes');

    expect(items().whereType<SkillSuggestion>(), isEmpty);
    expect((items().last as AssistantMessage).text, 'Hello!');
  });

  test('plain chat carries earlier plain turns but not skill runs', () async {
    container = make(withMatcher: false, replies: [
      'First answer.',
      '{"has_actions":false,"tasks":[]}',
      'Second answer.',
    ]);

    await ctl().submit('What is SkillCraft?');
    await ctl().submit('/capture-tasks nothing here');
    await ctl().submit('And how private is it?');

    final last = engine.prompts.last;
    expect(last, contains('What is SkillCraft?'));
    expect(last, contains('First answer.'));
    expect(last, isNot(contains('/capture-tasks')));
    expect(last, endsWith('And how private is it?<|im_end|>\n<|im_start|>assistant\n'));
  });

  test('cancel marks the run as stopped', () async {
    container = make(replies: ['{"has_actions":true,"tasks":[{"title":"a long title","priority":"low"}]}']);
    // Cancel as soon as the first tokens stream in.
    container.listen(chatControllerProvider, (_, s) {
      final last = s.items.lastOrNull;
      if (last is SkillRun && last.streamed.isNotEmpty) ctl().cancel();
    });
    await ctl().submit('/capture-tasks something');
    expect((items().last as SkillRun).status, RunStatus.cancelled);
    expect(device.keepScreenOn.last, isFalse);
  });

  test('clear empties the conversation when idle', () async {
    container = make(withMatcher: false, replies: ['ok']);
    await ctl().submit('hi');
    ctl().clear();
    expect(items(), isEmpty);
  });
}
