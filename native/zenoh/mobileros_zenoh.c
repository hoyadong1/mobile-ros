// Thin C layer over zenoh-pico for Mobile ROS's Zenoh connection (ROS 2 robots on rmw_zenoh).
//
// Zenoh calls back on its own threads; Dart cannot run there, so every callback copies what it got into
// one event queue per session and Dart polls it (mz_poll), like the Cyclone DDS layer in native/dds.
// Everything here is bytes and key strings: ROS semantics (key layout, CDR, attachments, the graph from
// liveliness tokens) live in Dart (lib/zenoh/).
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "zenoh-pico.h"

#if defined(_WIN32)
#define MZ_EXPORT __declspec(dllexport)
#else
#define MZ_EXPORT __attribute__((visibility("default")))
#endif

#define MZ_MAX_SESSIONS 4
#define MZ_MAX_SUBS 256
#define MZ_MAX_TOKENS 64
#define MZ_MAX_QUEUE 20000  // events kept when Dart does not poll; the oldest go first

enum {
  MZ_SAMPLE = 1,          // data on a subscription
  MZ_REPLY = 2,           // a reply to a query
  MZ_REPLY_ERROR = 3,     // an error reply to a query
  MZ_QUERY_DONE = 4,      // no more replies for a query
  MZ_ALIVE = 5,           // a liveliness token appeared (subscription or liveliness query)
  MZ_GONE = 6,            // a liveliness token disappeared
};

typedef struct mz_event {
  int32_t kind;
  int32_t id;  // subscription or query id
  char *key;
  uint8_t *payload;
  int32_t payload_len;
  uint8_t *attachment;
  int32_t attachment_len;
} mz_event;

typedef struct mz_node {
  mz_event event;
  struct mz_node *next;
} mz_node;

typedef struct {
  int used;
  z_owned_session_t session;
  z_owned_mutex_t lock;
  mz_node *head, *tail;
  int32_t queued;
  z_owned_subscriber_t subs[MZ_MAX_SUBS];
  ze_owned_advanced_subscriber_t adv_subs[MZ_MAX_SUBS];
  int sub_used[MZ_MAX_SUBS];  // 1: plain or liveliness subscriber, 2: advanced subscriber
  z_owned_liveliness_token_t tokens[MZ_MAX_TOKENS];
  int token_used[MZ_MAX_TOKENS];
  int32_t next_query;
} mz_session;

typedef struct {
  mz_session *s;
  int32_t id;
  int liveliness;
} mz_ctx;

static mz_session sessions[MZ_MAX_SESSIONS];
MZ_EXPORT void mz_unsubscribe(int32_t h, int32_t id);
static char last_error[256];

static void set_error(const char *what, int code) {
  snprintf(last_error, sizeof last_error, "%s (zenoh error %d)", what, code);
}

MZ_EXPORT const char *mz_error(void) { return last_error; }

// ------------------------------------------------------------------------------------------ queue

static uint8_t *copy_bytes(const z_loaned_bytes_t *bytes, int32_t *len) {
  *len = 0;
  if (bytes == NULL) return NULL;
  z_owned_slice_t slice;
  if (z_bytes_to_slice(bytes, &slice) != Z_OK) return NULL;
  size_t n = z_slice_len(z_loan(slice));
  uint8_t *out = (uint8_t *)malloc(n > 0 ? n : 1);
  if (out != NULL) {
    if (n > 0) memcpy(out, z_slice_data(z_loan(slice)), n);
    *len = (int32_t)n;
  }
  z_drop(z_move(slice));
  return out;
}

static char *copy_key(const z_loaned_keyexpr_t *ke) {
  z_view_string_t view;
  if (z_keyexpr_as_view_string(ke, &view) != Z_OK) return NULL;
  size_t n = z_string_len(z_loan(view));
  char *out = (char *)malloc(n + 1);
  if (out == NULL) return NULL;
  memcpy(out, z_string_data(z_loan(view)), n);
  out[n] = '\0';
  return out;
}

static void free_event(mz_event *e) {
  free(e->key);
  free(e->payload);
  free(e->attachment);
  memset(e, 0, sizeof *e);
}

static void push(mz_session *s, mz_event e) {
  mz_node *node = (mz_node *)calloc(1, sizeof(mz_node));
  if (node == NULL) {
    free_event(&e);
    return;
  }
  node->event = e;
  z_mutex_lock(z_loan_mut(s->lock));
  if (s->tail != NULL) s->tail->next = node; else s->head = node;
  s->tail = node;
  s->queued++;
  while (s->queued > MZ_MAX_QUEUE && s->head != NULL) {  // nobody is polling: drop the oldest
    mz_node *old = s->head;
    s->head = old->next;
    if (s->head == NULL) s->tail = NULL;
    s->queued--;
    free_event(&old->event);
    free(old);
  }
  z_mutex_unlock(z_loan_mut(s->lock));
}

static void push_sample(mz_ctx *c, int32_t kind, const z_loaned_sample_t *sample) {
  mz_event e;
  memset(&e, 0, sizeof e);
  e.kind = kind;
  e.id = c->id;
  e.key = copy_key(z_sample_keyexpr(sample));
  if (kind == MZ_SAMPLE || kind == MZ_REPLY) {
    e.payload = copy_bytes(z_sample_payload(sample), &e.payload_len);
    e.attachment = copy_bytes(z_sample_attachment(sample), &e.attachment_len);
  }
  push(c->s, e);
}

// ------------------------------------------------------------------------------------------ callbacks

static void on_sample(z_loaned_sample_t *sample, void *arg) {
  mz_ctx *c = (mz_ctx *)arg;
  if (c->liveliness) {
    push_sample(c, z_sample_kind(sample) == Z_SAMPLE_KIND_DELETE ? MZ_GONE : MZ_ALIVE, sample);
  } else {
    push_sample(c, MZ_SAMPLE, sample);
  }
}

static void on_reply(z_loaned_reply_t *reply, void *arg) {
  mz_ctx *c = (mz_ctx *)arg;
  if (z_reply_is_ok(reply)) {
    push_sample(c, c->liveliness ? MZ_ALIVE : MZ_REPLY, z_reply_ok(reply));
  } else {
    mz_event e;
    memset(&e, 0, sizeof e);
    e.kind = MZ_REPLY_ERROR;
    e.id = c->id;
    e.payload = copy_bytes(z_reply_err_payload(z_reply_err(reply)), &e.payload_len);
    push(c->s, e);
  }
}

static void on_query_done(void *arg) {
  mz_ctx *c = (mz_ctx *)arg;
  mz_event e;
  memset(&e, 0, sizeof e);
  e.kind = MZ_QUERY_DONE;
  e.id = c->id;
  push(c->s, e);
  free(c);
}

static void free_ctx(void *arg) { free(arg); }

// ------------------------------------------------------------------------------------------ API

static mz_session *get(int32_t h) {
  if (h < 0 || h >= MZ_MAX_SESSIONS || !sessions[h].used) return NULL;
  return &sessions[h];
}

// Opens a session. [connect] is a locator such as "tcp/192.168.0.10:7447" (the robot's Zenoh router);
// [mode] "client" (through the router) or "peer". Returns a session handle, or -1 (see mz_error).
MZ_EXPORT int32_t mz_open(const char *connect, const char *mode) {
  int32_t h = -1;
  for (int32_t i = 0; i < MZ_MAX_SESSIONS; i++) {
    if (!sessions[i].used) { h = i; break; }
  }
  if (h < 0) { set_error("too many sessions", -1); return -1; }
  mz_session *s = &sessions[h];
  memset(s, 0, sizeof *s);
  z_owned_config_t config;
  z_config_default(&config);
  zp_config_insert(z_loan_mut(config), Z_CONFIG_MODE_KEY, mode != NULL && *mode ? mode : "client");
  if (connect != NULL && *connect) zp_config_insert(z_loan_mut(config), Z_CONFIG_CONNECT_KEY, connect);
  z_result_t r = z_open(&s->session, z_move(config), NULL);
  if (r < 0) { set_error("could not reach the Zenoh router", r); return -1; }
  if ((r = zp_start_read_task(z_loan_mut(s->session), NULL)) < 0 ||
      (r = zp_start_lease_task(z_loan_mut(s->session), NULL)) < 0) {
    set_error("could not start the session tasks", r);
    z_drop(z_move(s->session));
    return -1;
  }
  z_mutex_init(&s->lock);
  s->used = 1;
  return h;
}

MZ_EXPORT void mz_close(int32_t h) {
  mz_session *s = get(h);
  if (s == NULL) return;
  for (int i = 0; i < MZ_MAX_SUBS; i++) mz_unsubscribe(h, i);
  for (int i = 0; i < MZ_MAX_TOKENS; i++) {
    if (s->token_used[i]) { z_drop(z_move(s->tokens[i])); s->token_used[i] = 0; }
  }
  z_close(z_loan_mut(s->session), NULL);
  z_drop(z_move(s->session));
  z_mutex_lock(z_loan_mut(s->lock));
  while (s->head != NULL) {
    mz_node *n = s->head;
    s->head = n->next;
    free_event(&n->event);
    free(n);
  }
  s->tail = NULL;
  s->queued = 0;
  z_mutex_unlock(z_loan_mut(s->lock));
  z_drop(z_move(s->lock));
  s->used = 0;
}

// The session's Zenoh id as text (as rmw_zenoh writes it in liveliness tokens). Returns its length.
MZ_EXPORT int32_t mz_zid(int32_t h, char *out, int32_t cap) {
  mz_session *s = get(h);
  if (s == NULL || cap <= 0) return 0;
  z_id_t id = z_info_zid(z_loan(s->session));
  z_owned_string_t text;
  if (z_id_to_string(&id, &text) != Z_OK) return 0;
  int32_t n = (int32_t)z_string_len(z_loan(text));
  if (n >= cap) n = cap - 1;
  memcpy(out, z_string_data(z_loan(text)), (size_t)n);
  out[n] = '\0';
  z_drop(z_move(text));
  return n;
}

// Subscribes to [keyexpr]: data samples, or with [liveliness] token appear/disappear events. [history]
// also delivers what already exists: the existing tokens, or for data the samples kept by publishers
// with history (rmw_zenoh's transient-local publishers, e.g. a latched /map), through an advanced
// subscriber. Returns a subscription id, or -1.
MZ_EXPORT int32_t mz_subscribe(int32_t h, const char *keyexpr, int32_t liveliness, int32_t history) {
  mz_session *s = get(h);
  if (s == NULL) { set_error("no such session", -1); return -1; }
  int32_t id = -1;
  for (int32_t i = 0; i < MZ_MAX_SUBS; i++) {
    if (!s->sub_used[i]) { id = i; break; }
  }
  if (id < 0) { set_error("too many subscriptions", -1); return -1; }
  z_view_keyexpr_t ke;
  z_result_t r = z_view_keyexpr_from_str(&ke, keyexpr);
  if (r < 0) { set_error("invalid key expression", r); return -1; }
  mz_ctx *c = (mz_ctx *)calloc(1, sizeof(mz_ctx));
  if (c == NULL) { set_error("out of memory", -1); return -1; }
  c->s = s;
  c->id = id;
  c->liveliness = liveliness;
  z_owned_closure_sample_t cb;
  z_closure(&cb, on_sample, free_ctx, c);
  int kind = 1;
  if (liveliness) {
    z_liveliness_subscriber_options_t opts;
    z_liveliness_subscriber_options_default(&opts);
    opts.history = history != 0;
    r = z_liveliness_declare_subscriber(z_loan(s->session), &s->subs[id], z_loan(ke), z_move(cb), &opts);
  } else if (history) {
    ze_advanced_subscriber_options_t opts;
    ze_advanced_subscriber_options_default(&opts);
    opts.history.is_enabled = true;
    opts.history.detect_late_publishers = true;
    r = ze_declare_advanced_subscriber(z_loan(s->session), &s->adv_subs[id], z_loan(ke), z_move(cb), &opts);
    kind = 2;
  } else {
    r = z_declare_subscriber(z_loan(s->session), &s->subs[id], z_loan(ke), z_move(cb), NULL);
  }
  if (r < 0) { set_error("could not subscribe", r); return -1; }
  s->sub_used[id] = kind;
  return id;
}

MZ_EXPORT void mz_unsubscribe(int32_t h, int32_t id) {
  mz_session *s = get(h);
  if (s == NULL || id < 0 || id >= MZ_MAX_SUBS || !s->sub_used[id]) return;
  if (s->sub_used[id] == 2) {
    ze_undeclare_advanced_subscriber(z_move(s->adv_subs[id]));
  } else {
    z_drop(z_move(s->subs[id]));
  }
  s->sub_used[id] = 0;
}

static z_result_t to_bytes(z_owned_bytes_t *out, const uint8_t *data, int32_t len) {
  if (data == NULL || len <= 0) return z_bytes_empty(out), Z_OK;
  return z_bytes_copy_from_buf(out, data, (size_t)len);
}

// Publishes [payload] on [key] with an optional [attachment]. Returns 0 or a negative error.
MZ_EXPORT int32_t mz_put(int32_t h, const char *key, const uint8_t *payload, int32_t len,
                         const uint8_t *attachment, int32_t attachment_len) {
  mz_session *s = get(h);
  if (s == NULL) { set_error("no such session", -1); return -1; }
  z_view_keyexpr_t ke;
  z_result_t r = z_view_keyexpr_from_str(&ke, key);
  if (r < 0) { set_error("invalid key expression", r); return r; }
  z_owned_bytes_t body, att;
  if ((r = to_bytes(&body, payload, len)) < 0) { set_error("out of memory", r); return r; }
  z_put_options_t opts;
  z_put_options_default(&opts);
  if (attachment != NULL && attachment_len > 0) {
    if ((r = to_bytes(&att, attachment, attachment_len)) < 0) {
      z_drop(z_move(body));
      set_error("out of memory", r);
      return r;
    }
    opts.attachment = z_move(att);
  }
  r = z_put(z_loan(s->session), z_loan(ke), z_move(body), &opts);
  if (r < 0) set_error("could not publish", r);
  return r;
}

// Sends a query on [key] (a service request, or with [liveliness] a lookup of existing tokens). Replies
// arrive as MZ_REPLY / MZ_REPLY_ERROR (or MZ_ALIVE) events and end with MZ_QUERY_DONE, all carrying the
// returned query id. Returns that id, or -1.
MZ_EXPORT int32_t mz_query(int32_t h, const char *key, const uint8_t *payload, int32_t len,
                           const uint8_t *attachment, int32_t attachment_len, int32_t timeout_ms,
                           int32_t liveliness) {
  mz_session *s = get(h);
  if (s == NULL) { set_error("no such session", -1); return -1; }
  z_view_keyexpr_t ke;
  z_result_t r = z_view_keyexpr_from_str(&ke, key);
  if (r < 0) { set_error("invalid key expression", r); return -1; }
  mz_ctx *c = (mz_ctx *)calloc(1, sizeof(mz_ctx));
  if (c == NULL) { set_error("out of memory", -1); return -1; }
  c->s = s;
  c->liveliness = liveliness;
  z_mutex_lock(z_loan_mut(s->lock));
  c->id = s->next_query++;
  z_mutex_unlock(z_loan_mut(s->lock));
  int32_t id = c->id;
  z_owned_closure_reply_t cb;
  z_closure(&cb, on_reply, on_query_done, c);
  if (liveliness) {
    z_liveliness_get_options_t opts;
    z_liveliness_get_options_default(&opts);
    if (timeout_ms > 0) opts.timeout_ms = (uint64_t)timeout_ms;
    r = z_liveliness_get(z_loan(s->session), z_loan(ke), z_move(cb), &opts);
  } else {
    z_get_options_t opts;
    z_get_options_default(&opts);
    if (timeout_ms > 0) opts.timeout_ms = (uint64_t)timeout_ms;
    z_owned_bytes_t body, att;
    if (payload != NULL && len > 0 && to_bytes(&body, payload, len) == Z_OK) opts.payload = z_move(body);
    if (attachment != NULL && attachment_len > 0 && to_bytes(&att, attachment, attachment_len) == Z_OK) {
      opts.attachment = z_move(att);
    }
    r = z_get(z_loan(s->session), z_loan(ke), "", z_move(cb), &opts);
  }
  if (r < 0) { set_error("could not send the query", r); return -1; }  // the closure (and ctx) is dropped
  return id;
}

// Declares a liveliness token (announces this app in the ROS graph). Returns a token id, or -1.
MZ_EXPORT int32_t mz_token(int32_t h, const char *key) {
  mz_session *s = get(h);
  if (s == NULL) { set_error("no such session", -1); return -1; }
  int32_t id = -1;
  for (int32_t i = 0; i < MZ_MAX_TOKENS; i++) {
    if (!s->token_used[i]) { id = i; break; }
  }
  if (id < 0) { set_error("too many tokens", -1); return -1; }
  z_view_keyexpr_t ke;
  z_result_t r = z_view_keyexpr_from_str(&ke, key);
  if (r < 0) { set_error("invalid key expression", r); return -1; }
  r = z_liveliness_declare_token(z_loan(s->session), &s->tokens[id], z_loan(ke), NULL);
  if (r < 0) { set_error("could not declare the token", r); return -1; }
  s->token_used[id] = 1;
  return id;
}

MZ_EXPORT void mz_untoken(int32_t h, int32_t id) {
  mz_session *s = get(h);
  if (s == NULL || id < 0 || id >= MZ_MAX_TOKENS || !s->token_used[id]) return;
  z_drop(z_move(s->tokens[id]));
  s->token_used[id] = 0;
}

// Takes the oldest queued event into [out] (1) or reports none (0). Release it with mz_event_free.
MZ_EXPORT int32_t mz_poll(int32_t h, mz_event *out) {
  mz_session *s = get(h);
  if (s == NULL || out == NULL) return 0;
  z_mutex_lock(z_loan_mut(s->lock));
  mz_node *n = s->head;
  if (n != NULL) {
    s->head = n->next;
    if (s->head == NULL) s->tail = NULL;
    s->queued--;
  }
  z_mutex_unlock(z_loan_mut(s->lock));
  if (n == NULL) return 0;
  *out = n->event;
  free(n);
  return 1;
}

MZ_EXPORT void mz_event_free(mz_event *e) {
  if (e != NULL) free_event(e);
}
