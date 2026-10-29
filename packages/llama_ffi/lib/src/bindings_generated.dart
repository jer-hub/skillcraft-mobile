// Bindings for `src/sc_llama.h`.
//
// Written by hand in ffigen's style (ffigen needs libclang, which is not part
// of the default toolchain). Regenerate with `dart run ffigen --config
// ffigen.yaml` when libclang is available and keep the result identical in
// shape.
// ignore_for_file: type=lint
import 'dart:ffi' as ffi;

/// Opaque `sc_handle`.
final class ScHandle extends ffi.Opaque {}

class ScLlamaBindings {
  ScLlamaBindings(ffi.DynamicLibrary dynamicLibrary)
      : _lookup = dynamicLibrary.lookup;

  final ffi.Pointer<T> Function<T extends ffi.NativeType>(String symbolName)
      _lookup;

  late final sc_backend_init = _lookup<ffi.NativeFunction<ffi.Void Function()>>(
    'sc_backend_init',
  ).asFunction<void Function()>();

  late final sc_load = _lookup<
          ffi.NativeFunction<
              ffi.Pointer<ScHandle> Function(
                  ffi.Pointer<ffi.Char>, ffi.Int32, ffi.Int32)>>('sc_load')
      .asFunction<
          ffi.Pointer<ScHandle> Function(ffi.Pointer<ffi.Char>, int, int)>();

  late final sc_last_load_error =
      _lookup<ffi.NativeFunction<ffi.Pointer<ffi.Char> Function()>>(
    'sc_last_load_error',
  ).asFunction<ffi.Pointer<ffi.Char> Function()>();

  late final sc_free =
      _lookup<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ScHandle>)>>(
    'sc_free',
  ).asFunction<void Function(ffi.Pointer<ScHandle>)>();

  late final sc_tokenize_count = _lookup<
          ffi.NativeFunction<
              ffi.Int32 Function(ffi.Pointer<ScHandle>,
                  ffi.Pointer<ffi.Char>)>>('sc_tokenize_count')
      .asFunction<int Function(ffi.Pointer<ScHandle>, ffi.Pointer<ffi.Char>)>();

  late final sc_n_ctx =
      _lookup<ffi.NativeFunction<ffi.Int32 Function(ffi.Pointer<ScHandle>)>>(
    'sc_n_ctx',
  ).asFunction<int Function(ffi.Pointer<ScHandle>)>();

  late final sc_begin = _lookup<
          ffi.NativeFunction<
              ffi.Int32 Function(
                  ffi.Pointer<ScHandle>,
                  ffi.Pointer<ffi.Char>,
                  ffi.Pointer<ffi.Char>,
                  ffi.Float,
                  ffi.Float,
                  ffi.Uint32,
                  ffi.Int32)>>('sc_begin')
      .asFunction<
          int Function(ffi.Pointer<ScHandle>, ffi.Pointer<ffi.Char>,
              ffi.Pointer<ffi.Char>, double, double, int, int)>();

  late final sc_load_embedder = _lookup<
          ffi.NativeFunction<
              ffi.Pointer<ScHandle> Function(
                  ffi.Pointer<ffi.Char>, ffi.Int32, ffi.Int32)>>('sc_load_embedder')
      .asFunction<
          ffi.Pointer<ScHandle> Function(ffi.Pointer<ffi.Char>, int, int)>();

  late final sc_n_embd =
      _lookup<ffi.NativeFunction<ffi.Int32 Function(ffi.Pointer<ScHandle>)>>(
    'sc_n_embd',
  ).asFunction<int Function(ffi.Pointer<ScHandle>)>();

  late final sc_embed = _lookup<
          ffi.NativeFunction<
              ffi.Int32 Function(ffi.Pointer<ScHandle>, ffi.Pointer<ffi.Char>,
                  ffi.Pointer<ffi.Float>, ffi.Int32)>>('sc_embed')
      .asFunction<
          int Function(ffi.Pointer<ScHandle>, ffi.Pointer<ffi.Char>,
              ffi.Pointer<ffi.Float>, int)>();

  late final sc_n_reused =
      _lookup<ffi.NativeFunction<ffi.Int32 Function(ffi.Pointer<ScHandle>)>>(
    'sc_n_reused',
  ).asFunction<int Function(ffi.Pointer<ScHandle>)>();

  late final sc_next = _lookup<
          ffi.NativeFunction<
              ffi.Int32 Function(ffi.Pointer<ScHandle>, ffi.Pointer<ffi.Char>,
                  ffi.Int32)>>('sc_next')
      .asFunction<
          int Function(ffi.Pointer<ScHandle>, ffi.Pointer<ffi.Char>, int)>();

  late final sc_cancel =
      _lookup<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ScHandle>)>>(
    'sc_cancel',
  ).asFunction<void Function(ffi.Pointer<ScHandle>)>();

  late final sc_last_error = _lookup<
          ffi.NativeFunction<
              ffi.Pointer<ffi.Char> Function(
                  ffi.Pointer<ScHandle>)>>('sc_last_error')
      .asFunction<ffi.Pointer<ffi.Char> Function(ffi.Pointer<ScHandle>)>();

  late final sc_json_schema_to_gbnf = _lookup<
          ffi.NativeFunction<
              ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char>,
                  ffi.Pointer<ffi.Pointer<ffi.Char>>)>>('sc_json_schema_to_gbnf')
      .asFunction<
          ffi.Pointer<ffi.Char> Function(
              ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Pointer<ffi.Char>>)>();

  late final sc_string_free =
      _lookup<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Char>)>>(
    'sc_string_free',
  ).asFunction<void Function(ffi.Pointer<ffi.Char>)>();

  late final sc_system_info =
      _lookup<ffi.NativeFunction<ffi.Pointer<ffi.Char> Function()>>(
    'sc_system_info',
  ).asFunction<ffi.Pointer<ffi.Char> Function()>();
}

const int SC_OK = 0;
const int SC_ERR_INVALID = -1;
const int SC_ERR_TOKENIZE = -2;
const int SC_ERR_CONTEXT_FULL = -3;
const int SC_ERR_DECODE = -4;
const int SC_ERR_GRAMMAR = -5;
const int SC_ERR_CANCELLED = -6;
const int SC_ERR_BUFFER = -7;
const int SC_DONE = -2147483648;
