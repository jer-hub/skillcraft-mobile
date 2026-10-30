import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/device_services.dart';
import '../inference/engine_providers.dart';
import '../mcp/mcp_providers.dart';
import '../settings/app_settings.dart';
import 'model_manager.dart';

final deviceServicesProvider = Provider<DeviceServices>((ref) => PlatformDeviceServices());

final modelManagerProvider = FutureProvider<ModelManager>((ref) async => ModelManager(
      await ref.watch(modelsDirectoryProvider.future),
      ref.watch(deviceServicesProvider),
    ));

/// The loaded chat model, or null when none is installed.
class ChatModelInfo {
  const ChatModelInfo(this.path, this.loadMs, this.threads, this.contextTokens);
  final String path;
  final int loadMs;
  final int threads;
  final int contextTokens;
}

/// Loads the installed chat model at startup and after imports or reloads.
/// Settings are read (not watched) so changing them does not reload 1 GB;
/// call [reload] to apply new thread / context settings.
class ChatModelController extends AsyncNotifier<ChatModelInfo?> {
  @override
  Future<ChatModelInfo?> build() async {
    final manager = await ref.watch(modelManagerProvider.future);
    final file = manager.installed(ModelRole.chat);
    if (file == null) return null;
    final config = (await ref.read(settingsProvider.future)).engineConfig;
    final engine = ref.read(inferenceEngineProvider);
    final sw = Stopwatch()..start();
    await engine.load(file.path, config);
    return ChatModelInfo(file.path, sw.elapsedMilliseconds, config.threads, config.contextTokens);
  }

  Future<void> reload() async {
    state = const AsyncLoading();
    ref.invalidateSelf();
    await future;
  }

  Future<void> remove() async {
    await ref.read(inferenceEngineProvider).unload();
    await (await ref.read(modelManagerProvider.future)).remove(ModelRole.chat);
    ref.invalidateSelf();
  }
}

final chatModelProvider =
    AsyncNotifierProvider<ChatModelController, ChatModelInfo?>(ChatModelController.new);
