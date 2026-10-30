// Round trip against the phone's REAL calendar, through the calendar tool
// server: creates "SkillCraft test – delete me" tomorrow at 10:00, reads it
// back with list_events, deletes it, and checks it is gone. Run it only with
// the phone owner's OK; it asks for calendar access on first run.
//
//   flutter test integration_test/calendar_test.dart -d <device> --no-uninstall
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:skillcraft/mcp/calendar_bridge.dart';
import 'package:skillcraft/mcp/host_api.dart';
import 'package:skillcraft/mcp/mcp_host.dart';
import 'package:skillcraft/mcp/tool_servers.dart';

const _title = 'SkillCraft test – delete me';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('create, list and delete a real calendar event', (tester) async {
    final bridge = PlatformCalendarBridge();
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day + 1, 10);
    String? eventId;
    McpHost? host;
    try {
      final (h, failures) = await startToolServers(
        loadAsset: rootBundle.loadString,
        capabilityFunctions: {Capability.calendar: calendarFunctions(bridge)},
        commonFunctions: logFunctions((_) {}),
        enabled: {'calendar'},
      );
      host = h;
      expect(failures, isEmpty);

      final created = await host.callTool('create_event',
          {'title': _title, 'start': start.toIso8601String(), 'description': 'Safe to delete.'});
      // ignore: avoid_print
      print('CALENDAR create: ${created.text}');
      expect(created.isError, isFalse, reason: created.text);
      eventId = RegExp(r'\(id (\d+)\)').firstMatch(created.text)?.group(1);
      expect(eventId, isNotNull);

      final listed = await host.callTool('list_events', {
        'from': start.subtract(const Duration(hours: 1)).toIso8601String(),
        'to': start.add(const Duration(hours: 2)).toIso8601String(),
      });
      // ignore: avoid_print
      print('CALENDAR list: ${listed.text}');
      expect(listed.text, contains(_title));
      expect(listed.text, contains(start.toIso8601String()));
    } finally {
      if (eventId != null) {
        expect(await bridge.delete(eventId), isTrue);
        final after = await bridge.list(from: start, to: start.add(const Duration(hours: 1)));
        expect(after.where((e) => e['id'] == eventId), isEmpty, reason: 'cleaned up');
        // ignore: avoid_print
        print('CALENDAR deleted $eventId');
      }
      await host?.dispose();
    }
  });
}
