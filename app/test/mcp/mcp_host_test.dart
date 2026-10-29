import 'package:flutter_test/flutter_test.dart';
import 'package:skillcraft/mcp/host_api.dart';
import 'package:skillcraft/mcp/mcp_host.dart';
import 'package:skillcraft/mcp/tool_servers.dart';

import '../support/fakes.dart';

void main() {
  late McpHost host;
  setUp(() => host = McpHost());
  tearDown(() => host.dispose());

  test('connects and aggregates tools across servers', () async {
    await host.connect('a', FakeMcpTransport('Server A', {'one': (_) => 1}));
    await host.connect('b', FakeMcpTransport('Server B', {'two': (_) => 2}));

    expect(host.servers.map((s) => s.name), ['Server A', 'Server B']);
    expect(host.tools.map((t) => t.name), ['one', 'two']);
    expect(host.tool('two')?.description, 'Fake two.');
  });

  test('routes calls by tool name', () async {
    final b = FakeMcpTransport('B', {'echo': (args) => 'hi ${args['who']}'});
    await host.connect('a', FakeMcpTransport('A', {'other': (_) => 'x'}));
    await host.connect('b', b);

    final r = await host.callTool('echo', {'who': 'Ana'});
    expect(r.text, 'hi Ana');
    expect(r.isError, isFalse);
    expect(b.calls.single.$1, 'echo');
  });

  test('tool failures are results; unknown tools are errors', () async {
    await host.connect('a', FakeMcpTransport('A', {'boom': (_) => throw 'disk full'}));

    final r = await host.callTool('boom', {});
    expect(r.isError, isTrue);
    expect(r.text, 'disk full');
    expect(() => host.callTool('missing', {}), throwsA(isA<McpException>()));
  });

  test('rejects clashing tool names and closes the newcomer', () async {
    await host.connect('a', FakeMcpTransport('A', {'same': (_) => 1}));
    final b = FakeMcpTransport('B', {'same': (_) => 2});

    await expectLater(host.connect('b', b), throwsA(isA<McpException>()));
    expect(b.closed, isTrue);
    expect(host.servers, hasLength(1));
  });

  test('disconnect removes tools and closes the transport', () async {
    final a = FakeMcpTransport('A', {'one': (_) => 1});
    await host.connect('a', a);
    await host.disconnect('a');
    expect(host.tools, isEmpty);
    expect(a.closed, isTrue);
  });

  group('startToolServers', () {
    test('grants only declared capabilities and reports skipped servers', () async {
      const defs = [
        ToolServerDef('db', 'db.js', {Capability.sql}),
        ToolServerDef('vec', 'vec.js', {Capability.vector}),
      ];
      // A real JS runtime is needed to start servers, so this only checks the
      // capability gate, which runs before any runtime is created.
      final (h, failures) = await startToolServers(
        loadAsset: (_) async => '',
        capabilityFunctions: {Capability.sql: <String, HostFunction>{}},
        commonFunctions: const {},
        servers: defs,
        enabled: {'vec'},
      );
      expect(h.servers, isEmpty);
      expect(failures.keys, ['vec']);
      expect(failures['vec'].toString(), contains('vector'));
    });
  });
}
