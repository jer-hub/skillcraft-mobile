import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skillcraft/core/run_activity.dart';
import 'package:skillcraft/inference/engine_providers.dart';

import '../support/fakes.dart';

class _TrackingEngine extends FakeEngine {
  int unloads = 0;
  @override
  Future<void> unload() async => unloads++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('memory pressure in the background unloads, except mid-run', () {
    final engine = _TrackingEngine();
    final lifecycle = EngineLifecycle(engine)..didChangeAppLifecycleState(AppLifecycleState.paused);

    RunActivity.begin();
    lifecycle.didHaveMemoryPressure();
    expect(engine.unloads, 0, reason: 'a run in progress keeps its model');
    expect(engine.cancelled, isFalse);

    RunActivity.end();
    lifecycle.didHaveMemoryPressure();
    expect(engine.unloads, 1);
  });

  test('memory pressure while visible never unloads', () {
    final engine = _TrackingEngine();
    EngineLifecycle(engine)
      ..didChangeAppLifecycleState(AppLifecycleState.resumed)
      ..didHaveMemoryPressure();
    expect(engine.unloads, 0);
  });
}
