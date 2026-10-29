import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/config.dart';
import '../inference/engine_providers.dart';
import 'skill_compiler.dart';
import 'skill_repository.dart';

const _seedAssetDir = 'assets/skills/';

/// `<app external files>/Documents/SkillCraft/skills`; scoped storage, no
/// permission needed, and reachable from a PC over USB.
final skillsDirectoryProvider = FutureProvider<Directory>((ref) async {
  final base =
      await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
  return Directory(p.join(base.path, AppPaths.skillsDir));
});

final skillRepositoryProvider = FutureProvider<SkillRepository>((ref) async {
  final repo = SkillRepository(
    root: await ref.watch(skillsDirectoryProvider.future),
    loadSeedSkills: _loadBundledSkills,
  );
  await repo.ensureSeeded();
  return repo;
});

/// All skill files, refreshed when the folder changes.
final skillEntriesProvider = StreamProvider<List<SkillEntry>>((ref) async* {
  final repo = await ref.watch(skillRepositoryProvider.future);
  yield* repo.watch();
});

final skillCompilerProvider = Provider<SkillCompiler>((ref) => SkillCompiler(
      ref.watch(inferenceEngineProvider),
      config: ref.watch(engineConfigProvider),
    ));

Future<Map<String, String>> _loadBundledSkills() async {
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  final assets = manifest
      .listAssets()
      .where((a) => a.startsWith(_seedAssetDir) && a.endsWith('.md'));
  return {
    for (final a in assets) p.basename(a): await rootBundle.loadString(a),
  };
}
