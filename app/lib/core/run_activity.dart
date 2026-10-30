/// Whether a skill run or chat reply is in progress. EngineLifecycle checks
/// it so a memory-pressure signal never unloads the model mid-run.
abstract final class RunActivity {
  static int _active = 0;

  static bool get isActive => _active > 0;

  static void begin() => _active++;

  static void end() {
    if (_active > 0) _active--;
  }
}
