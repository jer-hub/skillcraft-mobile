// Debug vs profile (AOT) performance with identical work (greedy decoding).
//
//   debug:   flutter test integration_test/perf_test.dart -d <device> --no-uninstall
//   profile: flutter drive --profile --driver=test_driver/integration_test.dart \
//              --target=integration_test/perf_test.dart -d <device>
//
// Keep the screen on: off-screen apps run on slower cores.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:llama_ffi/llama_ffi.dart';
import 'package:skillcraft/chat/chat_controller.dart';
import 'package:skillcraft/chat/chat_models.dart';
import 'package:skillcraft/core/device_services.dart';
import 'package:skillcraft/inference/chat_template.dart';
import 'package:skillcraft/inference/engine_providers.dart';
import 'package:skillcraft/main.dart';

const _mode = kReleaseMode ? 'release' : kProfileMode ? 'profile' : 'debug';

Future<void> pumpUntil(WidgetTester tester, bool Function() done,
    {Duration timeout = const Duration(minutes: 3)}) async {
  final end = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(end)) throw TestFailure('timed out');
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('engine and UI timings', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: SkillCraftApp()));
    // Keep the window on screen: otherwise the lock screen stops the activity
    // and vivo's background manager kills the app minutes later.
    await PlatformDeviceServices().setKeepScreenOn(true);
    final container = ProviderScope.containerOf(tester.element(find.byType(SkillCraftApp)));
    await pumpUntil(tester, () => find.byKey(const ValueKey('composer')).evaluate().isNotEmpty,
        timeout: const Duration(seconds: 90));
    await pumpUntil(tester, () => container.read(chatDepsProvider).hasValue,
        timeout: const Duration(seconds: 90));

    // 1. Engine only: 96 greedy tokens through the worker isolate.
    final engine = container.read(inferenceEngineProvider);
    final prompt = QwenChatTemplate.render(
        [const ChatMessage.user('Write a long paragraph about the history of sailing ships.')]);
    final pieces = <int>[];
    final sw = Stopwatch()..start();
    var first = 0;
    await tester.runAsync(() async {
      await for (final _ in engine.generate(prompt, const GenerationOptions(temperature: 0, maxTokens: 96))) {
        if (pieces.isEmpty) first = sw.elapsedMilliseconds;
        pieces.add(sw.elapsedMilliseconds);
      }
    });
    final tps = (pieces.length - 1) * 1000 / (pieces.last - first);

    // 2. Through the chat UI: the same skill run, rendering every token.
    await tester.enterText(find.byKey(const ValueKey('composer')),
        '/extract-tasks Jo fixes the login bug by Thursday. Mark updates the release notes.');
    await tester.pump();
    final ui = Stopwatch()..start();
    await tester.tap(find.byTooltip('Send'));
    await pumpUntil(tester, () {
      final last = container.read(chatControllerProvider).items.lastOrNull;
      return last is SkillRun && last.status != RunStatus.running;
    });
    final run = container.read(chatControllerProvider).items.last as SkillRun;

    // ignore: avoid_print
    print('PERF $_mode · engine ${tps.toStringAsFixed(2)} tok/s (first token ${first}ms, '
        '${pieces.length} pieces) · UI /extract-tasks ${ui.elapsedMilliseconds}ms '
        '(${run.status.name}, ${run.streamed.length} chars)');
    expect(run.status, RunStatus.finished);
  });
}
