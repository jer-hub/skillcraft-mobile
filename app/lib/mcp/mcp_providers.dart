import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/config.dart';
import '../inference/engine_providers.dart';
import '../settings/app_settings.dart';
import '../storage/data_version.dart';
import '../storage/database.dart';
import '../storage/storage_providers.dart';
import '../storage/vector_store.dart';
import 'calendar_bridge.dart';
import 'host_api.dart';
import 'mcp_host.dart';
import 'tool_servers.dart';

/// Running tool servers plus any that failed to start (id -> reason).
class ToolServers {
  const ToolServers(this.host, this.failures);
  final McpHost host;
  final Map<String, Object> failures;
}

final calendarBridgeProvider = Provider<CalendarBridge>((ref) => PlatformCalendarBridge());

/// `<app external files>/models`, where imported GGUF files live.
final modelsDirectoryProvider = FutureProvider<Directory>((ref) async {
  final base =
      await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
  return Directory(p.join(base.path, AppPaths.modelsDir));
});

/// Notes search, or null when no embedding model is present or it fails to
/// load (the notes server then stays off).
final vectorStoreProvider = FutureProvider<VectorStore?>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  if (!db.hasVectorSupport) return null;
  final dir = await ref.watch(modelsDirectoryProvider.future);
  final file = File(p.join(dir.path, AppPaths.embeddingModelFile));
  if (!file.existsSync()) return null;
  final engine = ref.watch(embeddingEngineProvider);
  try {
    if (!engine.hasEmbedder) {
      await engine.loadEmbedder(file.path, threads: ref.watch(engineConfigProvider).threads);
    }
    final store = VectorStore(db, engine, onChange: ref.read(dataVersionProvider.notifier).bump);
    await store.open();
    return store;
  } catch (e) {
    debugPrint('Embedding model not loaded: $e');
    return null;
  }
});

final toolServersProvider = FutureProvider<ToolServers>((ref) async {
  final AppDatabase db = await ref.watch(databaseProvider.future);
  final vectors = await ref.watch(vectorStoreProvider.future);
  // Restart servers only when the on/off set changes, not on every setting.
  final disabled = (await ref.watch(settingsProvider.selectAsync(
          (s) => (s.disabledToolServers.toList()..sort()).join('\n'))))
      .split('\n')
      .where((s) => s.isNotEmpty)
      .toSet();
  final (host, failures) = await startToolServers(
    loadAsset: rootBundle.loadString,
    capabilityFunctions: {
      Capability.sql: sqlFunctions(db, onWrite: ref.read(dataVersionProvider.notifier).bump),
      Capability.calendar: calendarFunctions(ref.watch(calendarBridgeProvider)),
      if (vectors != null) Capability.vector: vectorFunctions(vectors),
    },
    commonFunctions: logFunctions((line) => debugPrint('[tool] $line')),
    enabled: {
      for (final s in bundledToolServers)
        if (!disabled.contains(s.id)) s.id,
    },
  );
  ref.onDispose(host.dispose);
  for (final MapEntry(:key, :value) in failures.entries) {
    debugPrint('Tool server "$key" not started: $value');
  }
  return ToolServers(host, failures);
});
