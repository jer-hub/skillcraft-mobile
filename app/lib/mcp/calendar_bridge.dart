import 'package:device_calendar/device_calendar.dart';
import 'package:timezone/timezone.dart' as tz;

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

/// [CalendarBridge] over the Android calendar provider.
class DeviceCalendarBridge implements CalendarBridge {
  final _plugin = DeviceCalendarPlugin();

  @override
  Future<String> insert({
    required String title,
    required DateTime start,
    DateTime? end,
    String? description,
  }) async {
    final calendar = await _writableCalendar();
    final event = Event(
      calendar.id,
      title: title,
      description: description,
      // UTC needs no timezone database; the provider shows local time.
      start: tz.TZDateTime.from(start.toUtc(), tz.UTC),
      end: tz.TZDateTime.from((end ?? start.add(const Duration(hours: 1))).toUtc(), tz.UTC),
    );
    final result = await _plugin.createOrUpdateEvent(event);
    if (result == null || !result.isSuccess) {
      throw StateError('Could not create event: ${_errors(result)}');
    }
    return result.data!;
  }

  @override
  Future<List<Map<String, Object?>>> list({
    required DateTime from,
    required DateTime to,
  }) async {
    await _ensurePermission();
    final calendars = await _plugin.retrieveCalendars();
    final events = <Map<String, Object?>>[];
    for (final c in calendars.data ?? const <Calendar>[]) {
      final r = await _plugin.retrieveEvents(
          c.id, RetrieveEventsParams(startDate: from, endDate: to));
      for (final e in r.data ?? const <Event>[]) {
        events.add({
          'title': e.title,
          'start': e.start?.toLocal().toIso8601String(),
          'end': e.end?.toLocal().toIso8601String(),
          'allDay': e.allDay ?? false,
          'calendar': c.name,
        });
      }
    }
    events.sort((a, b) => '${a['start']}'.compareTo('${b['start']}'));
    return events;
  }

  Future<Calendar> _writableCalendar() async {
    await _ensurePermission();
    final calendars = (await _plugin.retrieveCalendars()).data ?? const <Calendar>[];
    final writable = calendars.where((c) => c.isReadOnly != true).toList();
    if (writable.isEmpty) throw StateError('No writable calendar on this device');
    return writable.firstWhere((c) => c.isDefault == true, orElse: () => writable.first);
  }

  Future<void> _ensurePermission() async {
    final has = await _plugin.hasPermissions();
    if (has.data == true) return;
    final granted = await _plugin.requestPermissions();
    if (granted.data != true) throw StateError('Calendar permission denied');
  }

  static String _errors(Result<Object?>? r) =>
      r == null ? 'no result' : r.errors.map((e) => e.errorMessage).join('; ');
}
