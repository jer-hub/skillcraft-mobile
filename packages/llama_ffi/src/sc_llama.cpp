#include "sc_llama.h"

#include <atomic>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <string>
#include <vector>

#include "json-schema-to-grammar.h"
#include "json.h"
#include "llama.h"

struct sc_handle {
  llama_model* model = nullptr;
  llama_context* ctx = nullptr;
  const llama_vocab* vocab = nullptr;

  llama_sampler* chain = nullptr;    // top-k -> top-p -> temp -> dist
  llama_sampler* grammar = nullptr;  // optional GBNF constraint

  std::vector<llama_token_data> candidates;  // reused for grammar resampling
  llama_token pending = LLAMA_TOKEN_NULL;    // sampled but not yet decoded
  std::vector<llama_token> cached;           // tokens held in the KV cache
  int32_t n_reused = 0;                      // prompt tokens served from cache
  int32_t n_generated = 0;
  int32_t max_tokens = 0;

  std::atomic<bool> cancelled{false};
  std::string error;
};

static thread_local std::string g_load_error;

static constexpr int32_t kTopK = 40;

static char* dup_string(const std::string& s) {
  char* out = static_cast<char*>(std::malloc(s.size() + 1));
  if (out != nullptr) {
    std::memcpy(out, s.c_str(), s.size() + 1);
  }
  return out;
}

static bool abort_cb(void* data) {
  return static_cast<sc_handle*>(data)->cancelled.load(std::memory_order_relaxed);
}

static void free_samplers(sc_handle* h) {
  if (h->chain != nullptr) {
    llama_sampler_free(h->chain);
    h->chain = nullptr;
  }
  if (h->grammar != nullptr) {
    llama_sampler_free(h->grammar);
    h->grammar = nullptr;
  }
}

static void clear_cache(sc_handle* h) {
  llama_memory_clear(llama_get_memory(h->ctx), true);
  h->cached.clear();
}

static int32_t n_past(const sc_handle* h) { return static_cast<int32_t>(h->cached.size()); }

// Decodes `tokens` in n_batch-sized chunks, recording them in `cached`.
// On failure the cache may hold a partial batch, so it is dropped entirely.
static int32_t decode_tokens(sc_handle* h, const llama_token* tokens, int32_t n) {
  const int32_t n_batch = static_cast<int32_t>(llama_n_batch(h->ctx));
  for (int32_t i = 0; i < n; i += n_batch) {
    const int32_t chunk = (n - i) < n_batch ? (n - i) : n_batch;
    const int32_t rc = llama_decode(
        h->ctx, llama_batch_get_one(const_cast<llama_token*>(tokens + i), chunk));
    if (rc == 2 || h->cancelled.load()) {
      clear_cache(h);
      h->error = "cancelled";
      return SC_ERR_CANCELLED;
    }
    if (rc != 0) {
      clear_cache(h);
      h->error = "llama_decode failed with code " + std::to_string(rc);
      return SC_ERR_DECODE;
    }
    h->cached.insert(h->cached.end(), tokens + i, tokens + i + chunk);
  }
  return SC_OK;
}

// Keeps the longest cached prefix shared with `tokens` and drops the rest,
// so only the new suffix has to be evaluated. Prompt evaluation is the slow
// part on this hardware (~11 tok/s), and agent steps re-send the previous
// prompt plus a tool result, so most of it is usually already cached.
static void reuse_prefix(sc_handle* h, const std::vector<llama_token>& tokens) {
  size_t n_keep = 0;
  while (n_keep < h->cached.size() && n_keep < tokens.size() &&
         h->cached[n_keep] == tokens[n_keep]) {
    n_keep++;
  }
  // The last prompt token must be evaluated again to get fresh logits.
  if (n_keep == tokens.size() && n_keep > 0) {
    n_keep--;
  }
  if (n_keep < h->cached.size()) {
    if (llama_memory_seq_rm(llama_get_memory(h->ctx), 0, static_cast<llama_pos>(n_keep), -1)) {
      h->cached.resize(n_keep);
    } else {
      clear_cache(h);
    }
  }
  h->n_reused = n_past(h);
}

// Samples one token; with a grammar, uses rejection sampling like llama.cpp's
// common sampler: try the unconstrained pick first and only mask the full
// vocabulary (expensive with Qwen's ~152k tokens) when the grammar rejects it.
static llama_token sample(sc_handle* h) {
  llama_token id = llama_sampler_sample(h->chain, h->ctx, -1);
  if (h->grammar == nullptr) {
    return id;
  }

  llama_token_data single = {id, 1.0f, 0.0f};
  llama_token_data_array single_arr = {&single, 1, -1, false};
  llama_sampler_apply(h->grammar, &single_arr);
  if (single.logit == -INFINITY) {
    const float* logits = llama_get_logits_ith(h->ctx, -1);
    const int32_t n_vocab = llama_vocab_n_tokens(h->vocab);
    h->candidates.resize(n_vocab);
    for (llama_token t = 0; t < n_vocab; t++) {
      h->candidates[t] = {t, logits[t], 0.0f};
    }
    llama_token_data_array arr = {h->candidates.data(), h->candidates.size(), -1, false};
    llama_sampler_apply(h->grammar, &arr);
    llama_sampler_apply(h->chain, &arr);
    id = arr.data[arr.selected].id;
  }
  llama_sampler_accept(h->grammar, id);
  return id;
}

extern "C" {

SC_API void sc_backend_init(void) { llama_backend_init(); }

SC_API sc_handle* sc_load(const char* model_path, int32_t n_ctx, int32_t n_threads) {
  g_load_error.clear();
  if (model_path == nullptr || n_ctx <= 0 || n_threads <= 0) {
    g_load_error = "invalid arguments";
    return nullptr;
  }

  llama_model_params mparams = llama_model_default_params();
  mparams.n_gpu_layers = 0;
  mparams.load_mode = LLAMA_LOAD_MODE_MMAP;

  llama_model* model = llama_model_load_from_file(model_path, mparams);
  if (model == nullptr) {
    g_load_error = std::string("failed to load model: ") + model_path;
    return nullptr;
  }

  llama_context_params cparams = llama_context_default_params();
  cparams.n_ctx = static_cast<uint32_t>(n_ctx);
  cparams.n_batch = static_cast<uint32_t>(n_ctx);
  cparams.n_ubatch = 512;
  cparams.n_seq_max = 1;
  cparams.n_threads = n_threads;
  cparams.n_threads_batch = n_threads;
  cparams.no_perf = true;
  // Measured on Snapdragon 680: ~5% faster prompt and generation than off.
  cparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED;

  auto* h = new sc_handle();
  cparams.abort_callback = abort_cb;
  cparams.abort_callback_data = h;

  llama_context* ctx = llama_init_from_model(model, cparams);
  if (ctx == nullptr) {
    g_load_error = "failed to create context";
    llama_model_free(model);
    delete h;
    return nullptr;
  }

  h->model = model;
  h->ctx = ctx;
  h->vocab = llama_model_get_vocab(model);
  return h;
}

SC_API const char* sc_last_load_error(void) { return g_load_error.c_str(); }

SC_API void sc_free(sc_handle* h) {
  if (h == nullptr) {
    return;
  }
  free_samplers(h);
  if (h->ctx != nullptr) {
    llama_free(h->ctx);
  }
  if (h->model != nullptr) {
    llama_model_free(h->model);
  }
  delete h;
}

SC_API int32_t sc_tokenize_count(sc_handle* h, const char* text) {
  if (h == nullptr || text == nullptr) {
    return SC_ERR_INVALID;
  }
  const int32_t len = static_cast<int32_t>(std::strlen(text));
  // A negative result is minus the required token count.
  const int32_t n = llama_tokenize(h->vocab, text, len, nullptr, 0, true, true);
  if (n == INT32_MIN) {
    return SC_ERR_TOKENIZE;
  }
  return n < 0 ? -n : n;
}

SC_API int32_t sc_n_ctx(sc_handle* h) {
  return h == nullptr ? 0 : static_cast<int32_t>(llama_n_ctx(h->ctx));
}

SC_API int32_t sc_begin(sc_handle* h, const char* prompt, const char* gbnf,
                        float temperature, float top_p, uint32_t seed,
                        int32_t max_tokens) {
  if (h == nullptr || prompt == nullptr || max_tokens <= 0) {
    return SC_ERR_INVALID;
  }
  h->cancelled.store(false);
  h->error.clear();
  h->pending = LLAMA_TOKEN_NULL;
  h->n_reused = 0;
  h->n_generated = 0;
  h->max_tokens = max_tokens;

  free_samplers(h);
  h->chain = llama_sampler_chain_init(llama_sampler_chain_default_params());
  if (temperature <= 0.0f) {
    llama_sampler_chain_add(h->chain, llama_sampler_init_greedy());
  } else {
    // top-k first (llama.cpp's default order): without it top-p sorts all
    // ~152k Qwen tokens on every step, a measurable cost on Cortex-A73.
    llama_sampler_chain_add(h->chain, llama_sampler_init_top_k(kTopK));
    llama_sampler_chain_add(h->chain, llama_sampler_init_top_p(top_p, 1));
    llama_sampler_chain_add(h->chain, llama_sampler_init_temp(temperature));
    llama_sampler_chain_add(h->chain, llama_sampler_init_dist(seed));
  }
  if (gbnf != nullptr && gbnf[0] != '\0') {
    h->grammar = llama_sampler_init_grammar(h->vocab, gbnf, "root");
    if (h->grammar == nullptr) {
      h->error = "failed to parse GBNF grammar";
      return SC_ERR_GRAMMAR;
    }
  }

  const int32_t len = static_cast<int32_t>(std::strlen(prompt));
  const int32_t n_needed = -llama_tokenize(h->vocab, prompt, len, nullptr, 0, true, true);
  if (n_needed <= 0) {
    h->error = "failed to tokenize prompt";
    return SC_ERR_TOKENIZE;
  }
  std::vector<llama_token> tokens(n_needed);
  if (llama_tokenize(h->vocab, prompt, len, tokens.data(), n_needed, true, true) < 0) {
    h->error = "failed to tokenize prompt";
    return SC_ERR_TOKENIZE;
  }
  if (n_needed >= sc_n_ctx(h)) {
    h->error = "prompt is " + std::to_string(n_needed) + " tokens, context is " +
               std::to_string(sc_n_ctx(h));
    return SC_ERR_CONTEXT_FULL;
  }
  reuse_prefix(h, tokens);
  return decode_tokens(h, tokens.data() + n_past(h), n_needed - n_past(h));
}

SC_API int32_t sc_n_reused(sc_handle* h) { return h == nullptr ? 0 : h->n_reused; }

SC_API int32_t sc_next(sc_handle* h, char* buf, int32_t buf_len) {
  if (h == nullptr || h->chain == nullptr || buf == nullptr || buf_len <= 0) {
    return SC_ERR_INVALID;
  }
  if (h->cancelled.load()) {
    h->error = "cancelled";
    return SC_ERR_CANCELLED;
  }

  // Feed back the token produced by the previous call.
  if (h->pending != LLAMA_TOKEN_NULL) {
    if (n_past(h) + 1 >= sc_n_ctx(h)) {
      h->error = "context window full";
      return SC_ERR_CONTEXT_FULL;
    }
    llama_token t = h->pending;
    h->pending = LLAMA_TOKEN_NULL;
    const int32_t rc = decode_tokens(h, &t, 1);
    if (rc != SC_OK) {
      return rc;
    }
  }
  if (h->n_generated >= h->max_tokens) {
    return SC_DONE;
  }

  const llama_token id = sample(h);
  if (llama_vocab_is_eog(h->vocab, id)) {
    return SC_DONE;
  }
  h->pending = id;
  h->n_generated++;

  const int32_t n = llama_token_to_piece(h->vocab, id, buf, buf_len, 0, false);
  if (n < 0) {
    h->error = "token piece needs " + std::to_string(-n) + " bytes";
    return SC_ERR_BUFFER;
  }
  return n;
}

SC_API void sc_cancel(sc_handle* h) {
  if (h != nullptr) {
    h->cancelled.store(true);
  }
}

SC_API const char* sc_last_error(sc_handle* h) {
  return h == nullptr ? "null handle" : h->error.c_str();
}

SC_API char* sc_json_schema_to_gbnf(const char* schema_json, char** error_out) {
  if (error_out != nullptr) {
    *error_out = nullptr;
  }
  try {
    const std::string gbnf =
        json_schema_to_grammar(common_json::parse(schema_json == nullptr ? "" : schema_json));
    return dup_string(gbnf);
  } catch (const std::exception& e) {
    if (error_out != nullptr) {
      *error_out = dup_string(e.what());
    }
    return nullptr;
  }
}

SC_API void sc_string_free(char* s) { std::free(s); }

SC_API const char* sc_system_info(void) { return llama_print_system_info(); }

}  // extern "C"
