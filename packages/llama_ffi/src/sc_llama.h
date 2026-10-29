// SkillCraft C API over llama.cpp.
//
// Kept deliberately small and C-only so Dart FFI bindings stay stable across
// llama.cpp upgrades. Generation is a pull API (sc_begin + sc_next) rather than
// a callback API, so Dart never has to receive calls from native threads.
//
// Threading: every function except sc_cancel must be called from the single
// thread (Dart isolate) that owns the handle. sc_cancel may be called from any
// thread.

#ifndef SC_LLAMA_H
#define SC_LLAMA_H

#include <stdint.h>

#if defined(_WIN32)
#define SC_API __declspec(dllexport)
#else
#define SC_API __attribute__((visibility("default"))) __attribute__((used))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct sc_handle sc_handle;

// Status codes returned by sc_begin / sc_next (negative = error).
#define SC_OK 0
#define SC_ERR_INVALID -1
#define SC_ERR_TOKENIZE -2
#define SC_ERR_CONTEXT_FULL -3
#define SC_ERR_DECODE -4
#define SC_ERR_GRAMMAR -5
#define SC_ERR_CANCELLED -6
#define SC_ERR_BUFFER -7

// Initialises the llama.cpp backend. Call once per process.
SC_API void sc_backend_init(void);

// Loads a GGUF model (mmap) and creates a context. Returns NULL on failure;
// the reason is available through sc_last_load_error().
SC_API sc_handle* sc_load(const char* model_path, int32_t n_ctx, int32_t n_threads);

// Message for the most recent failed sc_load on this thread.
SC_API const char* sc_last_load_error(void);

// Frees the context and model.
SC_API void sc_free(sc_handle* h);

// Number of tokens `text` tokenizes to (special tokens parsed), or < 0 on error.
SC_API int32_t sc_tokenize_count(sc_handle* h, const char* text);

// Context window size in tokens.
SC_API int32_t sc_n_ctx(sc_handle* h);

// Sets up sampling and evaluates `prompt`. The KV cache is kept between calls:
// the longest prefix shared with the previous prompt (plus its generated
// tokens) is reused and only the remainder is evaluated.
// `gbnf` may be NULL for unconstrained generation; its start rule is "root".
// Returns SC_OK or a negative SC_ERR_*; details via sc_last_error().
SC_API int32_t sc_begin(sc_handle* h, const char* prompt, const char* gbnf,
                        float temperature, float top_p, uint32_t seed,
                        int32_t max_tokens);

// Prompt tokens the last sc_begin took from the KV cache instead of evaluating.
SC_API int32_t sc_n_reused(sc_handle* h);

// Samples the next token and writes its UTF-8 bytes (not null-terminated,
// possibly a partial code point) into `buf`.
// Returns the number of bytes written (may be 0 for byte-less tokens),
// SC_DONE when generation finished (end of generation token or max_tokens),
// or a negative SC_ERR_*.
#define SC_DONE INT32_MIN
SC_API int32_t sc_next(sc_handle* h, char* buf, int32_t buf_len);

// Requests that the running sc_begin / sc_next stop as soon as possible.
// Thread-safe. The flag is cleared by the next sc_begin.
SC_API void sc_cancel(sc_handle* h);

// Message describing the last error on this handle (never NULL).
SC_API const char* sc_last_error(sc_handle* h);

// Loads an embedding model (e.g. nomic-embed-text) with pooled sequence
// embeddings. Texts longer than n_ctx tokens are truncated. NULL on failure,
// reason via sc_last_load_error(). Free with sc_free.
SC_API sc_handle* sc_load_embedder(const char* model_path, int32_t n_ctx, int32_t n_threads);

// Embedding width of a handle from sc_load_embedder.
SC_API int32_t sc_n_embd(sc_handle* h);

// Writes the L2-normalised embedding of `text` into `out` (out_len >=
// sc_n_embd). Returns the number of floats written or a negative SC_ERR_*.
SC_API int32_t sc_embed(sc_handle* h, const char* text, float* out, int32_t out_len);

// Converts a JSON Schema document into a GBNF grammar using llama.cpp's own
// converter. Returns a malloc'd string to release with sc_string_free, or NULL
// on error with the reason in *error_out (also to release with sc_string_free).
SC_API char* sc_json_schema_to_gbnf(const char* schema_json, char** error_out);

SC_API void sc_string_free(char* s);

// llama.cpp/ggml build and CPU feature summary (static string).
SC_API const char* sc_system_info(void);

#ifdef __cplusplus
}
#endif

#endif  // SC_LLAMA_H
