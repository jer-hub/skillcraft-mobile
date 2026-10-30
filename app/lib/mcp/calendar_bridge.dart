import 'package:flutter/services.dart';

import 'host_api.dart';

/// Device calendar access used by the calendar tool server.
abstract interface class CalendarBridge {
  /// Creates an event in the default writable calendar; returns its id.
  Future<String> insert({
    required String title,
    required DateTime start,
    DateTime? end,
    String? description,
  });

  Future<List<Map<String, Object?>>> list({
    required DateTime from,
    required DateTime to,
  });
}

/// Host functions backed by [bridge]: `calendar.insert`, `calendar.list`.
Map<String, HostFunction> calendarFunctions(CalendarBridge bridge) => {
      'calendar.insert': (p) async {
        final start = _date(p, 'start')!;
        final id = await bridge.insert(
          title: (p['title'] as String?) ?? (throw ArgumentError('title is required')),
          start: start,
          end: _date(p, 'end') ?? start.add(const Duration(hours: 1)),
          description: p['description'] as String?,
        );
        return {'eventId': id};
      },
      'calendar.list': (p) => bridge.list(from: _date(p, 'from')!, to: _date(p, 'to')!),
    };

DateTime? _date(Map<String, Object?> p, String key) {
  final v = p[key];
  if (v == null) {
    if (key == 'end') return null;
    throw ArgumentError('$key is required (ISO 8601)');
  }
  final parsed = DateTime.tryParse(v.toString());
  if (parsed == null) throw ArgumentError('$key must be ISO 8601, got "$v"');
  return parsed;
}

/// [CalendarBridge] over the `skillcraft/calendar` channel (CalendarStore.kt).
class PlatformCalendarBridge implements CalendarBridge {
  static const _channel = MethodChannel('skillcraft/calendar');

  @override
  Future<String> insert({
    required String title,
    required DateTime start,
    DateTime? end,
    String? description,
  }) async {
    final id = await _call<String>('insert', {
      'title': title,
      'start': start.millisecondsSinceEpoch,
      'end': (end ?? start.add(const Duration(hours: 1))).millisecondsSinceEpoch,
      'description': description,
    });
    return id!;
  }

  @override
  Future<List<Map<String, Object?>>> list({
    required DateTime from,
    required DateTime to,
  }) async {
    final rows = await _call<List<Object?>>(
        'list', {'from': from.millisecondsSinceEpoch, 'to': to.millisecondsSinceEpoch});
    return [for (final r in rows ?? const []) calendarEventFromPlatform((r as Map).cast())];
  }

  /// Removes an event by id. Not exposed as a tool; tests use it to clean up.
  Future<bool> delete(String eventId) async =>
      await _call<bool>('delete', {'id': eventId}) ?? false;

  Future<T?> _call<T>(String method, Map<String, Object?> args) async {
    try {
      if (await _channel.invokeMethod<bool>('requestPermission') != true) {
        throw StateError('Calendar permission denied');
      }
      return await _channel.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw StateError(e.message ?? e.code);
    }
  }
}

/// Converts a CalendarStore row (epoch milliseconds) into the tool's shape.
/// All-day events are stored at UTC midnight, so their dates are read in UTC.
Map<String, Object?> calendarEventFromPlatform(Map<String, Object?> row) {
  final allDay = row['allDay'] == true;
  String time(Object? ms) {
    final t = DateTime.fromMillisecondsSinceEpoch((ms as num).toInt(), isUtc: allDay);
    return allDay ? DateTime(t.year, t.month, t.day).toIso8601String() : t.toIso8601String();
  }

  return {
    'id': row['id'],
    'title': row['title'],
    'start': time(row['start']),
    'end': time(row['end']),
    'allDay': allDay,
    'calendar': row['calendar'],
  };
}
