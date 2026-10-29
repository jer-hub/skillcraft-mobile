import 'dart:async';
import 'dart:convert';

import 'package:quickjs_ffi/quickjs_ffi.dart';

import 'host_api.dart';
import 'tool_spec.dart';

/// Sends JSON-RPC requests to one MCP server and returns its responses.
abstract interface class McpTransport {
  Future<Map<String, Object?>> send(Map<String, Object?> request);
  Future<void> close();
}

/// An MCP server implemented by a script in its own QuickJS runtime.
class JsMcpTransport implements McpTransport {
  /// Evaluates [prelude] then [script]; the script must create an McpServer.
  JsMcpTransport({
    required String prelude,
    required String script,
    required String scriptName,
    required HostApi hostApi,
    Duration timeout = const Duration(seconds: 5),
  }) : _js = QuickJs(onHost: hostApi.call, timeout: timeout) {
    _js.eval(prelude, filename: '_prelude.js');
    _js.eval(script, filename: scriptName);
  }

  final QuickJs _js;

  @override
  Future<Map<String, Object?>> send(Map<String, Object?> request) async {
    final response = await _js.evalAsync('__mcp.handle(${jsonEncode(request)})');
    return (response as Map).cast<String, Object?>();
  }

  @override
  Future<void> close() async => _js.dispose();
}

/// Outcome of `tools/call`.
class ToolResult {
  const ToolResult({required this.text, this.isError = false, this.structured});

  /// Concatenated text content, as fed back to the model.
  final String text;
  final bool isError;
  final Object? structured;
}

class McpException implements Exception {
  McpException(this.message);
  final String message;
  @override
  String toString() => 'McpException: $message';
}

/// A connected server and what it advertised.
class McpServerInfo {
  McpServerInfo(this.id, this.name, this.transport, this.tools);

  final String id;
  final String name;
  final McpTransport transport;
  final List<ToolSpec> tools;
}

/// MCP client side: connects to servers, aggregates their tools, routes
/// `tools/call` by tool name.
class McpHost {
  final _servers = <String, McpServerInfo>{};
  final _toolOwner = <String, McpServerInfo>{};
  var _nextId = 1;

  /// Runs `initialize` and `tools/list`; tool names must be unique across
  /// servers. Closes [transport] if the handshake fails.
  Future<McpServerInfo> connect(String id, McpTransport transport) async {
    if (_servers.containsKey(id)) throw McpException('Server "$id" already connected');
    try {
      final init = await _request(transport, 'initialize', {
        'protocolVersion': '2025-06-18',
        'clientInfo': {'name': 'SkillCraft', 'version': '0.1.0'},
        'capabilities': <String, Object?>{},
      });
      final name = ((init['serverInfo'] as Map?)?['name'] as String?) ?? id;
      final listed = await _request(transport, 'tools/list', const {});
      final tools = [
        for (final t in (listed['tools'] as List? ?? const []).cast<Map>())
          ToolSpec(
            name: t['name'] as String,
            description: (t['description'] as String?) ?? '',
            inputSchema: (t['inputSchema'] as Map?)?.cast<String, Object?>() ??
                const {'type': 'object', 'properties': <String, Object?>{}},
          ),
      ];
      for (final t in tools) {
        final other = _toolOwner[t.name];
        if (other != null) {
          throw McpException('Tool "${t.name}" from "$id" clashes with "${other.id}"');
        }
      }
      final info = McpServerInfo(id, name, transport, tools);
      _servers[id] = info;
      for (final t in tools) {
        _toolOwner[t.name] = info;
      }
      return info;
    } catch (_) {
      await transport.close();
      rethrow;
    }
  }

  List<McpServerInfo> get servers => List.unmodifiable(_servers.values);

  List<ToolSpec> get tools => [for (final s in _servers.values) ...s.tools];

  ToolSpec? tool(String name) {
    final owner = _toolOwner[name];
    return owner?.tools.firstWhere((t) => t.name == name);
  }

  /// Calls [name]. Tool-level failures come back as `isError` results;
  /// protocol failures (unknown tool, broken server) throw [McpException].
  Future<ToolResult> callTool(String name, Map<String, Object?> arguments) async {
    final owner = _toolOwner[name];
    if (owner == null) throw McpException('Unknown tool "$name"');
    final result = await _request(
        owner.transport, 'tools/call', {'name': name, 'arguments': arguments});
    final content = (result['content'] as List? ?? const []).cast<Map>();
    return ToolResult(
      text: content
          .where((c) => c['type'] == 'text')
          .map((c) => c['text'] as String)
          .join('\n'),
      isError: result['isError'] == true,
      structured: result['structuredContent'],
    );
  }

  Future<void> disconnect(String id) async {
    final info = _servers.remove(id);
    if (info == null) return;
    _toolOwner.removeWhere((_, s) => s == info);
    await info.transport.close();
  }

  Future<void> dispose() async {
    for (final id in _servers.keys.toList()) {
      await disconnect(id);
    }
  }

  Future<Map<String, Object?>> _request(
      McpTransport transport, String method, Map<String, Object?> params) async {
    final id = _nextId++;
    final Map<String, Object?> response;
    try {
      response = await transport.send(
          {'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
    } on JsException catch (e) {
      throw McpException('$method failed: ${e.message}');
    }
    final error = response['error'];
    if (error is Map) {
      throw McpException('$method: ${error['message']} (${error['code']})');
    }
    if (response['id'] != id) throw McpException('$method: response id mismatch');
    return (response['result'] as Map?)?.cast<String, Object?>() ?? const {};
  }
}
