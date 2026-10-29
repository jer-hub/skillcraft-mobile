import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'bindings_generated.dart';
import 'utf8_accumulator.dart';

const _libName = 'sc_llama';

final DynamicLibrary _dylib = () {
  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open('lib$_libName.so');
  }
  if (Platform.isWindows) return DynamicLibrary.open('$_libName.dll');
  if (Platform.isMacOS) return DynamicLibrary.open('lib$_libName.dylib');
  throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
}();

final ScLlamaBindings _bindings = ScLlamaBindings(_dylib);

bool _backendReady = false;

/// Failure reported by the native engine.
class LlamaException implements Exception {
  LlamaException(this.code, this.message);

  /// One of the `SC_ERR_*` codes (0 for load failures).
  final int code;
  final String message;

  bool get isCancelled => code == SC_ERR_CANCELLED;
  bool get isContextFull => code == SC_ERR_CONTEXT_FULL;

  @override
  String toString() => 'LlamaException($code): $message';
}

/// Sampling settings for one generation.
class GenerationOptions {
  const GenerationOptions({
    this.temperature = 0.2,
    this.topP = 0.9,
    this.seed = 0xFFFFFFFF,
    this.maxTokens = 512,
    this.grammar,
  });

  /// <= 0 selects greedy decoding.
  final double temperature;
  final double topP;

  /// 0xFFFFFFFF (LLAMA_DEFAULT_SEED) picks a random seed.
  final int seed;
  final int maxTokens;

  /// Optional GBNF grammar with a `root` rule.
  final String? grammar;
}

/// A loaded model and context.
///
/// Every call blocks the calling thread, so use it from a background isolate,
/// never from the UI isolate. Only [cancel] may be used from elsewhere, via
/// [address].
class LlamaModel {
  LlamaModel._(this._handle);

  final Pointer<ScHandle> _handle;
  bool _disposed = false;

  /// Loads a GGUF model with mmap. Throws [LlamaException] on failure.
  factory LlamaModel.load(
    String path, {
    int contextTokens = 2048,
    int threads = 4,
  }) {
    if (!_backendReady) {
      _bindings.sc_backend_init();
      _backendReady = true;
    }
    final cPath = path.toNativeUtf8();
    try {
      final handle = _bindings.sc_load(cPath.cast(), contextTokens, threads);
      if (handle == nullptr) {
        throw LlamaException(
            0, _bindings.sc_last_load_error().cast<Utf8>().toDartString());
      }
      return LlamaModel._(handle);
    } finally {
      malloc.free(cPath);
    }
  }

  /// Native handle address, for [cancel] from another isolate.
  int get address => _handle.address;

  /// Requests the generation running on [address] to stop. Thread-safe.
  static void cancel(int address) =>
      _bindings.sc_cancel(Pointer<ScHandle>.fromAddress(address));

  int get contextTokens => _bindings.sc_n_ctx(_checked);

  /// Number of tokens [text] encodes to (special tokens included).
  int tokenCount(String text) {
    final cText = text.toNativeUtf8();
    try {
      final n = _bindings.sc_tokenize_count(_checked, cText.cast());
      if (n < 0) throw LlamaException(n, 'tokenization failed');
      return n;
    } finally {
      malloc.free(cText);
    }
  }

  /// Evaluates [prompt] and yields generated text as it is produced.
  ///
  /// Throws [LlamaException] on errors, including cancellation.
  Iterable<String> generate(String prompt, GenerationOptions options) sync* {
    final handle = _checked;
    final cPrompt = prompt.toNativeUtf8();
    final cGrammar = options.grammar?.toNativeUtf8();
    const bufLen = 256;
    final buf = malloc<Uint8>(bufLen);
    try {
      final rc = _bindings.sc_begin(
        handle,
        cPrompt.cast(),
        cGrammar?.cast() ?? nullptr,
        options.temperature,
        options.topP,
        options.seed,
        options.maxTokens,
      );
      if (rc != SC_OK) throw _error(rc);

      final utf8 = Utf8Accumulator();
      while (true) {
        final n = _bindings.sc_next(handle, buf.cast(), bufLen);
        if (n == SC_DONE) break;
        if (n < 0) throw _error(n);
        final text = utf8.add(buf.asTypedList(n));
        if (text.isNotEmpty) yield text;
      }
      final rest = utf8.close();
      if (rest.isNotEmpty) yield rest;
    } finally {
      malloc.free(buf);
      malloc.free(cPrompt);
      if (cGrammar != null) malloc.free(cGrammar);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _bindings.sc_free(_handle);
  }

  Pointer<ScHandle> get _checked {
    if (_disposed) throw StateError('LlamaModel used after dispose');
    return _handle;
  }

  LlamaException _error(int code) => LlamaException(
      code, _bindings.sc_last_error(_handle).cast<Utf8>().toDartString());
}

/// Converts a JSON Schema (as JSON text) into a GBNF grammar using llama.cpp's
/// converter. Throws [FormatException] for schemas it cannot handle.
String jsonSchemaToGbnf(String schemaJson) {
  final cSchema = schemaJson.toNativeUtf8();
  final errOut = calloc<Pointer<Char>>();
  try {
    final result = _bindings.sc_json_schema_to_gbnf(cSchema.cast(), errOut);
    if (result == nullptr) {
      final err = errOut.value;
      final message =
          err == nullptr ? 'unknown error' : err.cast<Utf8>().toDartString();
      if (err != nullptr) _bindings.sc_string_free(err);
      throw FormatException('JSON Schema to GBNF failed: $message');
    }
    final gbnf = result.cast<Utf8>().toDartString();
    _bindings.sc_string_free(result);
    return gbnf;
  } finally {
    malloc.free(cSchema);
    calloc.free(errOut);
  }
}

/// llama.cpp build and CPU feature summary.
String llamaSystemInfo() =>
    _bindings.sc_system_info().cast<Utf8>().toDartString();
