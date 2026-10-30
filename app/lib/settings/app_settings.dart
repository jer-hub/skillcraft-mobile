import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config.dart';
import '../storage/database.dart';
import '../storage/storage_providers.dart';

/// User-adjustable settings, stored as JSON in the database `meta` table.
class AppSettings {
  const AppSettings({
    this.threads = 4,
    this.contextTokens = EngineConfig.maxContextTokens,
    this.chatTemperature = 0.7,
    this.disabledToolServers = const {},
    this.suggestThreshold = 0.54,
  });

  /// One thread per Cortex-A73 core is fastest on the target device.
  final int threads;
  final int contextTokens;

  /// Plain chat only; skills always decode greedily.
  final double chatTemperature;
  final Set<String> disabledToolServers;

  /// Minimum similarity for suggesting a skill for a plain message. Measured
  /// with nomic-embed on device: task requests scored 0.556-0.629, unrelated
  /// questions 0.455-0.515.
  final double suggestThreshold;

  EngineConfig get engineConfig =>
      EngineConfig(threads: threads, contextTokens: contextTokens);

  AppSettings copyWith({
    int? threads,
    int? contextTokens,
    double? chatTemperature,
    Set<String>? disabledToolServers,
    double? suggestThreshold,
  }) =>
      AppSettings(
        threads: threads ?? this.threads,
        contextTokens: contextTokens ?? this.contextTokens,
        chatTemperature: chatTemperature ?? this.chatTemperature,
        disabledToolServers: disabledToolServers ?? this.disabledToolServers,
        suggestThreshold: suggestThreshold ?? this.suggestThreshold,
      );

  Map<String, Object?> toJson() => {
        'threads': threads,
        'contextTokens': contextTokens,
        'chatTemperature': chatTemperature,
        'disabledToolServers': disabledToolServers.toList()..sort(),
        'suggestThreshold': suggestThreshold,
      };

  /// Tolerates missing or out-of-range values (falls back per field).
  factory AppSettings.fromJson(Map<String, Object?> j) {
    const d = AppSettings();
    T pick<T extends num>(String key, T fallback, T min, T max) {
      final v = j[key];
      if (v is! num) return fallback;
      final n = (fallback is int ? v.round() : v.toDouble()) as T;
      return n < min || n > max ? fallback : n;
    }

    return AppSettings(
      threads: pick('threads', d.threads, 1, 8),
      contextTokens: pick('contextTokens', d.contextTokens, 512, EngineConfig.maxContextTokens),
      chatTemperature: pick('chatTemperature', d.chatTemperature, 0.0, 1.5),
      disabledToolServers: {
        for (final s in (j['disabledToolServers'] as List? ?? const [])) s.toString(),
      },
      suggestThreshold: pick('suggestThreshold', d.suggestThreshold, 0.0, 1.0),
    );
  }

  static const _key = 'settings';

  static AppSettings load(AppDatabase db) {
    final raw = db.metaValue(_key);
    if (raw == null) return const AppSettings();
    try {
      return AppSettings.fromJson((jsonDecode(raw) as Map).cast<String, Object?>());
    } on FormatException {
      return const AppSettings();
    }
  }

  void save(AppDatabase db) => db.setMeta(_key, jsonEncode(toJson()));
}

class SettingsController extends AsyncNotifier<AppSettings> {
  @override
  Future<AppSettings> build() async =>
      AppSettings.load(await ref.watch(databaseProvider.future));

  Future<void> change(AppSettings Function(AppSettings) edit) async {
    final next = edit(await future);
    next.save(await ref.read(databaseProvider.future));
    state = AsyncData(next);
  }
}

final settingsProvider =
    AsyncNotifierProvider<SettingsController, AppSettings>(SettingsController.new);
