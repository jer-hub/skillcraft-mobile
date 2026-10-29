import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'bindings.dart';

/// Handles a script's `__host(name, payload)` call. The returned value is
/// JSON-encoded back into the script; a thrown error rejects its promise.
typedef HostHandler = FutureOr<Object?> Function(String name, Object? payload);

/// A script error (or a timeout, see [isTimeout]).
class JsException implements Exception {
  JsException(this.message, {this.isTimeout = false});

  final String message;
  final bool isTimeout;

  @override
  String toString() =>
      isTimeout ? 'JsException(timeout): $message' : 'JsException: $message';
}

final ScQjsBindings _bindings = ScQjsBindings(() {
  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open('libsc_qjs.so');
  }
  if (Platform.isWindows) return DynamicLibrary.open('sc_qjs.dll');
  throw UnsupportedError('quickjs_ffi: unsupported platform');
}());

/// Live runtimes by owner id, for routing the shared native callback.
final _runtimes = <int, QuickJs>{};
var _nextOwner = 1;

// Runs synchronously on this isolate's thread, re-entrantly inside an eval /
// resolve / run_jobs call. It must not call back into the bridge, so it only
// queues the request.
final _hostCallable = NativeCallable<ScQjsHostNative>.isolateLocal(
  (int owner, int callId, Pointer<Char> name, Pointer<Char> payload) {
    _runtimes[owner]?._onHostCall(callId, name.cast<Utf8>().toDartString(),
        payload.cast<Utf8>().toDartString());
  },
);

/// Lets Dart await async JS: `__settle` reports the outcome of a call.
const _prelude = r'''
globalThis.__settleAsync = (id, fn) => {
  Promise.resolve().then(fn).then(
    (v) => __host("__settle", JSON.stringify({ id, ok: true, value: v === undefined ? null : v })),
    (e) => __host("__settle", JSON.stringify({ id, ok: false,
        error: e instanceof Error ? `${e.message}\n${e.stack ?? ""}` : String(e) })));
};
''';

/// One sandboxed QuickJS runtime. Scripts have no file, network or OS access;
/// they can only reach the app through [HostHandler].
///
/// Use from a single isolate. Not thread-safe.
class QuickJs {
  QuickJs({
    required this._onHost,
    int memoryLimitBytes = 32 * 1024 * 1024,
    this.timeout = const Duration(seconds: 5),
  }) {
    _owner = _nextOwner++;
    _handle = _bindings.sc_qjs_new(
        _owner, memoryLimitBytes, _hostCallable.nativeFunction);
    if (_handle == nullptr) throw StateError('QuickJS runtime creation failed');
    _runtimes[_owner] = this;
    eval(_prelude, filename: '<prelude>');
  }

  final HostHandler _onHost;

  /// Wall-clock limit for each burst of synchronous script execution.
  final Duration timeout;

  late final int _owner;
  late final Pointer<ScQjs> _handle;
  bool _disposed = false;
  int _nextCallId = 0;
  final _settles = <int, Completer<Object?>>{};

  /// Evaluates [code] as a global script and returns its completion value
  /// (decoded from JSON). Throws [JsException].
  Object? eval(String code, {String filename = '<eval>'}) {
    final cCode = code.toNativeUtf8();
    final cName = filename.toNativeUtf8();
    try {
      final text = _withOut((out) => _bindings.sc_qjs_eval(
          _checked, cCode.cast(), cName.cast(), _timeoutMs, out));
      return text == null ? null : jsonDecode(text);
    } finally {
      malloc.free(cCode);
      malloc.free(cName);
    }
  }

  /// Evaluates [expression] (which may return a promise) and completes with
  /// its settled value. Throws [JsException] if it throws or rejects.
  Future<Object?> evalAsync(String expression) {
    final id = _nextCallId++;
    final completer = Completer<Object?>();
    _settles[id] = completer;
    try {
      eval('__settleAsync($id, () => ($expression));', filename: '<async>');
    } catch (e) {
      _settles.remove(id);
      rethrow;
    }
    return completer.future;
  }

  /// `__host` calls still waiting for a reply.
  int get pendingHostCalls => _bindings.sc_qjs_pending_calls(_checked);

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _runtimes.remove(_owner);
    _bindings.sc_qjs_free(_handle);
    for (final c in _settles.values) {
      c.completeError(JsException('runtime disposed'));
    }
    _settles.clear();
  }

  void _onHostCall(int callId, String name, String payloadJson) {
    // Defer: we are inside a native call and must not re-enter the bridge.
    scheduleMicrotask(() => _handleHostCall(callId, name, payloadJson));
  }

  Future<void> _handleHostCall(int callId, String name, String payloadJson) async {
    if (name == '__settle') {
      final m = jsonDecode(payloadJson) as Map<String, Object?>;
      final completer = _settles.remove(m['id'] as int);
      _resolve(callId, true, 'null');
      if (completer == null) return;
      if (m['ok'] == true) {
        completer.complete(m['value']);
      } else {
        completer.completeError(JsException(m['error'].toString()));
      }
      return;
    }

    bool ok;
    String reply;
    try {
      final payload = jsonDecode(payloadJson);
      reply = jsonEncode(await _onHost(name, payload));
      ok = true;
    } catch (e) {
      ok = false;
      reply = e is JsException ? e.message : e.toString();
    }
    if (!_disposed) _resolve(callId, ok, reply);
  }

  void _resolve(int callId, bool ok, String json) {
    final cJson = json.toNativeUtf8();
    try {
      _withOut((out) => _bindings.sc_qjs_resolve(
          _checked, callId, ok ? 1 : 0, cJson.cast(), _timeoutMs, out));
    } on JsException catch (e) {
      // A job threw while handling the reply; fail any awaiting caller.
      for (final c in _settles.values) {
        c.completeError(e);
      }
      _settles.clear();
    } finally {
      malloc.free(cJson);
    }
  }

  int get _timeoutMs => timeout.inMilliseconds;

  Pointer<ScQjs> get _checked {
    if (_disposed) throw StateError('QuickJs used after dispose');
    return _handle;
  }

  /// Runs [call] with an out-string pointer; returns the string on success,
  /// throws [JsException] on failure.
  static String? _withOut(int Function(Pointer<Pointer<Char>> out) call) {
    final out = calloc<Pointer<Char>>();
    try {
      final rc = call(out);
      final text = out.value == nullptr ? null : out.value.cast<Utf8>().toDartString();
      if (out.value != nullptr) _bindings.sc_qjs_string_free(out.value);
      if (rc == SC_QJS_OK) return text;
      if (rc == SC_QJS_ERR_TIMEOUT) {
        throw JsException(text ?? 'interrupted', isTimeout: true);
      }
      throw JsException(text ?? 'QuickJS error $rc');
    } finally {
      calloc.free(out);
    }
  }
}
