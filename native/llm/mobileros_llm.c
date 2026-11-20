// A small C layer over llama.cpp for the app's on-device assistant (lib/agent/local/llm_native.dart).
// One model and context per handle; generation is grammar-constrained and greedy, so the output is
// always well-formed for the grammar the app passes. Calls on one handle must not overlap; ml_cancel
// may be called from any thread.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "llama.h"

#if defined(_WIN32)
#define ML_API __declspec(dllexport)
#else
#define ML_API __attribute__((visibility("default")))
#endif

typedef struct {
  struct llama_model *model;
  struct llama_context *ctx;
  const struct llama_vocab *vocab;
  const char *tmpl;
  int n_ctx;
  // The system prompt stays the same between instructions. Its evaluated state is kept, so each
  // instruction only evaluates its own text. (A state snapshot rather than reusing the KV cache: models
  // with recurrent layers, like Qwen3.5, cannot drop part of a sequence.)
  char *prefix;
  uint8_t *prefix_state;
  size_t prefix_state_size;
  volatile int cancel;  // a plain flag is enough: only ever set to 1, or cleared before a run
} ml_t;

static void ml_err(char *err, int err_len, const char *msg) {
  if (err && err_len > 0) snprintf(err, (size_t)err_len, "%s", msg);
}

static void quiet_log(enum ggml_log_level level, const char *text, void *data) {
  (void)level; (void)text; (void)data;
}

static bool ml_abort(void *data) { return ((ml_t *)data)->cancel != 0; }

ML_API void *ml_load(const char *path, int n_ctx, int n_threads, char *err, int err_len) {
  static int backend_ready = 0;
  if (!backend_ready) {
    llama_log_set(quiet_log, NULL);
    llama_backend_init();
    backend_ready = 1;
  }
  struct llama_model_params mp = llama_model_default_params();
  mp.n_gpu_layers = 0;  // CPU everywhere: phones differ too much for one GPU setup
  struct llama_model *model = llama_model_load_from_file(path, mp);
  if (!model) {
    ml_err(err, err_len, "could not load the model file");
    return NULL;
  }
  struct llama_context_params cp = llama_context_default_params();
  cp.n_ctx = (uint32_t)n_ctx;
  cp.n_batch = (uint32_t)n_ctx;
  if (n_threads > 0) {
    cp.n_threads = n_threads;
    cp.n_threads_batch = n_threads;
  }
  struct llama_context *ctx = llama_init_from_model(model, cp);
  if (!ctx) {
    llama_model_free(model);
    ml_err(err, err_len, "could not create the model context (out of memory?)");
    return NULL;
  }
  ml_t *h = (ml_t *)calloc(1, sizeof(ml_t));
  h->model = model;
  h->ctx = ctx;
  h->vocab = llama_model_get_vocab(model);
  h->tmpl = llama_model_chat_template(model, NULL);
  h->n_ctx = n_ctx;
  llama_set_abort_callback(ctx, ml_abort, h);
  return h;
}

ML_API void ml_cancel(void *handle) {
  if (handle) ((ml_t *)handle)->cancel = 1;
}

// The chat template applied to the messages; the caller frees it. NULL if the template fails.
static char *apply_template(ml_t *h, const struct llama_chat_message *msgs, size_t n_msg, bool add_ass) {
  size_t chars = 0;
  for (size_t i = 0; i < n_msg; i++) chars += strlen(msgs[i].content);
  int cap = (int)chars * 2 + 256;
  char *buf = (char *)malloc((size_t)cap);
  int n = llama_chat_apply_template(h->tmpl, msgs, n_msg, add_ass, buf, cap);
  if (n >= cap) {
    buf = (char *)realloc(buf, (size_t)n + 1);
    n = llama_chat_apply_template(h->tmpl, msgs, n_msg, add_ass, buf, n + 1);
  }
  if (n < 0) {
    free(buf);
    return NULL;
  }
  buf[n] = 0;
  return buf;
}

// Tokenizes and evaluates `text` after what the context already holds. 0, or an ml_generate error.
static int eval_text(ml_t *h, const char *text, bool first) {
  int len = (int)strlen(text);
  if (len == 0) return 0;
  llama_token *tokens = (llama_token *)malloc(sizeof(llama_token) * (size_t)h->n_ctx);
  int n = llama_tokenize(h->vocab, text, len, tokens, h->n_ctx, first && llama_vocab_get_add_bos(h->vocab), true);
  int rc = 0;
  if (n < 0 || n >= h->n_ctx) rc = -3;
  else if (llama_decode(h->ctx, llama_batch_get_one(tokens, n)) != 0) rc = h->cancel ? -6 : -5;
  free(tokens);
  return rc;
}

// Writes the model's answer to `system` + `user` into `out` (NUL-terminated). The answer follows
// `grammar` (GBNF, root rule "root"). Returns the answer's length, or a negative error code:
// -1 bad arguments, -2 chat template, -3 prompt too long, -4 bad grammar, -5 decode failed,
// -6 cancelled, -7 output buffer too small.
ML_API int ml_generate(void *handle, const char *system, const char *user, const char *grammar,
                       int max_tokens, char *out, int out_len) {
  ml_t *h = (ml_t *)handle;
  if (!h || !system || !user || !grammar || !out || out_len <= 0) return -1;
  h->cancel = 0;
  out[0] = 0;

  struct llama_chat_message msgs[2] = {{"system", system}, {"user", user}};
  char *full = apply_template(h, msgs, 2, true);
  char *prefix = apply_template(h, msgs, 1, false);
  if (!full || !prefix) {
    free(full);
    free(prefix);
    return -2;
  }
  size_t plen = strlen(prefix);
  bool split = strncmp(full, prefix, plen) == 0;  // the template renders the system turn on its own

  llama_memory_t mem = llama_get_memory(h->ctx);
  llama_memory_clear(mem, true);
  int rc = 0;
  if (split && h->prefix && strcmp(h->prefix, prefix) == 0 &&
      llama_state_seq_set_data(h->ctx, h->prefix_state, h->prefix_state_size, 0) == h->prefix_state_size) {
    rc = eval_text(h, full + plen, false);
  } else if (split) {
    free(h->prefix);
    free(h->prefix_state);
    h->prefix = NULL;
    h->prefix_state = NULL;
    rc = eval_text(h, prefix, true);
    if (rc == 0) {
      size_t size = llama_state_seq_get_size(h->ctx, 0);
      uint8_t *state = (uint8_t *)malloc(size);
      if (llama_state_seq_get_data(h->ctx, state, size, 0) == size) {
        h->prefix = prefix;
        prefix = NULL;
        h->prefix_state = state;
        h->prefix_state_size = size;
      } else {
        free(state);
      }
      rc = eval_text(h, full + plen, false);
    }
  } else {
    rc = eval_text(h, full, true);
  }
  free(full);
  free(prefix);
  if (rc != 0) return rc;

  struct llama_sampler *grammar_s = llama_sampler_init_grammar(h->vocab, grammar, "root");
  if (!grammar_s) return -4;
  struct llama_sampler *chain = llama_sampler_chain_init(llama_sampler_chain_default_params());
  llama_sampler_chain_add(chain, grammar_s);
  llama_sampler_chain_add(chain, llama_sampler_init_greedy());

  int len = 0;
  for (int i = 0; i < max_tokens; i++) {
    if (h->cancel) { rc = -6; break; }
    llama_token t = llama_sampler_sample(chain, h->ctx, -1);
    if (llama_vocab_is_eog(h->vocab, t)) break;
    char piece[256];
    int m = llama_token_to_piece(h->vocab, t, piece, sizeof piece, 0, false);
    if (m < 0) m = 0;
    if (len + m >= out_len) { rc = -7; break; }
    memcpy(out + len, piece, (size_t)m);
    len += m;
    if (llama_decode(h->ctx, llama_batch_get_one(&t, 1)) != 0) {
      rc = h->cancel ? -6 : -5;
      break;
    }
  }
  llama_sampler_free(chain);
  out[len] = 0;
  return rc != 0 ? rc : len;
}

ML_API void ml_free(void *handle) {
  ml_t *h = (ml_t *)handle;
  if (!h) return;
  llama_free(h->ctx);
  llama_model_free(h->model);
  free(h->prefix);
  free(h->prefix_state);
  free(h);
}
