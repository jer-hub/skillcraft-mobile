#include "sc_qjs.h"

#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "quickjs.h"

typedef struct {
  int32_t id;
  JSValue resolve;
  JSValue reject;
} pending_call;

struct sc_qjs {
  JSRuntime* rt;
  JSContext* ctx;
  int64_t owner;
  sc_qjs_host_fn host;

  int32_t next_call_id;
  pending_call* calls;
  int32_t n_calls;
  int32_t cap_calls;

  int64_t deadline_ms;  // 0 = no limit
  int timed_out;
};

static int64_t now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int interrupt_handler(JSRuntime* rt, void* opaque) {
  (void)rt;
  sc_qjs* q = (sc_qjs*)opaque;
  if (q->deadline_ms != 0 && now_ms() > q->deadline_ms) {
    q->timed_out = 1;
    return 1;
  }
  return 0;
}

static void start_clock(sc_qjs* q, int32_t timeout_ms) {
  q->timed_out = 0;
  q->deadline_ms = timeout_ms > 0 ? now_ms() + timeout_ms : 0;
}

static char* dup_cstr(const char* s, size_t len) {
  char* out = (char*)malloc(len + 1);
  if (out != NULL) {
    memcpy(out, s, len);
    out[len] = '\0';
  }
  return out;
}

static char* dup_js_string(JSContext* ctx, JSValueConst v) {
  size_t len = 0;
  const char* s = JS_ToCStringLen2(ctx, &len, v, false);
  if (s == NULL) return dup_cstr("<unprintable>", 13);
  char* out = dup_cstr(s, len);
  JS_FreeCString(ctx, s);
  return out;
}

// Takes the pending exception and returns "message\nstack" (malloc'd).
static char* take_exception(JSContext* ctx) {
  JSValue exc = JS_GetException(ctx);
  char* msg = dup_js_string(ctx, exc);
  if (JS_IsError(exc)) {
    JSValue stack = JS_GetPropertyStr(ctx, exc, "stack");
    if (!JS_IsUndefined(stack)) {
      char* st = dup_js_string(ctx, stack);
      size_t a = strlen(msg), b = strlen(st);
      char* both = (char*)malloc(a + b + 2);
      if (both != NULL) {
        memcpy(both, msg, a);
        both[a] = '\n';
        memcpy(both + a + 1, st, b + 1);
        free(msg);
        msg = both;
      }
      free(st);
    }
    JS_FreeValue(ctx, stack);
  }
  JS_FreeValue(ctx, exc);
  return msg;
}

static int32_t fail(sc_qjs* q, char** out) {
  char* msg = take_exception(q->ctx);
  if (q->timed_out) {
    JS_ResetUncatchableError(q->ctx);
  }
  if (out != NULL) {
    *out = msg;
  } else {
    free(msg);
  }
  return q->timed_out ? SC_QJS_ERR_TIMEOUT : SC_QJS_ERR_EXCEPTION;
}

static int32_t run_jobs(sc_qjs* q, char** out) {
  while (JS_IsJobPending(q->rt)) {
    JSContext* job_ctx = NULL;
    if (JS_ExecutePendingJob(q->rt, &job_ctx) < 0) {
      return fail(q, out);
    }
  }
  return SC_QJS_OK;
}

// __host(name, payloadJson) -> Promise
static JSValue js_host(JSContext* ctx, JSValueConst this_val, int argc, JSValueConst* argv) {
  (void)this_val;
  sc_qjs* q = (sc_qjs*)JS_GetContextOpaque(ctx);
  if (argc < 1) {
    return JS_ThrowTypeError(ctx, "__host(name, payloadJson) needs a name");
  }
  const char* name = JS_ToCString(ctx, argv[0]);
  if (name == NULL) return JS_EXCEPTION;
  const char* payload = argc > 1 && !JS_IsUndefined(argv[1]) ? JS_ToCString(ctx, argv[1]) : NULL;

  JSValue funcs[2];
  JSValue promise = JS_NewPromiseCapability(ctx, funcs);
  if (JS_IsException(promise)) {
    JS_FreeCString(ctx, name);
    if (payload != NULL) JS_FreeCString(ctx, payload);
    return promise;
  }

  if (q->n_calls == q->cap_calls) {
    int32_t cap = q->cap_calls == 0 ? 8 : q->cap_calls * 2;
    pending_call* grown = (pending_call*)realloc(q->calls, sizeof(pending_call) * cap);
    if (grown == NULL) {
      JS_FreeValue(ctx, funcs[0]);
      JS_FreeValue(ctx, funcs[1]);
      JS_FreeValue(ctx, promise);
      JS_FreeCString(ctx, name);
      if (payload != NULL) JS_FreeCString(ctx, payload);
      return JS_ThrowOutOfMemory(ctx);
    }
    q->calls = grown;
    q->cap_calls = cap;
  }
  const int32_t id = ++q->next_call_id;
  q->calls[q->n_calls++] = (pending_call){id, funcs[0], funcs[1]};

  q->host(q->owner, id, name, payload != NULL ? payload : "null");

  JS_FreeCString(ctx, name);
  if (payload != NULL) JS_FreeCString(ctx, payload);
  return promise;
}

sc_qjs* sc_qjs_new(int64_t owner, int64_t memory_limit, sc_qjs_host_fn host) {
  if (host == NULL) return NULL;
  sc_qjs* q = (sc_qjs*)calloc(1, sizeof(sc_qjs));
  if (q == NULL) return NULL;
  q->owner = owner;
  q->host = host;
  q->rt = JS_NewRuntime();
  if (q->rt == NULL) {
    free(q);
    return NULL;
  }
  if (memory_limit > 0) JS_SetMemoryLimit(q->rt, (size_t)memory_limit);
  JS_SetInterruptHandler(q->rt, interrupt_handler, q);
  q->ctx = JS_NewContext(q->rt);
  if (q->ctx == NULL) {
    JS_FreeRuntime(q->rt);
    free(q);
    return NULL;
  }
  JS_SetContextOpaque(q->ctx, q);

  JSValue global = JS_GetGlobalObject(q->ctx);
  JS_SetPropertyStr(q->ctx, global, "__host", JS_NewCFunction(q->ctx, js_host, "__host", 2));
  JS_FreeValue(q->ctx, global);
  return q;
}

void sc_qjs_free(sc_qjs* q) {
  if (q == NULL) return;
  for (int32_t i = 0; i < q->n_calls; i++) {
    JS_FreeValue(q->ctx, q->calls[i].resolve);
    JS_FreeValue(q->ctx, q->calls[i].reject);
  }
  free(q->calls);
  JS_FreeContext(q->ctx);
  JS_FreeRuntime(q->rt);
  free(q);
}

int32_t sc_qjs_eval(sc_qjs* q, const char* code, const char* filename,
                    int32_t timeout_ms, char** out) {
  if (out != NULL) *out = NULL;
  if (q == NULL || code == NULL) return SC_QJS_ERR_INVALID;
  start_clock(q, timeout_ms);

  JSValue result = JS_Eval(q->ctx, code, strlen(code),
                           filename != NULL ? filename : "<eval>", JS_EVAL_TYPE_GLOBAL);
  if (JS_IsException(result)) return fail(q, out);

  if (out != NULL) {
    JSValue json = JS_JSONStringify(q->ctx, result, JS_UNDEFINED, JS_UNDEFINED);
    if (JS_IsException(json)) {
      JS_FreeValue(q->ctx, result);
      return fail(q, out);
    }
    *out = JS_IsUndefined(json) ? dup_cstr("null", 4) : dup_js_string(q->ctx, json);
    JS_FreeValue(q->ctx, json);
  }
  JS_FreeValue(q->ctx, result);

  char* job_error = NULL;
  const int32_t rc = run_jobs(q, &job_error);
  if (rc != SC_QJS_OK && out != NULL) {
    free(*out);  // report the job failure instead of the completion value
    *out = job_error;
  } else {
    free(job_error);
  }
  return rc;
}

int32_t sc_qjs_resolve(sc_qjs* q, int32_t call_id, int32_t ok, const char* json,
                       int32_t timeout_ms, char** out) {
  if (out != NULL) *out = NULL;
  if (q == NULL) return SC_QJS_ERR_INVALID;

  int32_t index = -1;
  for (int32_t i = 0; i < q->n_calls; i++) {
    if (q->calls[i].id == call_id) {
      index = i;
      break;
    }
  }
  if (index < 0) return SC_QJS_ERR_UNKNOWN_CALL;
  pending_call call = q->calls[index];
  q->calls[index] = q->calls[--q->n_calls];

  start_clock(q, timeout_ms);
  const char* text = json != NULL ? json : "null";
  JSValue arg;
  if (ok) {
    arg = JS_ParseJSON(q->ctx, text, strlen(text), "<host>");
    if (JS_IsException(arg)) {
      // Malformed host reply: reject instead so the script sees it.
      JS_FreeValue(q->ctx, JS_GetException(q->ctx));
      ok = 0;
      arg = JS_NewError(q->ctx);
      JS_SetPropertyStr(q->ctx, arg, "message", JS_NewString(q->ctx, "host returned invalid JSON"));
    }
  } else {
    arg = JS_NewError(q->ctx);
    JS_SetPropertyStr(q->ctx, arg, "message", JS_NewString(q->ctx, text));
  }

  JSValue r = JS_Call(q->ctx, ok ? call.resolve : call.reject, JS_UNDEFINED, 1, &arg);
  JS_FreeValue(q->ctx, arg);
  JS_FreeValue(q->ctx, call.resolve);
  JS_FreeValue(q->ctx, call.reject);
  if (JS_IsException(r)) return fail(q, out);
  JS_FreeValue(q->ctx, r);

  return run_jobs(q, out);
}

int32_t sc_qjs_run_jobs(sc_qjs* q, int32_t timeout_ms, char** out) {
  if (out != NULL) *out = NULL;
  if (q == NULL) return SC_QJS_ERR_INVALID;
  start_clock(q, timeout_ms);
  return run_jobs(q, out);
}

int32_t sc_qjs_pending_calls(sc_qjs* q) { return q == NULL ? 0 : q->n_calls; }

void sc_qjs_string_free(char* s) { free(s); }
