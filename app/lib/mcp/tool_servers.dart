import 'host_api.dart';
import 'mcp_host.dart';

/// Host capabilities a bundled tool server may be granted.
enum Capability { sql, calendar, vector }

/// A bundled tool server: a script in `assets/tools/` plus what it may use.
class ToolServerDef {
  const ToolServerDef(this.id, this.asset, this.capabilities);

  final String id;
  final String asset;
  final Set<Capability> capabilities;
}

const bundledToolServers = [
  ToolServerDef('local_db', 'assets/tools/local_db.js', {Capability.sql}),
  ToolServerDef('calendar', 'assets/tools/calendar.js', {Capability.calendar}),
  // Started only when an embedding model is available.
  ToolServerDef('notes', 'assets/tools/vector.js', {Capability.vector}),
];

const preludeAsset = 'assets/tools/_prelude.js';

/// Starts each enabled server in its own runtime and connects it to a new
/// [McpHost]. A server that fails to start is reported and skipped, so one
/// broken script cannot take the others down.
Future<(McpHost, Map<String, Object>)> startToolServers({
  required Future<String> Function(String asset) loadAsset,
  required Map<Capability, Map<String, HostFunction>> capabilityFunctions,
  required Map<String, HostFunction> commonFunctions,
  List<ToolServerDef> servers = bundledToolServers,
  Set<String>? enabled,
}) async {
  final host = McpHost();
  final failures = <String, Object>{};
  final prelude = await loadAsset(preludeAsset);
  for (final def in servers) {
    if (enabled != null && !enabled.contains(def.id)) continue;
    final missing = def.capabilities.where((c) => !capabilityFunctions.containsKey(c));
    if (missing.isNotEmpty) {
      failures[def.id] = 'unavailable: ${missing.map((c) => c.name).join(', ')}';
      continue;
    }
    try {
      final api = HostApi({
        ...commonFunctions,
        for (final c in def.capabilities) ...capabilityFunctions[c]!,
      });
      final transport = JsMcpTransport(
        prelude: prelude,
        script: await loadAsset(def.asset),
        scriptName: def.asset.split('/').last,
        hostApi: api,
      );
      await host.connect(def.id, transport);
    } catch (e) {
      failures[def.id] = e;
    }
  }
  return (host, failures);
}
