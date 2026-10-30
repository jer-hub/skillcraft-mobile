// Grammar guarantee (plan, Verification): 50 varied inputs through
// /extract-tasks, via the real AgentRunner path (loop stop + salvage), must
// all yield schema-valid JSON on the first pass. Also logs each output for
// quality review.
//
//   flutter test integration_test/grammar_test.dart -d <device> --no-uninstall
//
// Always pass --no-uninstall (see runtime_test.dart). Start with the phone
// unlocked: the test keeps the screen on from then on.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:skillcraft/agent/agent_runner.dart';
import 'package:skillcraft/core/config.dart';
import 'package:skillcraft/core/device_services.dart';
import 'package:skillcraft/inference/llama_engine.dart';
import 'package:skillcraft/mcp/mcp_host.dart';
import 'package:skillcraft/skills/skill_compiler.dart';
import 'package:skillcraft/skills/skill_parser.dart';

import 'data/grammar_inputs.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('50 inputs, 100% schema-valid JSON', () async {
    expect(grammarInputs, hasLength(50));
    await PlatformDeviceServices().setKeepScreenOn(true);
    final base = await getExternalStorageDirectory();
    final engine = LlamaEngine();
    await engine.load('${base!.path}/${AppPaths.modelsDir}/${AppPaths.defaultModelFile}', const EngineConfig());
    final runner = AgentRunner(engine: engine, compiler: SkillCompiler(engine), mcp: McpHost());
    final skill = parseSkill(await rootBundle.loadString('assets/skills/extract-tasks.md'));

    var valid = 0, partial = 0, truncatedInputs = 0, countHits = 0, counted = 0, emptyOk = 0, emptyTotal = 0;
    final failures = <String>[];
    final total = Stopwatch()..start();

    for (var i = 0; i < grammarInputs.length; i++) {
      final input = grammarInputs[i];
      final sw = Stopwatch()..start();
      final events = await runner.run(skill, {'raw_text': input.text}).toList();
      final ms = sw.elapsedMilliseconds;
      final compiled = events.whereType<AgentCompiled>().firstOrNull?.compiled;
      if (compiled?.warnings.any((w) => w.contains('truncated')) ?? false) truncatedInputs++;
      final streamed = events.whereType<AgentToken>().map((t) => t.text).join();

      String verdict;
      int? n;
      switch (events.last) {
        case AgentFinished(:final output, partial: final cut):
          valid++;
          if (cut) partial++;
          n = ((output as Map)['tasks'] as List).length;
          if (input.tasks != null) {
            counted++;
            if (n == input.tasks) countHits++;
          }
          if (input.tasks == 0) {
            emptyTotal++;
            if (n == 0) emptyOk++;
          }
          verdict = cut ? 'ok (partial)' : 'ok';
          if (cut) streamedPreview(i, jsonEncode(output));
        case AgentFailed(:final error):
          failures.add('#$i $error');
          verdict = 'FAILED $error';
        default:
          verdict = 'FAILED no final event';
          failures.add('#$i no final event');
      }
      // ignore: avoid_print
      print('GRAMMAR #${i.toString().padLeft(2)} ${input.kind.padRight(9)} $verdict · '
          '${ms}ms · ${compiled?.promptTokens}tok · tasks=$n'
          '${input.tasks == null ? '' : '/${input.tasks}'} · ${streamed.replaceAll('\n', ' ')}');
    }
    await engine.dispose();
    await PlatformDeviceServices().setKeepScreenOn(false);

    // ignore: avoid_print
    print('GRAMMAR_SUMMARY valid $valid/50 · partial (loop/length salvaged) $partial · '
        'no-task inputs empty $emptyOk/$emptyTotal · task count exact $countHits/$counted · '
        'truncated inputs $truncatedInputs · total ${(total.elapsedMilliseconds / 1000).round()}s');
    expect(failures, isEmpty);
    expect(valid, 50);
  }, timeout: const Timeout(Duration(minutes: 75)));
}

void streamedPreview(int i, String salvaged) {
  // ignore: avoid_print
  print('GRAMMAR #$i salvaged → $salvaged');
}
