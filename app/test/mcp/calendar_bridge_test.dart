import 'package:flutter_test/flutter_test.dart';
import 'package:skillcraft/mcp/calendar_bridge.dart';

void main() {
  test('timed events come back in local time', () {
    final start = DateTime(2026, 11, 3, 9, 30);
    final e = calendarEventFromPlatform({
      'id': '42',
      'title': 'Standup',
      'start': start.millisecondsSinceEpoch,
      'end': start.add(const Duration(minutes: 15)).millisecondsSinceEpoch,
      'allDay': false,
      'calendar': 'Work',
    });
    expect(e, {
      'id': '42',
      'title': 'Standup',
      'start': '2026-11-03T09:30:00.000',
      'end': '2026-11-03T09:45:00.000',
      'allDay': false,
      'calendar': 'Work',
    });
  });

  test('all-day events keep their date whatever the time zone', () {
    // The provider stores all-day events at UTC midnight.
    final e = calendarEventFromPlatform({
      'id': '7',
      'title': 'Holiday',
      'start': DateTime.utc(2026, 11, 1).millisecondsSinceEpoch,
      'end': DateTime.utc(2026, 11, 2).millisecondsSinceEpoch,
      'allDay': true,
      'calendar': 'Holidays',
    });
    expect(e['start'], '2026-11-01T00:00:00.000');
    expect(e['end'], '2026-11-02T00:00:00.000');
  });

  test('tool functions pass ISO dates through and default to one hour', () async {
    final bridge = _Recording();
    final fns = calendarFunctions(bridge);
    final r = await fns['calendar.insert']!({'title': 'Call Ana', 'start': '2026-11-03T14:00:00'});
    expect(r, {'eventId': 'e1'});
    expect(bridge.ends.single, DateTime(2026, 11, 3, 15));
    expect(() => fns['calendar.insert']!({'title': 'x', 'start': 'Friday'}), throwsArgumentError);
  });
}

class _Recording implements CalendarBridge {
  final ends = <DateTime?>[];
  @override
  Future<String> insert(
      {required String title, required DateTime start, DateTime? end, String? description}) async {
    ends.add(end);
    return 'e${ends.length}';
  }

  @override
  Future<List<Map<String, Object?>>> list({required DateTime from, required DateTime to}) async => [];
}
