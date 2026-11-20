/* Mobile ROS direct connection: a thin C layer over Cyclone DDS that lets Dart talk to ROS 2 without
 * rosbridge. DDS only sees opaque, already-serialized samples (a "raw CDR" type, the same trick the ROS 2
 * Cyclone RMW uses), so any ROS message works as long as Dart knows how to (de)serialize it.
 *
 * Every function returns a negative DDS return code on failure. Samples passed in and out include the
 * 4-byte CDR encapsulation header. Buffers returned through `out` must be released with mr_free.
 */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "dds/dds.h"
#include "dds/ddsi/ddsi_serdata.h"
#include "dds/ddsi/ddsi_sertype.h"
#include "dds/ddsi/q_radmin.h"
#include "dds/ddsrt/heap.h"
#include "dds/ddsrt/md5.h"

#if defined(_WIN32)
#define MR_EXPORT __declspec(dllexport)
#else
#define MR_EXPORT __attribute__((visibility("default")))
#endif

/* ---------- raw CDR sertype / serdata ---------- */

struct raw_serdata {
  struct ddsi_serdata c;
  uint32_t size;
  unsigned char data[]; /* encapsulation header + payload */
};

static const struct ddsi_serdata_ops raw_serdata_ops;

static struct raw_serdata *raw_new (const struct ddsi_sertype *type, enum ddsi_serdata_kind kind, size_t size)
{
  struct raw_serdata *d = ddsrt_malloc (sizeof (*d) + size);
  ddsi_serdata_init (&d->c, type, kind);
  d->c.hash = type->serdata_basehash;
  d->size = (uint32_t) size;
  return d;
}

static bool raw_eqkey (const struct ddsi_serdata *a, const struct ddsi_serdata *b) { (void) a; (void) b; return true; }
static uint32_t raw_get_size (const struct ddsi_serdata *d) { return ((const struct raw_serdata *) d)->size; }
static void raw_free (struct ddsi_serdata *d) { ddsrt_free (d); }

static struct ddsi_serdata *raw_from_ser (const struct ddsi_sertype *type, enum ddsi_serdata_kind kind, const struct nn_rdata *fragchain, size_t size)
{
  struct raw_serdata *d = raw_new (type, kind, size);
  uint32_t off = 0;
  while (fragchain) {
    if (fragchain->maxp1 > off) {
      const unsigned char *payload = NN_RMSG_PAYLOADOFF (fragchain->rmsg, NN_RDATA_PAYLOAD_OFF (fragchain));
      memcpy (d->data + off, payload + off - fragchain->min, fragchain->maxp1 - off);
      off = fragchain->maxp1;
    }
    fragchain = fragchain->nextfrag;
  }
  return &d->c;
}

static struct ddsi_serdata *raw_from_ser_iov (const struct ddsi_sertype *type, enum ddsi_serdata_kind kind, ddsrt_msg_iovlen_t niov, const ddsrt_iovec_t *iov, size_t size)
{
  struct raw_serdata *d = raw_new (type, kind, size);
  size_t off = 0;
  for (ddsrt_msg_iovlen_t i = 0; i < niov && off < size; i++) {
    size_t n = iov[i].iov_len < size - off ? iov[i].iov_len : size - off;
    memcpy (d->data + off, iov[i].iov_base, n);
    off += n;
  }
  return &d->c;
}

static struct ddsi_serdata *raw_from_keyhash (const struct ddsi_sertype *type, const struct ddsi_keyhash *keyhash)
{
  /* Keyless: a key-only sample is just the encapsulation header. */
  (void) keyhash;
  struct raw_serdata *d = raw_new (type, SDK_KEY, 4);
  memcpy (d->data, (unsigned char[]) { 0, 1, 0, 0 }, 4);
  return &d->c;
}

/* A "sample" for this type is { const uint8_t *data; uint32_t size; } (see mr_write). */
struct raw_sample { const unsigned char *data; uint32_t size; };

static struct ddsi_serdata *raw_from_sample (const struct ddsi_sertype *type, enum ddsi_serdata_kind kind, const void *sample)
{
  const struct raw_sample *s = sample;
  if (kind == SDK_KEY) return raw_from_keyhash (type, NULL);
  struct raw_serdata *d = raw_new (type, kind, s->size);
  memcpy (d->data, s->data, s->size);
  return &d->c;
}

static void raw_to_ser (const struct ddsi_serdata *d, size_t off, size_t sz, void *buf)
{
  memcpy (buf, ((const struct raw_serdata *) d)->data + off, sz);
}

static struct ddsi_serdata *raw_to_ser_ref (const struct ddsi_serdata *d, size_t off, size_t sz, ddsrt_iovec_t *ref)
{
  ref->iov_base = (void *) (((const struct raw_serdata *) d)->data + off);
  ref->iov_len = (ddsrt_iov_len_t) sz;
  return ddsi_serdata_ref (d);
}

static void raw_to_ser_unref (struct ddsi_serdata *d, const ddsrt_iovec_t *ref)
{
  (void) ref;
  ddsi_serdata_unref (d);
}

static bool raw_to_sample (const struct ddsi_serdata *d, void *sample, void **bufptr, void *buflim)
{
  (void) bufptr; (void) buflim;
  struct raw_sample *s = sample;
  s->data = ((const struct raw_serdata *) d)->data;
  s->size = ((const struct raw_serdata *) d)->size;
  return true;
}

static struct ddsi_serdata *raw_to_untyped (const struct ddsi_serdata *d)
{
  /* Keyless, so the untyped (key-only) form carries no information besides the type. */
  struct raw_serdata *u = raw_new (d->type, SDK_KEY, 4);
  memcpy (u->data, (unsigned char[]) { 0, 1, 0, 0 }, 4);
  u->c.type = NULL;
  return &u->c;
}

static bool raw_untyped_to_sample (const struct ddsi_sertype *type, const struct ddsi_serdata *d, void *sample, void **bufptr, void *buflim)
{
  (void) type; (void) d; (void) bufptr; (void) buflim;
  struct raw_sample *s = sample;
  s->data = NULL;
  s->size = 0;
  return true;
}

static size_t raw_print (const struct ddsi_sertype *type, const struct ddsi_serdata *d, char *buf, size_t size)
{
  (void) type;
  return (size_t) snprintf (buf, size, "(raw %u bytes)", ((const struct raw_serdata *) d)->size);
}

static void raw_get_keyhash (const struct ddsi_serdata *d, struct ddsi_keyhash *buf, bool force_md5)
{
  (void) d; (void) force_md5;
  memset (buf, 0, sizeof (*buf));
}

static const struct ddsi_serdata_ops raw_serdata_ops = {
  .eqkey = raw_eqkey,
  .get_size = raw_get_size,
  .from_ser = raw_from_ser,
  .from_ser_iov = raw_from_ser_iov,
  .from_keyhash = raw_from_keyhash,
  .from_sample = raw_from_sample,
  .to_ser = raw_to_ser,
  .to_ser_ref = raw_to_ser_ref,
  .to_ser_unref = raw_to_ser_unref,
  .to_sample = raw_to_sample,
  .to_untyped = raw_to_untyped,
  .untyped_to_sample = raw_untyped_to_sample,
  .free = raw_free,
  .print = raw_print,
  .get_keyhash = raw_get_keyhash,
};

static void raw_type_free (struct ddsi_sertype *tp) { ddsi_sertype_fini (tp); ddsrt_free (tp); }
static void raw_zero_samples (const struct ddsi_sertype *d, void *samples, size_t count) { (void) d; memset (samples, 0, count * sizeof (struct raw_sample)); }
static void raw_realloc_samples (void **ptrs, const struct ddsi_sertype *d, void *old, size_t oldcount, size_t count)
{
  (void) d;
  struct raw_sample *s = ddsrt_realloc (old, count * sizeof (*s));
  if (count > oldcount) memset (s + oldcount, 0, (count - oldcount) * sizeof (*s));
  for (size_t i = 0; i < count; i++) ptrs[i] = &s[i];
}
static void raw_free_samples (const struct ddsi_sertype *d, void **ptrs, size_t count, dds_free_op_t op)
{
  (void) d; (void) count;
  if ((op & DDS_FREE_ALL_BIT) && ptrs[0]) ddsrt_free (ptrs[0]);
}
static bool raw_type_equal (const struct ddsi_sertype *a, const struct ddsi_sertype *b) { (void) a; (void) b; return true; }
static uint32_t raw_type_hash (const struct ddsi_sertype *tp) { (void) tp; return 0x6d726f73; }
static size_t raw_serialized_size (const struct ddsi_sertype *d, const void *sample) { (void) d; return ((const struct raw_sample *) sample)->size; }
static bool raw_serialize_into (const struct ddsi_sertype *d, const void *sample, void *dst, size_t dst_size)
{
  (void) d;
  const struct raw_sample *s = sample;
  if (dst_size < s->size) return false;
  memcpy (dst, s->data, s->size);
  return true;
}

static const struct ddsi_sertype_ops raw_sertype_ops = {
  .version = ddsi_sertype_v0,
  .arg = NULL,
  .free = raw_type_free,
  .zero_samples = raw_zero_samples,
  .realloc_samples = raw_realloc_samples,
  .free_samples = raw_free_samples,
  .equal = raw_type_equal,
  .hash = raw_type_hash,
  .get_serialized_size = raw_serialized_size,
  .serialize_into = raw_serialize_into,
};

static struct ddsi_sertype *raw_sertype_new (const char *type_name)
{
  struct ddsi_sertype *st = ddsrt_malloc (sizeof (*st));
  ddsi_sertype_init_flags (st, type_name, &raw_sertype_ops, &raw_serdata_ops, DDSI_SERTYPE_FLAG_TOPICKIND_NO_KEY);
  st->allowed_data_representation = DDS_DATA_REPRESENTATION_FLAG_XCDR1;
  return st;
}

/* ---------- participant ---------- */

static void forget_topics (int32_t pp);

struct graph { dds_entity_t participants, publications, subscriptions; };
#define MAX_PARTICIPANTS 8
static struct { dds_entity_t pp; struct graph g; } open_participants[MAX_PARTICIPANTS];

static struct graph *graph_of (dds_entity_t pp)
{
  for (int i = 0; i < MAX_PARTICIPANTS; i++)
    if (open_participants[i].pp == pp) return &open_participants[i].g;
  return NULL;
}

/* Joins `domain`. `config` is Cyclone XML (may be NULL/empty for defaults). Returns the participant. */
MR_EXPORT int32_t mr_open (uint32_t domain, const char *config)
{
  int slot = -1;
  for (int i = 0; i < MAX_PARTICIPANTS && slot < 0; i++)
    if (open_participants[i].pp == 0) slot = i;
  if (slot < 0) return DDS_RETCODE_OUT_OF_RESOURCES;
  if (config && *config) {
    dds_entity_t dom = dds_create_domain ((dds_domainid_t) domain, config);
    /* PRECONDITION_NOT_MET: the domain already exists (e.g. a second participant); reuse it. */
    if (dom < 0 && dom != DDS_RETCODE_PRECONDITION_NOT_MET) return dom;
  }
  dds_qos_t *qos = dds_create_qos ();
  /* ROS 2 nodes identify their security enclave in USER_DATA; mirror what the RMW sends. */
  static const char enclave[] = "enclave=/;";
  dds_qset_userdata (qos, enclave, sizeof (enclave) - 1);
  dds_entity_t pp = dds_create_participant ((dds_domainid_t) domain, qos, NULL);
  dds_delete_qos (qos);
  if (pp < 0) return pp;
  struct graph g = {
    dds_create_reader (pp, DDS_BUILTIN_TOPIC_DCPSPARTICIPANT, NULL, NULL),
    dds_create_reader (pp, DDS_BUILTIN_TOPIC_DCPSPUBLICATION, NULL, NULL),
    dds_create_reader (pp, DDS_BUILTIN_TOPIC_DCPSSUBSCRIPTION, NULL, NULL),
  };
  open_participants[slot].pp = pp;
  open_participants[slot].g = g;
  return pp;
}

/* Deletes the participant (and everything created under it). */
MR_EXPORT int32_t mr_close (int32_t pp)
{
  forget_topics (pp);
  for (int i = 0; i < MAX_PARTICIPANTS; i++)
    if (open_participants[i].pp == pp) open_participants[i].pp = 0;
  return dds_delete (pp);
}

/* GUID of an entity (16 bytes). */
MR_EXPORT int32_t mr_guid (int32_t entity, uint8_t *out16)
{
  dds_guid_t g;
  dds_return_t rc = dds_get_guid (entity, &g);
  if (rc == 0) memcpy (out16, g.v, 16);
  return rc;
}

/* ---------- readers / writers ---------- */

static dds_qos_t *make_qos (int32_t reliable, int32_t transient_local, int32_t depth)
{
  dds_qos_t *qos = dds_create_qos ();
  dds_qset_reliability (qos, reliable ? DDS_RELIABILITY_RELIABLE : DDS_RELIABILITY_BEST_EFFORT, DDS_SECS (1));
  dds_qset_durability (qos, transient_local ? DDS_DURABILITY_TRANSIENT_LOCAL : DDS_DURABILITY_VOLATILE);
  dds_qset_history (qos, DDS_HISTORY_KEEP_LAST, depth > 0 ? depth : 10);
  dds_data_representation_id_t xcdr1 = DDS_DATA_REPRESENTATION_XCDR1;
  dds_qset_data_representation (qos, 1, &xcdr1);
  return qos;
}

/* Topics are created once per (participant, name, type) and reused: creating a second topic entity
 * for a name whose readers were deleted left new readers without data. */
#define MAX_TOPICS 1024
static struct { dds_entity_t pp, topic; char *name, *type; } topics[MAX_TOPICS];
static int ntopics;

static dds_entity_t make_topic (int32_t pp, const char *topic, const char *type)
{
  for (int i = 0; i < ntopics; i++)
    if (topics[i].pp == pp && strcmp (topics[i].name, topic) == 0 && strcmp (topics[i].type, type) == 0)
      return topics[i].topic;
  struct ddsi_sertype *st = raw_sertype_new (type);
  dds_entity_t t = dds_create_topic_sertype (pp, topic, &st, NULL, NULL, NULL);
  if (t < 0) { raw_type_free (st); return t; }
  if (ntopics < MAX_TOPICS) {
    topics[ntopics].pp = pp;
    topics[ntopics].topic = t;
    topics[ntopics].name = strdup (topic);
    topics[ntopics].type = strdup (type);
    ntopics++;
  }
  return t;
}

static void forget_topics (int32_t pp)
{
  int j = 0;
  for (int i = 0; i < ntopics; i++) {
    if (topics[i].pp == pp) { free (topics[i].name); free (topics[i].type); }
    else topics[j++] = topics[i];
  }
  ntopics = j;
}

/* DDS topic name (e.g. "rt/odom") and type name (e.g. "nav_msgs::msg::dds_::Odometry_"). */
MR_EXPORT int32_t mr_reader (int32_t pp, const char *topic, const char *type, int32_t reliable, int32_t transient_local, int32_t depth)
{
  dds_entity_t t = make_topic (pp, topic, type);
  if (t < 0) return t;
  dds_qos_t *qos = make_qos (reliable, transient_local, depth);
  dds_entity_t r = dds_create_reader (pp, t, qos, NULL);
  dds_delete_qos (qos);
  return r;
}

MR_EXPORT int32_t mr_writer (int32_t pp, const char *topic, const char *type, int32_t reliable, int32_t transient_local, int32_t depth)
{
  dds_entity_t t = make_topic (pp, topic, type);
  if (t < 0) return t;
  dds_qos_t *qos = make_qos (reliable, transient_local, depth);
  dds_entity_t w = dds_create_writer (pp, t, qos, NULL);
  dds_delete_qos (qos);
  return w;
}

MR_EXPORT int32_t mr_delete (int32_t entity) { return dds_delete (entity); }

/* How many remote endpoints a reader or writer is currently matched with. */
MR_EXPORT int32_t mr_matched (int32_t entity)
{
  dds_publication_matched_status_t ps;
  dds_return_t rc = dds_get_publication_matched_status (entity, &ps);
  if (rc == 0) return (int32_t) ps.current_count;
  dds_subscription_matched_status_t ss;
  rc = dds_get_subscription_matched_status (entity, &ss);
  return rc == 0 ? (int32_t) ss.current_count : rc;
}

MR_EXPORT int32_t mr_write (int32_t writer, const uint8_t *data, uint32_t size)
{
  struct raw_sample s = { data, size };
  return dds_write (writer, &s);
}

/* Takes the next valid sample. Returns its size (and a malloc'd copy in *out, the writer's GUID in
 * writer16 if non-NULL, the source timestamp in ns), 0 if nothing is waiting, or a negative error. */
MR_EXPORT int32_t mr_take (int32_t reader, uint8_t **out, uint8_t *writer16, int64_t *timestamp)
{
  for (;;) {
    struct ddsi_serdata *sd = NULL;
    dds_sample_info_t info;
    dds_return_t n = dds_takecdr (reader, &sd, 1, &info, DDS_ANY_STATE);
    if (n <= 0) return n;
    if (!info.valid_data) { ddsi_serdata_unref (sd); continue; }
    uint32_t size = ddsi_serdata_size (sd);
    uint8_t *buf = malloc (size ? size : 1);
    ddsi_serdata_to_ser (sd, 0, size, buf);
    ddsi_serdata_unref (sd);
    if (timestamp) *timestamp = info.source_timestamp;
    if (writer16) {
      /* The publication handle identifies the writer; resolve it to its GUID. */
      memset (writer16, 0, 16);
      dds_builtintopic_endpoint_t *ep = dds_get_matched_publication_data (reader, info.publication_handle);
      if (ep) { memcpy (writer16, ep->key.v, 16); dds_builtintopic_free_endpoint (ep); }
    }
    *out = buf;
    return (int32_t) size;
  }
}

MR_EXPORT void mr_free (void *p) { free (p); }

/* ---------- graph ---------- */

struct text { char *buf; size_t len, cap; };

static void text_add (struct text *t, const char *s)
{
  size_t n = strlen (s);
  if (t->len + n + 1 > t->cap) {
    t->cap = (t->len + n + 1) * 2;
    t->buf = realloc (t->buf, t->cap);
  }
  memcpy (t->buf + t->len, s, n + 1);
  t->len += n;
}

static void hex16 (char *dst, const unsigned char *v)
{
  static const char digits[] = "0123456789abcdef";
  for (int i = 0; i < 16; i++) { dst[2 * i] = digits[v[i] >> 4]; dst[2 * i + 1] = digits[v[i] & 15]; }
  dst[32] = 0;
}

/* Text snapshot of what is alive on the network, one record per line, tab separated:
 *   P <participant guid> <vendor hint: fastdds|other>
 *   W|R <endpoint guid> <participant guid> <topic> <type> <reliable 0/1> <transient_local 0/1>
 * Includes our own entities. */
MR_EXPORT int32_t mr_graph (int32_t pp, char **out)
{
  struct graph *g = graph_of (pp);
  if (!g) return DDS_RETCODE_BAD_PARAMETER;
  struct text t = { NULL, 0, 0 };
  text_add (&t, "");
  enum { MAXS = 8192 };
  void **samples = calloc (MAXS, sizeof (void *));
  dds_sample_info_t *infos = calloc (MAXS, sizeof (dds_sample_info_t));
  const uint32_t alive = DDS_ANY_SAMPLE_STATE | DDS_ANY_VIEW_STATE | DDS_ALIVE_INSTANCE_STATE;
  char line[1024], a[33], b[33];

  /* read (not take) so every snapshot is complete; only instances that are still alive */
  dds_return_t n = dds_read_mask (g->participants, samples, infos, MAXS, MAXS, alive);
  for (dds_return_t i = 0; i < n; i++) {
    if (!infos[i].valid_data) continue;
    const dds_builtintopic_participant_t *p = samples[i];
    uint32_t nprops = 0;
    char **names = NULL;
    bool fast = false;
    if (dds_qget_propnames (p->qos, &nprops, &names)) {
      for (uint32_t k = 0; k < nprops; k++) {
        if (strcmp (names[k], "PARTICIPANT_TYPE") == 0 || strncmp (names[k], "fastdds.", 8) == 0) fast = true;
        dds_free (names[k]);
      }
      dds_free (names);
    }
    hex16 (a, p->key.v);
    snprintf (line, sizeof (line), "P\t%s\t%s\n", a, fast ? "fastdds" : "other");
    text_add (&t, line);
  }
  if (n > 0) dds_return_loan (g->participants, samples, n);

  struct { dds_entity_t r; const char *kind; } eps[] = { { g->publications, "W" }, { g->subscriptions, "R" } };
  for (int e = 0; e < 2; e++) {
    memset (samples, 0, MAXS * sizeof (void *));
    n = dds_read_mask (eps[e].r, samples, infos, MAXS, MAXS, alive);
    for (dds_return_t i = 0; i < n; i++) {
      if (!infos[i].valid_data) continue;
      const dds_builtintopic_endpoint_t *ep = samples[i];
      dds_reliability_kind_t rel = DDS_RELIABILITY_BEST_EFFORT;
      dds_durability_kind_t dur = DDS_DURABILITY_VOLATILE;
      dds_qget_reliability (ep->qos, &rel, NULL);
      dds_qget_durability (ep->qos, &dur);
      hex16 (a, ep->key.v);
      hex16 (b, ep->participant_key.v);
      snprintf (line, sizeof (line), "%s\t%s\t%s\t%s\t%s\t%d\t%d\n", eps[e].kind, a, b, ep->topic_name, ep->type_name,
                rel == DDS_RELIABILITY_RELIABLE, dur != DDS_DURABILITY_VOLATILE);
      text_add (&t, line);
    }
    if (n > 0) dds_return_loan (eps[e].r, samples, n);
  }
  free (samples);
  free (infos);
  *out = t.buf;
  return (int32_t) t.len;
}

MR_EXPORT const char *mr_error_text (int32_t rc) { return dds_strretcode (rc); }
