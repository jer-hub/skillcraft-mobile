import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skillcraft/main.dart';
import 'package:skillcraft/models/model_providers.dart';
import 'package:skillcraft/skills/skill_compiler.dart';
import 'package:skillcraft/skills/skill_parser.dart';
import 'package:skillcraft/ui/chat/output_view.dart';
import 'package:skillcraft/ui/chat/skill_input_form.dart';
import 'package:skillcraft/ui/skills/skill_editor_screen.dart';

import 'support/fakes.dart';

class _NoModel extends ChatModelController {
  @override
  Future<ChatModelInfo?> build() async => null;
}

Widget _app(Widget home, {List overrides = const []}) =>
    ProviderScope(overrides: [...overrides], child: SkillCraftApp(home: home));

void main() {
  testWidgets('without a model the app opens on setup', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        chatModelProvider.overrideWith(_NoModel.new),
        deviceServicesProvider.overrideWithValue(FakeDeviceServices()),
      ],
      child: const SkillCraftApp(),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Welcome to SkillCraft'), findsOneWidget);
    expect(find.textContaining('Memory: 8.0 GB'), findsOneWidget);
    expect(find.text('Import file'), findsNWidgets(2));
    expect(find.textContaining('Download ('), findsNWidgets(2));
  });

  testWidgets('output view shows array items as cards', (tester) async {
    await tester.pumpWidget(_app(const Scaffold(
      body: SingleChildScrollView(
        child: OutputView({
          'tasks': [
            {'title': 'Ana: send budget', 'priority': 'high', 'due_date': 'Friday'},
            {'title': 'Book venue', 'priority': 'medium'},
          ],
          'summary': 'Two tasks',
        }),
      ),
    )));

    expect(find.text('Tasks (2)'), findsOneWidget);
    expect(find.text('Ana: send budget'), findsOneWidget);
    expect(find.text('Priority: high'), findsOneWidget);
    expect(find.text('Due date: Friday'), findsOneWidget);
    expect(find.textContaining('Two tasks'), findsOneWidget);
  });

  testWidgets('input form validates and returns coerced inputs', (tester) async {
    final skill = parseSkill('''
---
name: plan
description: Plans.
inputs:
  goal: {type: string, required: true}
  days: {type: integer, required: true}
output_schema: {type: object, properties: {}}
---
''');
    Map<String, Object?>? got;
    await tester.pumpWidget(_app(Scaffold(
      body: SkillInputForm(skill: skill, onSubmit: (v) => got = v),
    )));

    await tester.tap(find.text('Run'));
    await tester.pump();
    expect(find.text('Missing required input "goal"'), findsOneWidget);
    expect(got, isNull);

    await tester.enterText(find.byKey(const ValueKey('input-goal')), 'Ship v1');
    await tester.enterText(find.byKey(const ValueKey('input-days')), '3');
    await tester.tap(find.text('Run'));
    await tester.pump();
    expect(got, {'goal': 'Ship v1', 'days': 3});
  });

  testWidgets('skill editor validates live with line numbers', (tester) async {
    final source = File('assets/skills/extract-tasks.md').readAsStringSync();
    await tester.pumpWidget(_app(SkillEditorScreen(fileName: 'extract-tasks.md', source: source)));
    expect(find.text('Valid skill: /extract-tasks'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('skill-source')),
        source.replaceFirst('name: extract-tasks', 'name: Bad Name'));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.textContaining('kebab-case'), findsOneWidget);
    expect(find.text('line 2'), findsOneWidget);
  });

  test('parseInvocation is what the composer relies on', () {
    expect(SkillCompiler.parseInvocation('/capture-tasks '), ('capture-tasks', ''));
  });
}
