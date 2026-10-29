// Bindings for `src/sc_qjs.h`, written in ffigen's style.
// ignore_for_file: type=lint
import 'dart:ffi' as ffi;

final class ScQjs extends ffi.Opaque {}

typedef ScQjsHostNative = ffi.Void Function(ffi.Int64 owner, ffi.Int32 callId,
    ffi.Pointer<ffi.Char> name, ffi.Pointer<ffi.Char> payloadJson);

class ScQjsBindings {
  ScQjsBindings(ffi.DynamicLibrary lib) : _lookup = lib.lookup;

  final ffi.Pointer<T> Function<T extends ffi.NativeType>(String) _lookup;

  late final sc_qjs_new = _lookup<
          ffi.NativeFunction<
              ffi.Pointer<ScQjs> Function(ffi.Int64, ffi.Int64,
                  ffi.Pointer<ffi.NativeFunction<ScQjsHostNative>>)>>('sc_qjs_new')
      .asFunction<
          ffi.Pointer<ScQjs> Function(
              int, int, ffi.Pointer<ffi.NativeFunction<ScQjsHostNative>>)>();

  late final sc_qjs_free =
      _lookup<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ScQjs>)>>(
              'sc_qjs_free')
          .asFunction<void Function(ffi.Pointer<ScQjs>)>();

  late final sc_qjs_eval = _lookup<
          ffi.NativeFunction<
              ffi.Int32 Function(ffi.Pointer<ScQjs>, ffi.Pointer<ffi.Char>,
                  ffi.Pointer<ffi.Char>, ffi.Int32,
                  ffi.Pointer<ffi.Pointer<ffi.Char>>)>>('sc_qjs_eval')
      .asFunction<
          int Function(ffi.Pointer<ScQjs>, ffi.Pointer<ffi.Char>,
              ffi.Pointer<ffi.Char>, int, ffi.Pointer<ffi.Pointer<ffi.Char>>)>();

  late final sc_qjs_resolve = _lookup<
          ffi.NativeFunction<
              ffi.Int32 Function(ffi.Pointer<ScQjs>, ffi.Int32, ffi.Int32,
                  ffi.Pointer<ffi.Char>, ffi.Int32,
                  ffi.Pointer<ffi.Pointer<ffi.Char>>)>>('sc_qjs_resolve')
      .asFunction<
          int Function(ffi.Pointer<ScQjs>, int, int, ffi.Pointer<ffi.Char>, int,
              ffi.Pointer<ffi.Pointer<ffi.Char>>)>();

  late final sc_qjs_run_jobs = _lookup<
          ffi.NativeFunction<
              ffi.Int32 Function(ffi.Pointer<ScQjs>, ffi.Int32,
                  ffi.Pointer<ffi.Pointer<ffi.Char>>)>>('sc_qjs_run_jobs')
      .asFunction<
          int Function(
              ffi.Pointer<ScQjs>, int, ffi.Pointer<ffi.Pointer<ffi.Char>>)>();

  late final sc_qjs_pending_calls =
      _lookup<ffi.NativeFunction<ffi.Int32 Function(ffi.Pointer<ScQjs>)>>(
              'sc_qjs_pending_calls')
          .asFunction<int Function(ffi.Pointer<ScQjs>)>();

  late final sc_qjs_string_free =
      _lookup<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Char>)>>(
              'sc_qjs_string_free')
          .asFunction<void Function(ffi.Pointer<ffi.Char>)>();
}

const int SC_QJS_OK = 0;
const int SC_QJS_ERR_EXCEPTION = -1;
const int SC_QJS_ERR_TIMEOUT = -2;
const int SC_QJS_ERR_INVALID = -3;
const int SC_QJS_ERR_UNKNOWN_CALL = -4;
