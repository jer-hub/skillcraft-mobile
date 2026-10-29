import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config.dart';
import 'llama_engine.dart';

final engineConfigProvider = Provider<EngineConfig>((ref) => const EngineConfig());

/// The app-wide inference engine. Override in tests with a fake.
final inferenceEngineProvider = Provider<InferenceEngine>((ref) {
  final engine = LlamaEngine();
  final lifecycle = EngineLifecycle(engine)..attach();
  ref.onDispose(() {
    lifecycle.detach();
    engine.dispose();
  });
  return engine;
});

/// Frees the ~1.1 GB model when Android reports memory pressure
/// (`onTrimMemory`, surfaced by Flutter as [didHaveMemoryPressure]) while the
/// app is in the background. The next run reloads it.
class EngineLifecycle with WidgetsBindingObserver {
  EngineLifecycle(this._engine);

  final InferenceEngine _engine;
  AppLifecycleState _state = AppLifecycleState.resumed;

  void attach() => WidgetsBinding.instance.addObserver(this);
  void detach() => WidgetsBinding.instance.removeObserver(this);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _state = state;

  @override
  void didHaveMemoryPressure() {
    if (_state != AppLifecycleState.resumed && _engine.isLoaded) {
      _engine.cancel();
      _engine.unload();
    }
  }
}
