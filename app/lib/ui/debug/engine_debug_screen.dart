import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:llama_ffi/llama_ffi.dart';

import '../../inference/chat_template.dart';
import '../../inference/engine_providers.dart';
import '../../models/model_manager.dart';
import '../../models/model_providers.dart';

/// Phase 1 exit check: load a GGUF, stream a reply, log tokens/s and RSS.
class EngineDebugScreen extends ConsumerStatefulWidget {
  const EngineDebugScreen({super.key});

  @override
  ConsumerState<EngineDebugScreen> createState() => _EngineDebugScreenState();
}

class _EngineDebugScreenState extends ConsumerState<EngineDebugScreen> {
  static const _demoSchema = {
    'type': 'object',
    'properties': {
      'answer': {'type': 'string'},
      'confidence': {
        'type': 'string',
        'enum': ['high', 'medium', 'low'],
      },
    },
    'required': ['answer', 'confidence'],
  };

  final _pathCtrl = TextEditingController();
  final _promptCtrl = TextEditingController(
    text: 'Give me three tips for a productive day.',
  );
  final _output = StringBuffer();
  final _log = <String>[];
  StreamSubscription<String>? _run;
  bool _busy = false;
  bool _jsonMode = false;

  @override
  void dispose() {
    _run?.cancel();
    _pathCtrl.dispose();
    _promptCtrl.dispose();
    super.dispose();
  }

  void _addLog(String line) => setState(() => _log.insert(0, line));

  Future<void> _pick() async {
    final manager = await ref.read(modelManagerProvider.future);
    final file = manager.installed(ModelRole.chat);
    if (file != null) {
      setState(() => _pathCtrl.text = file.path);
    } else {
      _addLog('No chat model installed; import one in Settings');
    }
  }

  Future<void> _load() async {
    final engine = ref.read(inferenceEngineProvider);
    final config = ref.read(engineConfigProvider);
    setState(() => _busy = true);
    final sw = Stopwatch()..start();
    try {
      await engine.load(_pathCtrl.text.trim(), config);
      _addLog(
        'Loaded in ${sw.elapsedMilliseconds} ms · '
        'ctx ${config.contextTokens} · ${config.threads} threads · '
        'RSS ${_rssMb()} MB',
      );
    } catch (e) {
      _addLog('Load failed: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _generate() async {
    final engine = ref.read(inferenceEngineProvider);
    final config = ref.read(engineConfigProvider);
    setState(() {
      _busy = true;
      _output.clear();
    });

    String? grammar;
    if (_jsonMode) {
      try {
        grammar = await engine.schemaToGbnf(jsonEncode(_demoSchema));
      } catch (e) {
        _addLog('Grammar failed: $e');
        setState(() => _busy = false);
        return;
      }
    }

    final prompt = QwenChatTemplate.render([
      ChatMessage.system(
        _jsonMode
            ? 'Reply only with JSON matching: ${jsonEncode(_demoSchema)}'
            : 'You are a helpful assistant.',
      ),
      ChatMessage.user(_promptCtrl.text),
    ]);
    final promptTokens = await engine.tokenCount(prompt);

    final sw = Stopwatch()..start();
    int? firstTokenMs;
    var pieces = 0;
    _run = engine
        .generate(
          prompt,
          GenerationOptions(
            temperature: config.temperature,
            maxTokens: 256,
            grammar: grammar,
          ),
        )
        .listen(
          (piece) {
            firstTokenMs ??= sw.elapsedMilliseconds;
            pieces++;
            setState(() => _output.write(piece));
          },
          onError: (Object e) => _addLog('Generation error: $e'),
          onDone: () {
            final genMs = sw.elapsedMilliseconds - (firstTokenMs ?? 0);
            final tps = pieces > 1 && genMs > 0
                ? ((pieces - 1) * 1000 / genMs).toStringAsFixed(1)
                : '-';
            var line =
                'prompt $promptTokens tok '
                '(${engine.lastReusedTokens} cached) · first token '
                '${firstTokenMs ?? '-'} ms · ~$tps tok/s · RSS ${_rssMb()} MB';
            if (_jsonMode) {
              line +=
                  ' · JSON ${_isJson(_output.toString()) ? 'valid' : 'INVALID'}';
            }
            _addLog(line);
            setState(() => _busy = false);
          },
        );
  }

  static bool _isJson(String s) {
    try {
      jsonDecode(s);
      return true;
    } on FormatException {
      return false;
    }
  }

  /// Resident set size from /proc (Android/Linux only).
  static String _rssMb() {
    try {
      final status = File('/proc/self/status').readAsLinesSync();
      final line = status.firstWhere((l) => l.startsWith('VmRSS:'));
      final kb = int.parse(RegExp(r'\d+').firstMatch(line)!.group(0)!);
      return (kb / 1024).toStringAsFixed(0);
    } catch (_) {
      return '?';
    }
  }

  @override
  Widget build(BuildContext context) {
    final engine = ref.watch(inferenceEngineProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Engine debug')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _pathCtrl,
                  decoration: const InputDecoration(labelText: 'GGUF path'),
                ),
              ),
              IconButton(
                onPressed: _busy ? null : _pick,
                icon: const Icon(Icons.folder_open),
                tooltip: 'Use installed model',
              ),
            ],
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _busy ? null : _load,
            child: Text(engine.isLoaded ? 'Reload model' : 'Load model'),
          ),
          const Divider(height: 32),
          TextField(
            controller: _promptCtrl,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(labelText: 'Prompt'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Constrain to JSON schema'),
            value: _jsonMode,
            onChanged: _busy ? null : (v) => setState(() => _jsonMode = v),
          ),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: !_busy && engine.isLoaded ? _generate : null,
                  child: const Text('Generate'),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _busy ? engine.cancel : null,
                child: const Text('Cancel'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SelectableText(_output.toString()),
          const Divider(height: 32),
          for (final line in _log)
            Text(line, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 16),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('System info'),
            children: [
              SelectableText(
                engine.isLoaded ? llamaSystemInfo() : 'Load a model first',
              ),
            ],
          ),
        ],
      ),
    );
  }
}
