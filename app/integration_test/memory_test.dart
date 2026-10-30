// Memory profiling on the device: repeated generations, skill runs and
// load/unload cycles, sampling resident memory (VmRSS) after each.
//
//   flutter test integration_test/memory_test.dart -d <device> --no-uninstall
//
// Always pass --no-uninstall (see runtime_test.dart). Keep the screen on:
// off-screen apps run on slower cores.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:llama_ffi/llama_ffi.dart';
import 'package:path_provider/path_provider.dart';
import 'package:skillcraft/agent/agent_runner.dart';
import 'package:skillcraft/core/config.dart';
import 'package:skillcraft/inference/chat_template.dart';
import 'package:skillcraft/inference/llama_engine.dart';
import 'package:skillcraft/mcp/host_api.dart';
import 'package:skillcraft/mcp/tool_servers.dart';
import 'package:skillcraft/skills/skill_compiler.dart';
import 'package:skillcraft/skills/skill_parser.dart';
import 'package:skillcraft/storage/database.dart';

int rssMb() {
  final line = File('/proc/self/status').readAsLinesSync().firstWhere((l) => l.startsWith('VmRSS:'));
  return int.parse(RegExp(r'\d+').firstMatch(line)![0]!) ~/ 1024;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('no memory growth across repeated runs', () async {
    final base = await getExternalStorageDirectory();
    final model = '${base!.path}/${AppPaths.modelsDir}/${AppPaths.defaultModelFile}';
    final baseline = rssMb();
    final engine = LlamaEngine();
    await engine.load(model, const EngineConfig());
    final loaded = rssMb();

    // 15 short plain generations with varying prompts.
    final gen = <int>[];
    for (var i = 0; i < 15; i++) {
      final prompt = QwenChatTemplate.render([
        ChatMessage.user('Give one tip about topic number $i, in one sentence.'),
      ]);
      await engine.generate(prompt, const GenerationOptions(temperature: 0, maxTokens: 24)).drain<void>();
      gen.add(rssMb());
    }

    // 3 full skill runs with tools and the hook.
    final db = AppDatabase.inMemory();
    final (host, _) = await startToolServers(
      loadAsset: rootBundle.loadString,
      capabilityFunctions: {Capability.sql: sqlFunctions(db)},
      commonFunctions: const {},
      enabled: {'local_db'},
    );
    final skill = parseSkill(await rootBundle.loadString('assets/skills/capture-tasks.md'));
    final runner = AgentRunner(engine: engine, compiler: SkillCompiler(engine), mcp: host);
    final runs = <int>[];
    for (var i = 0; i < 3; i++) {
      final events = await runner.run(skill, {'raw_text': 'Note $i: Kim must file the report by Monday.'}).toList();
      expect(events.last, isA<AgentFinished>());
      runs.add(rssMb());
    }
    await host.dispose();
    db.close();

    // 3 unload / reload cycles.
    final cycles = <String>[];
    for (var i = 0; i < 3; i++) {
      await engine.unload();
      final down = rssMb();
      await engine.load(model, const EngineConfig());
      cycles.add('$down/${rssMb()}');
    }
    await engine.dispose();
    final end = rssMb();

    // ignore: avoid_print
    print('MEM baseline $baseline MB · loaded $loaded MB\n'
        'MEM gen $gen\nMEM skill runs $runs\nMEM unload/reload $cycles\nMEM after dispose $end MB');

    // Allow warm-up in the first iterations; afterwards memory must be flat.
    expect(gen.last - gen[4], lessThan(40), reason: 'growth across generations 5..15');
    expect(runs.last - runs.first, lessThan(40), reason: 'growth across skill runs');
    expect(end, lessThan(loaded - 500), reason: 'model memory released on dispose');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
