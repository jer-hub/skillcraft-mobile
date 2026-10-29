// SkillCraft QuickJS bridge.
//
// One sc_qjs = one isolated QuickJS runtime + context (a tool server).
// Scripts reach the app only through the global `__host(name, payloadJson)`,
// which returns a Promise. The bridge calls the registered host callback
// synchronously with a call id; the app does its (possibly async) work and
// later settles the promise with sc_qjs_resolve.
//
// Threading: all functions must be called from the thread that created the
// handle, and the host callback runs on that same thread (re-entrantly, from
// inside sc_qjs_eval / sc_qjs_resolve / sc_qjs_run_jobs). The callback must
// not call back into the bridge; it should only record the request.

#ifndef SC_QJS_H
#define SC_QJS_H

#include <stdint.h>

#if defined(_WIN32)
#define SC_QJS_API __declspec(dllexport)
#else
#define SC_QJS_API __attribute__((visibility("default"))) __attribute__((used))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct sc_qjs sc_qjs;

// (owner, call_id, name, payload_json). Strings are only valid during the call.
typedef void (*sc_qjs_host_fn)(int64_t owner, int32_t call_id,
                               const char* name, const char* payload_json);

#define SC_QJS_OK 0
#define SC_QJS_ERR_EXCEPTION -1  // script threw; *out holds the message
#define SC_QJS_ERR_TIMEOUT -2    // interrupted after timeout_ms
#define SC_QJS_ERR_INVALID -3
#define SC_QJS_ERR_UNKNOWN_CALL -4

// Creates a runtime with `memory_limit` bytes (0 = unlimited). `owner` is
// passed back to `host` so one callback can serve many runtimes.
SC_QJS_API sc_qjs* sc_qjs_new(int64_t owner, int64_t memory_limit, sc_qjs_host_fn host);

SC_QJS_API void sc_qjs_free(sc_qjs* q);

// Evaluates a global script, then runs pending jobs. On success *out (if not
// NULL) receives the JSON encoding of the completion value ("null" when it is
// not JSON-representable). On SC_QJS_ERR_EXCEPTION *out receives the error
// message and stack. Free *out with sc_qjs_string_free.
SC_QJS_API int32_t sc_qjs_eval(sc_qjs* q, const char* code, const char* filename,
                               int32_t timeout_ms, char** out);

// Settles the promise returned by the `__host` call `call_id`: resolves with
// JSON.parse(json) when ok != 0, otherwise rejects with Error(json). Then
// runs pending jobs. *out as for sc_qjs_eval on exceptions.
SC_QJS_API int32_t sc_qjs_resolve(sc_qjs* q, int32_t call_id, int32_t ok,
                                  const char* json, int32_t timeout_ms, char** out);

// Runs queued promise jobs until none remain.
SC_QJS_API int32_t sc_qjs_run_jobs(sc_qjs* q, int32_t timeout_ms, char** out);

// Number of __host calls still waiting for sc_qjs_resolve.
SC_QJS_API int32_t sc_qjs_pending_calls(sc_qjs* q);

SC_QJS_API void sc_qjs_string_free(char* s);

#ifdef __cplusplus
}
#endif

#endif  // SC_QJS_H
