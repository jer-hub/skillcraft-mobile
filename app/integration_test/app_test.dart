// End-to-end UI check on the device with the real models, plus measurements
// for the skill-suggestion threshold.
//
//   flutter test integration_test/app_test.dart -d <device> --no-uninstall
//
// Always pass --no-uninstall (see runtime_test.dart).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skillcraft/chat/skill_matcher.dart';
import 'package:skillcraft/inference/engine_providers.dart';
import 'package:skillcraft/main.dart';
import 'package:skillcraft/mcp/mcp_providers.dart';
import 'package:skillcraft/skills/skill_providers.dart';

/// Pumps until [finder] matches or [timeout] passes.
Future<void> pumpUntil(WidgetTester tester, Finder finder,
    {Duration timeout = const Duration(minutes: 3)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 250));
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TestFailure('Timed out waiting for $finder');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('chat runs /capture-tasks end to end', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: SkillCraftApp()));
    await pumpUntil(tester, find.byKey(const ValueKey('composer')), timeout: const Duration(seconds: 60));
    await pumpUntil(tester, find.text('/capture-tasks'), timeout: const Duration(seconds: 60));

    await tester.enterText(find.byKey(const ValueKey('composer')),
        '/capture-tasks Sam must renew the domain by Friday. Maybe someday tidy the wiki.');
    await tester.pump();
    final sw = Stopwatch()..start();
    await tester.tap(find.byTooltip('Send'));
    await pumpUntil(tester, find.textContaining(RegExp(r'^(Done|Failed)')));

    // ignore: avoid_print
    print('UI_E2E ${sw.elapsedMilliseconds} ms');
    expect(find.textContaining(RegExp(r'^Done')), findsOneWidget);
    expect(find.textContaining('Tasks ('), findsOneWidget);
    // The row is rich text ("save_task_to_db  auto"), so match by substring.
    expect(find.textContaining('save_task_to_db'), findsWidgets, reason: 'on_output hook ran');
  });

  // A plain test (real async, no fake clock): it embeds on the worker isolate.
  test('suggestion scores for related vs unrelated messages', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // Riverpod 3 pauses providers nobody listens to; read() alone would wait
    // forever once a dependency (settings) changes mid-load.
    container.listen(vectorStoreProvider, (_, _) {});
    container.listen(skillEntriesProvider, (_, _) {});
    final sw = Stopwatch()..start();
    final store = await container.read(vectorStoreProvider.future);
    // ignore: avoid_print
    print('SUGGEST_SETUP vector store ready in ${sw.elapsedMilliseconds} ms');
    expect(store, isNotNull, reason: 'embedding model required');
    final skills = [
      for (final e in await container.read(skillEntriesProvider.future))
        if (e.skill != null) e.skill!,
    ];
    final matcher = SkillMatcher(container.read(embeddingEngineProvider));

    const related = [
      'pull the action items out of these meeting notes',
      'what tasks came out of this call: Ana sends the deck, Ben books a room',
      'turn this into a todo list',
    ];
    const unrelated = [
      'what is the capital of France',
      'tell me a joke about cats',
      'how do I boil an egg',
    ];
    final scores = <String, double>{};
    for (final m in [...related, ...unrelated]) {
      final best = (await matcher.best(m, skills))!;
      scores['$m -> ${best.skill.name}'] = best.score;
    }
    // ignore: avoid_print
    scores.forEach((k, v) => print('SUGGEST ${v.toStringAsFixed(3)}  $k'));
    final minRelated = related.map((m) => scores.entries.firstWhere((e) => e.key.startsWith(m)).value).reduce((a, b) => a < b ? a : b);
    final maxUnrelated = unrelated.map((m) => scores.entries.firstWhere((e) => e.key.startsWith(m)).value).reduce((a, b) => a > b ? a : b);
    // ignore: avoid_print
    print('SUGGEST_GAP minRelated=${minRelated.toStringAsFixed(3)} maxUnrelated=${maxUnrelated.toStringAsFixed(3)}');
    expect(minRelated, greaterThan(maxUnrelated), reason: 'a threshold can separate them');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
