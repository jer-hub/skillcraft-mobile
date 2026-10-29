import 'dart:async';
import 'dart:isolate';

import 'package:llama_ffi/llama_ffi.dart';

import '../core/config.dart';

/// Text generation backend. [LlamaEngine] is the real one; tests use fakes.
abstract interface class InferenceEngine {
  bool get isLoaded;

  Future<void> load(String modelPath, EngineConfig config);
  Future<void> unload();

  Future<int> tokenCount(String text);

  /// Converts a JSON Schema (JSON text) into a GBNF grammar.
  Future<String> schemaToGbnf(String schemaJson);

  /// Streams generated text. Errors arrive as [LlamaException]; a cancelled
  /// run ends with one whose `isCancelled` is true.
  Stream<String> generate(String prompt, GenerationOptions options);

  /// Prompt tokens the last completed [generate] reused from the KV cache.
  int get lastReusedTokens;

  /// Stops the current generation, if any.
  void cancel();

  Future<void> dispose();
}

/// Runs llama.cpp on a long-lived background isolate.
///
/// Requests are handled one at a time in order. Generation blocks the worker,
/// so [cancel] signals the native handle directly from the calling isolate.
class LlamaEngine implements InferenceEngine {
  SendPort? _worker;
  Isolate? _isolate;
  ReceivePort? _inbox;
  int? _handleAddress;
  int _nextId = 0;
  final _pending = <int, _Request>{};

  @override
  bool get isLoaded => _handleAddress != null;

  @override
  int lastReusedTokens = 0;

  @override
  Future<void> load(String modelPath, EngineConfig config) async {
    await _ensureWorker();
    // The worker frees any previous model before loading, even if this fails.
    _handleAddress = null;
    final address = await _call<int>(
        _LoadCmd(modelPath, config.contextTokens, config.threads));
    _handleAddress = address;
  }

  @override
  Future<void> unload() async {
    if (_worker == null || !isLoaded) return;
    await _call<void>(const _UnloadCmd());
    _handleAddress = null;
  }

  @override
  Future<int> tokenCount(String text) => _call<int>(_TokenCountCmd(text));

  @override
  Future<String> schemaToGbnf(String schemaJson) async {
    await _ensureWorker();
    return _call<String>(_GbnfCmd(schemaJson));
  }

  @override
  Stream<String> generate(String prompt, GenerationOptions options) {
    final controller = StreamController<String>();
    final id = _nextId++;
    _pending[id] = _StreamRequest(
        controller, (reused) => lastReusedTokens = reused);
    final worker = _worker;
    if (worker == null || !isLoaded) {
      _pending.remove(id);
      controller
        ..addError(StateError('No model loaded'))
        ..close();
    } else {
      worker.send((id, _GenerateCmd(prompt, options)));
    }
    return controller.stream;
  }

  @override
  void cancel() {
    final address = _handleAddress;
    if (address != null) LlamaModel.cancel(address);
  }

  @override
  Future<void> dispose() async {
    cancel();
    if (_worker != null) {
      try {
        await unload();
      } finally {
        _isolate?.kill();
        _inbox?.close();
        _worker = _isolate = _inbox = null;
      }
    }
    for (final r in _pending.values) {
      r.fail(StateError('LlamaEngine disposed'), StackTrace.current);
    }
    _pending.clear();
  }

  Future<void> _ensureWorker() async {
    if (_worker != null) return;
    final inbox = ReceivePort();
    final ready = Completer<SendPort>();
    inbox.listen((message) {
      if (message is SendPort) {
        ready.complete(message);
      } else {
        _onReply(message as _Reply);
      }
    });
    _inbox = inbox;
    _isolate = await Isolate.spawn(_workerMain, inbox.sendPort,
        debugName: 'llama-engine');
    _worker = await ready.future;
  }

  Future<T> _call<T>(_Command cmd) {
    final worker = _worker;
    if (worker == null) {
      return Future.error(StateError('Engine not started'));
    }
    final id = _nextId++;
    final completer = Completer<T>();
    _pending[id] = _FutureRequest<T>(completer);
    worker.send((id, cmd));
    return completer.future;
  }

  void _onReply(_Reply reply) {
    switch (reply) {
      case _Token(:final id, :final text):
        (_pending[id] as _StreamRequest?)?.controller.add(text);
      case _Done(:final id, :final value):
        _pending.remove(id)?.complete(value);
      case _Failed(:final id, :final code, :final message):
        final error =
            code == null ? StateError(message) : LlamaException(code, message);
        _pending.remove(id)?.fail(error, StackTrace.empty);
    }
  }
}

// ---------------------------------------------------------------------------
// Worker isolate

void _workerMain(SendPort replies) {
  final inbox = ReceivePort();
  replies.send(inbox.sendPort);
  LlamaModel? model;

  inbox.listen((message) {
    final (int id, _Command cmd) = message as (int, _Command);
    try {
      switch (cmd) {
        case _LoadCmd(:final path, :final contextTokens, :final threads):
          model?.dispose();
          model = null;
          final loaded = LlamaModel.load(path,
              contextTokens: contextTokens, threads: threads);
          model = loaded;
          replies.send(_Done(id, loaded.address));
        case _UnloadCmd():
          model?.dispose();
          model = null;
          replies.send(_Done(id, null));
        case _TokenCountCmd(:final text):
          replies.send(_Done(id, _require(model).tokenCount(text)));
        case _GbnfCmd(:final schemaJson):
          replies.send(_Done(id, jsonSchemaToGbnf(schemaJson)));
        case _GenerateCmd(:final prompt, :final options):
          final m = _require(model);
          for (final piece in m.generate(prompt, options)) {
            replies.send(_Token(id, piece));
          }
          replies.send(_Done(id, m.lastReusedTokens));
      }
    } on LlamaException catch (e) {
      replies.send(_Failed(id, e.code, e.message));
    } catch (e) {
      replies.send(_Failed(id, null, e.toString()));
    }
  });
}

LlamaModel _require(LlamaModel? model) =>
    model ?? (throw StateError('No model loaded'));

// ---------------------------------------------------------------------------
// Messages (records and final classes only, so they cross isolates cheaply)

sealed class _Command {
  const _Command();
}

final class _LoadCmd extends _Command {
  const _LoadCmd(this.path, this.contextTokens, this.threads);
  final String path;
  final int contextTokens;
  final int threads;
}

final class _UnloadCmd extends _Command {
  const _UnloadCmd();
}

final class _TokenCountCmd extends _Command {
  const _TokenCountCmd(this.text);
  final String text;
}

final class _GbnfCmd extends _Command {
  const _GbnfCmd(this.schemaJson);
  final String schemaJson;
}

final class _GenerateCmd extends _Command {
  const _GenerateCmd(this.prompt, this.options);
  final String prompt;
  final GenerationOptions options;
}

sealed class _Reply {
  const _Reply(this.id);
  final int id;
}

final class _Token extends _Reply {
  const _Token(super.id, this.text);
  final String text;
}

final class _Done extends _Reply {
  const _Done(super.id, this.value);
  final Object? value;
}

final class _Failed extends _Reply {
  const _Failed(super.id, this.code, this.message);
  final int? code;
  final String message;
}

sealed class _Request {
  void complete(Object? value);
  void fail(Object error, StackTrace stack);
}

final class _FutureRequest<T> extends _Request {
  _FutureRequest(this.completer);
  final Completer<T> completer;

  @override
  void complete(Object? value) => completer.complete(value as T);

  @override
  void fail(Object error, StackTrace stack) =>
      completer.completeError(error, stack);
}

final class _StreamRequest extends _Request {
  _StreamRequest(this.controller, this.onReused);
  final StreamController<String> controller;
  final void Function(int reused) onReused;

  @override
  void complete(Object? value) {
    onReused(value as int);
    controller.close();
  }

  @override
  void fail(Object error, StackTrace stack) {
    controller
      ..addError(error, stack)
      ..close();
  }
}
