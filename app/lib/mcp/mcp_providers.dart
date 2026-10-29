import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/storage_providers.dart';
import 'calendar_bridge.dart';
import 'host_api.dart';
import 'mcp_host.dart';
import 'tool_servers.dart';

/// Running tool servers plus any that failed to start (id -> reason).
class ToolServers {
  const ToolServers(this.host, this.failures);
  final McpHost host;
  final Map<String, Object> failures;
}

final calendarBridgeProvider = Provider<CalendarBridge>((ref) => DeviceCalendarBridge());

final toolServersProvider = FutureProvider<ToolServers>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  final (host, failures) = await startToolServers(
    loadAsset: rootBundle.loadString,
    capabilityFunctions: {
      Capability.sql: sqlFunctions(db),
      Capability.calendar: calendarFunctions(ref.watch(calendarBridgeProvider)),
    },
    commonFunctions: logFunctions((line) => debugPrint('[tool] $line')),
  );
  ref.onDispose(host.dispose);
  for (final MapEntry(:key, :value) in failures.entries) {
    debugPrint('Tool server "$key" not started: $value');
  }
  return ToolServers(host, failures);
});
