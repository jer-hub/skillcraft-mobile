import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Bytes copied so far during a file import ([total] is -1 when unknown).
typedef ImportProgress = ({int copied, int total});

/// A file the user picked, already written to its destination.
typedef ImportedFile = ({String name, int bytes});

/// Platform services implemented in MainActivity.kt.
abstract interface class DeviceServices {
  /// Installed version, e.g. (name: "1.0.0", code: 1).
  Future<({String name, int code})> appVersion();

  /// Keeps the screen on; Android runs off-screen apps on slower cores.
  Future<void> setKeepScreenOn(bool on);

  /// Opens the system file picker and streams the chosen file to [dest].
  /// Returns null if the user cancelled.
  Future<ImportedFile?> importDocument(String dest);

  Stream<ImportProgress> get importProgress;

  /// Total and available RAM in bytes (from /proc/meminfo).
  Future<({int total, int available})> memory();

  /// Free bytes on the volume holding [path].
  Future<int> freeBytes(String path);

  /// True on mobile data or another network that may charge per byte.
  Future<bool> isMeteredNetwork();

  /// Starts the foreground service that keeps a run alive off screen.
  Future<void> startRun(String label);
  Future<void> stopRun();

  /// "Stop" tapped on the run notification.
  Stream<void> get stopRequests;

  /// Asks for notification permission (Android 13+); true if granted.
  Future<bool> ensureNotificationPermission();

  /// Whether Android exempts SkillCraft from battery optimisation.
  Future<bool> isBatteryExempt();

  /// Opens the system dialog that grants the exemption.
  Future<void> requestBatteryExemption();
}

class PlatformDeviceServices implements DeviceServices {
  PlatformDeviceServices() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'stopRequested') _stops.add(null);
    });
  }

  static const _channel = MethodChannel('skillcraft/device');
  static const _progress = EventChannel('skillcraft/import_progress');
  final _stops = StreamController<void>.broadcast();

  @override
  Future<int> freeBytes(String path) async =>
      (await _channel.invokeMethod<num>('freeBytes', {'path': path}))?.toInt() ?? 0;

  @override
  Future<bool> isMeteredNetwork() async =>
      await _channel.invokeMethod<bool>('isMeteredNetwork') ?? true;

  @override
  Future<void> startRun(String label) => _channel.invokeMethod('startRun', {'label': label});

  @override
  Future<void> stopRun() => _channel.invokeMethod('stopRun');

  @override
  Stream<void> get stopRequests => _stops.stream;

  @override
  Future<bool> ensureNotificationPermission() async =>
      await _channel.invokeMethod<bool>('ensureNotificationPermission') ?? false;

  @override
  Future<bool> isBatteryExempt() async => await _channel.invokeMethod<bool>('isBatteryExempt') ?? false;

  @override
  Future<void> requestBatteryExemption() => _channel.invokeMethod('requestBatteryExemption');

  @override
  Future<({String name, int code})> appVersion() async {
    final r = await _channel.invokeMapMethod<String, Object?>('appVersion');
    return (name: (r?['name'] as String?) ?? '?', code: (r?['code'] as num?)?.toInt() ?? 0);
  }

  @override
  Future<void> setKeepScreenOn(bool on) => _channel.invokeMethod('setKeepScreenOn', on);

  @override
  Future<ImportedFile?> importDocument(String dest) async {
    final r = await _channel.invokeMapMethod<String, Object?>('importDocument', {'dest': dest});
    if (r == null) return null;
    return (name: r['name'] as String, bytes: (r['bytes'] as num).toInt());
  }

  @override
  Stream<ImportProgress> get importProgress => _progress.receiveBroadcastStream().map((e) {
        final m = (e as Map).cast<String, Object?>();
        return (copied: (m['copied'] as num).toInt(), total: (m['total'] as num).toInt());
      });

  @override
  Future<({int total, int available})> memory() async => readMemInfo(
      await File('/proc/meminfo').readAsString());
}

/// Parses MemTotal / MemAvailable (kB) from /proc/meminfo text.
({int total, int available}) readMemInfo(String meminfo) {
  int field(String name) {
    final m = RegExp('^$name:\\s+(\\d+) kB', multiLine: true).firstMatch(meminfo);
    return m == null ? 0 : int.parse(m.group(1)!) * 1024;
  }

  return (total: field('MemTotal'), available: field('MemAvailable'));
}
