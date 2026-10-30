import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:skillcraft/core/device_services.dart';

import 'package:llama_ffi/llama_ffi.dart';
import 'package:skillcraft/core/config.dart';
import 'package:skillcraft/inference/llama_engine.dart';
import 'package:skillcraft/mcp/mcp_host.dart';

/// ~4 characters per token. Replays [replies] in order, one per generate(),
/// and records what it was asked. Embeddings are hashed bag-of-words
/// vectors, so texts sharing words score higher.
class FakeEngine implements InferenceEngine, EmbeddingEngine {
  FakeEngine([List<String> replies = const []]) : replies = List.of(replies);

  static const _dims = 64;

  @override
  bool get hasEmbedder => true;
  @override
  int get embeddingDimensions => _dims;
  @override
  Future<void> loadEmbedder(String modelPath, {int threads = 4}) async {}
  @override
  Future<void> unloadEmbedder() async {}

  @override
  Future<List<double>> embed(String text) async {
    final v = List<double>.filled(_dims, 0);
    final body = text.replaceFirst(RegExp(r'^search_(query|document): '), '');
    for (final w in RegExp(r'[a-z]{3,}').allMatches(body.toLowerCase())) {
      v[w[0].hashCode % _dims] += 1;
    }
    final norm = sqrt(v.fold<double>(0, (s, x) => s + x * x));
    return [for (final x in v) norm == 0 ? 0.0 : x / norm];
  }

  final List<String> replies;
  final prompts = <String>[];
  final optionsSeen = <GenerationOptions>[];
  final schemasConverted = <String>[];
  bool cancelled = false;

  @override
  bool get isLoaded => true;
  @override
  int get lastReusedTokens => 0;
  @override
  Future<int> tokenCount(String text) async => (text.length / 4).ceil();
  @override
  Future<String> schemaToGbnf(String schemaJson) async {
    schemasConverted.add(schemaJson);
    return 'grammar#${schemasConverted.length}';
  }

  @override
  Stream<String> generate(String prompt, GenerationOptions options) async* {
    cancelled = false; // like sc_begin, a new generation clears the flag
    prompts.add(prompt);
    optionsSeen.add(options);
    if (replies.isEmpty) throw StateError('FakeEngine: no reply scripted');
    final reply = replies.removeAt(0);
    // Stream in a few pieces, like real tokens.
    for (var i = 0; i < reply.length; i += 7) {
      if (cancelled) throw LlamaException(SC_ERR_CANCELLED, 'cancelled');
      yield reply.substring(i, i + 7 > reply.length ? reply.length : i + 7);
    }
  }

  @override
  void cancel() => cancelled = true;
  @override
  Future<void> load(String modelPath, EngineConfig config) async {}
  @override
  Future<void> unload() async {}
  @override
  Future<void> dispose() async {}
}

/// Records keep-screen-on calls; "imports" by writing [importBytes] to dest.
class FakeDeviceServices implements DeviceServices {
  final keepScreenOn = <bool>[];
  List<int>? importBytes;
  String importName = 'model.gguf';
  final _progress = StreamController<ImportProgress>.broadcast();

  @override
  Future<void> setKeepScreenOn(bool on) async => keepScreenOn.add(on);

  @override
  Future<ImportedFile?> importDocument(String dest) async {
    final bytes = importBytes;
    if (bytes == null) return null;
    _progress.add((copied: bytes.length, total: bytes.length));
    await File(dest).writeAsBytes(bytes);
    return (name: importName, bytes: bytes.length);
  }

  @override
  Stream<ImportProgress> get importProgress => _progress.stream;

  @override
  Future<({int total, int available})> memory() async =>
      (total: 8 << 30, available: 4 << 30);
}

typedef FakeTool =FutureOr<Object?> Function(Map<String, Object?> args);

/// An MCP server in Dart, answering like the JS prelude does.
class FakeMcpTransport implements McpTransport {
  FakeMcpTransport(this.name, this.tools, {this.schemas = const {}});

  final String name;
  final Map<String, FakeTool> tools;
  final Map<String, Map<String, Object?>> schemas;
  final calls = <(String, Map<String, Object?>)>[];
  bool closed = false;

  @override
  Future<Map<String, Object?>> send(Map<String, Object?> request) async {
    final id = request['id'];
    final params = (request['params'] as Map?)?.cast<String, Object?>() ?? {};
    Map<String, Object?> ok(Object? result) => {'jsonrpc': '2.0', 'id': id, 'result': result};
    switch (request['method']) {
      case 'initialize':
        return ok({'serverInfo': {'name': name}, 'capabilities': {'tools': {}}});
      case 'tools/list':
        return ok({
          'tools': [
            for (final t in tools.keys)
              {
                'name': t,
                'description': 'Fake $t.',
                'inputSchema': schemas[t] ?? {'type': 'object', 'properties': {}},
              },
          ],
        });
      case 'tools/call':
        final tool = tools[params['name']];
        if (tool == null) {
          return {'jsonrpc': '2.0', 'id': id, 'error': {'code': -32602, 'message': 'Unknown tool'}};
        }
        final args = (params['arguments'] as Map).cast<String, Object?>();
        calls.add((params['name'] as String, args));
        try {
          final out = await tool(args);
          return ok({'content': [{'type': 'text', 'text': out is String ? out : '$out'}]});
        } catch (e) {
          return ok({'content': [{'type': 'text', 'text': '$e'}], 'isError': true});
        }
      default:
        return {'jsonrpc': '2.0', 'id': id, 'error': {'code': -32601, 'message': 'Method not found'}};
    }
  }

  @override
  Future<void> close() async => closed = true;
}
