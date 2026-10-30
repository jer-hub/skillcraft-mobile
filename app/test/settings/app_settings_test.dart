import 'package:flutter_test/flutter_test.dart';
import 'package:skillcraft/settings/app_settings.dart';
import 'package:skillcraft/storage/database.dart';

void main() {
  test('round-trips through the database', () {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    expect(AppSettings.load(db).threads, 4);

    const AppSettings(threads: 3, chatTemperature: 0.2, disabledToolServers: {'calendar'}).save(db);
    final s = AppSettings.load(db);
    expect(s.threads, 3);
    expect(s.chatTemperature, 0.2);
    expect(s.disabledToolServers, {'calendar'});
    expect(s.engineConfig.threads, 3);
  });

  test('falls back per field on bad or out-of-range values', () {
    final s = AppSettings.fromJson({
      'threads': 99,
      'contextTokens': 4096,
      'chatTemperature': 'hot',
      'suggestThreshold': 0.5,
    });
    expect(s.threads, 4);
    expect(s.contextTokens, 2048, reason: 'never above the KV-cache cap');
    expect(s.chatTemperature, 0.7);
    expect(s.suggestThreshold, 0.5);
  });

  test('corrupt JSON loads defaults', () {
    final db = AppDatabase.inMemory();
    addTearDown(db.close);
    db.setMeta('settings', '{nope');
    expect(AppSettings.load(db).threads, 4);
  });
}
