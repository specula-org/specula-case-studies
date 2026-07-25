/**
 * spdm_tla_trace.c — TLA+ trace emission implementation.
 *
 * Placed by apply.sh into artifact/libspdm/unit_test/test_spdm_secured_message/
 * Compiled as part of the test_spdm_secured_message binary.
 *
 * Thread-safe (Category A: mutex around file write).
 * Timestamps via gettimeofday (milliseconds since epoch).
 */
#ifdef SPDM_TLA_TRACE_ENABLE

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdarg.h>
#include <sys/time.h>
#include <pthread.h>

#include "internal/spdm_tla_trace.h"
#include "internal/libspdm_secured_message_lib.h"

/* ------------------------------------------------------------------ */
/* Epoch context table                                                  */
/* ------------------------------------------------------------------ */

#define SPDM_TLA_MAX_CTXS 8

typedef struct {
    void       *smc;
    const char *role;             /* "requester" or "responder" */
    uint32_t    req_active;       /* epoch of active request-dir key */
    uint32_t    rsp_active;       /* epoch of active response-dir key */
    uint32_t    req_backup;       /* epoch saved at last create_update(REQUESTER) */
    uint32_t    rsp_backup;       /* epoch saved at last create_update(RESPONDER) */
} spdm_tla_ectx_t;

static spdm_tla_ectx_t g_ectx[SPDM_TLA_MAX_CTXS];
static int g_ectx_count = 0;

static spdm_tla_ectx_t *find_ectx(void *smc)
{
    for (int i = 0; i < g_ectx_count; i++) {
        if (g_ectx[i].smc == smc) return &g_ectx[i];
    }
    return NULL;
}

void spdm_tla_register_ctx(void *smc, const char *role)
{
    if (find_ectx(smc)) return;  /* already registered */
    if (g_ectx_count >= SPDM_TLA_MAX_CTXS) return;
    spdm_tla_ectx_t *e = &g_ectx[g_ectx_count++];
    e->smc        = smc;
    e->role       = role;
    e->req_active = 0;
    e->rsp_active = 0;
    e->req_backup = 0;
    e->rsp_backup = 0;
}

void spdm_tla_on_create_update(void *smc, int is_requester_action)
{
    spdm_tla_ectx_t *e = find_ectx(smc);
    if (!e) return;
    if (is_requester_action) {
        e->req_backup = e->req_active;
        e->req_active++;
    } else {
        e->rsp_backup = e->rsp_active;
        e->rsp_active++;
    }
}

void spdm_tla_on_activate_update(void *smc, int is_requester_action, int commit)
{
    spdm_tla_ectx_t *e = find_ectx(smc);
    if (!e) return;
    if (!commit) {
        /* rollback: restore previous epoch */
        if (is_requester_action) {
            e->req_active = e->req_backup;
        } else {
            e->rsp_active = e->rsp_backup;
        }
    }
    /* commit: active stays at new epoch, backup discarded (no state change needed here) */
}

uint32_t spdm_tla_epoch(void *smc, int is_req_dir)
{
    spdm_tla_ectx_t *e = find_ectx(smc);
    if (!e) return 0;
    return is_req_dir ? e->req_active : e->rsp_active;
}

uint32_t spdm_tla_backup_epoch(void *smc, int is_req_dir)
{
    spdm_tla_ectx_t *e = find_ectx(smc);
    if (!e) return 0;
    return is_req_dir ? e->req_backup : e->rsp_backup;
}

const char *spdm_tla_role(void *smc)
{
    spdm_tla_ectx_t *e = find_ectx(smc);
    if (!e) return "unknown";
    return e->role;
}

/* ------------------------------------------------------------------ */
/* Synthesized protocol state                                           */
/* ------------------------------------------------------------------ */

static const char *g_phase     = "Idle";
static bool        g_committed = false;

void spdm_tla_set_phase(const char *phase)    { g_phase = phase; }
const char *spdm_tla_get_phase(void)          { return g_phase; }
void spdm_tla_set_committed(bool val)         { g_committed = val; }
bool spdm_tla_get_committed(void)             { return g_committed; }

/* ------------------------------------------------------------------ */
/* File output                                                          */
/* ------------------------------------------------------------------ */

static FILE           *g_trace_fp  = NULL;
static pthread_mutex_t g_mutex     = PTHREAD_MUTEX_INITIALIZER;

void spdm_tla_init(const char *trace_file)
{
    if (g_trace_fp) fclose(g_trace_fp);
    g_trace_fp = fopen(trace_file, "w");
    /* Reset epoch state for each new trace */
    memset(g_ectx, 0, sizeof(g_ectx));
    g_ectx_count = 0;
    g_phase      = "Idle";
    g_committed  = false;
}

void spdm_tla_close(void)
{
    if (g_trace_fp) { fflush(g_trace_fp); fclose(g_trace_fp); g_trace_fp = NULL; }
}

uint64_t spdm_tla_now_ms(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (uint64_t)tv.tv_sec * 1000 + (uint64_t)tv.tv_usec / 1000;
}

void spdm_tla_emit(const char *json)
{
    if (!g_trace_fp) return;
    pthread_mutex_lock(&g_mutex);
    fputs(json, g_trace_fp);
    fputc('\n', g_trace_fp);
    fflush(g_trace_fp);
    pthread_mutex_unlock(&g_mutex);
}

/* ------------------------------------------------------------------ */
/* Helpers                                                              */
/* ------------------------------------------------------------------ */

/* Get seq AFTER increment for the given direction from the smc struct */
static uint64_t get_seq(void *smc, int is_request)
{
    libspdm_secured_message_context_t *ctx = smc;
    if (ctx->session_state != LIBSPDM_SESSION_STATE_ESTABLISHED) return 0;
    return is_request
        ? ctx->application_secret.request_data_sequence_number
        : ctx->application_secret.response_data_sequence_number;
}

static uint64_t get_backup_seq(void *smc, int is_request)
{
    libspdm_secured_message_context_t *ctx = smc;
    return is_request
        ? ctx->application_secret_backup.request_data_sequence_number
        : ctx->application_secret_backup.response_data_sequence_number;
}

static bool get_backup_valid(void *smc, int is_request)
{
    libspdm_secured_message_context_t *ctx = smc;
    return is_request ? ctx->requester_backup_valid : ctx->responder_backup_valid;
}

/* Build the "state" JSON fragment.
 * always_update_phase: if true, include update_phase / initiator_committed */
static void build_state_json(char *buf, size_t bufsz, void *smc, int is_request,
                             bool include_phase)
{
    uint32_t ae   = spdm_tla_epoch(smc, is_request);
    bool     bv   = get_backup_valid(smc, is_request);
    uint64_t seq  = get_seq(smc, is_request);
    char phase_part[128] = "";
    if (include_phase) {
        snprintf(phase_part, sizeof(phase_part),
                 ",\"update_phase\":\"%s\",\"initiator_committed\":%s",
                 spdm_tla_get_phase(),
                 spdm_tla_get_committed() ? "true" : "false");
    }
    if (bv) {
        uint32_t be  = spdm_tla_backup_epoch(smc, is_request);
        uint64_t bsq = get_backup_seq(smc, is_request);
        snprintf(buf, bufsz,
                 "{\"seq\":%llu,\"active_epoch\":%u,\"backup_valid\":true,"
                 "\"backup_epoch\":%u,\"backup_seq\":%llu%s}",
                 (unsigned long long)seq, ae, be,
                 (unsigned long long)bsq, phase_part);
    } else {
        snprintf(buf, bufsz,
                 "{\"seq\":%llu,\"active_epoch\":%u,\"backup_valid\":false%s}",
                 (unsigned long long)seq, ae, phase_part);
    }
}

/* ------------------------------------------------------------------ */
/* Encode / Decode event emitters                                       */
/* ------------------------------------------------------------------ */

void spdm_tla_emit_encode_advance_seq(void *smc, int is_request, uint64_t seq)
{
    char state[256], buf[512];
    build_state_json(state, sizeof(state), smc, is_request, false);
    snprintf(buf, sizeof(buf),
             "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"encode_advance_seq\","
             "\"node\":\"%s\",\"dir\":\"%s\","
             "\"state\":%s,"
             "\"msg\":{\"epoch\":%u,\"seq\":%llu}}",
             (unsigned long long)spdm_tla_now_ms(),
             spdm_tla_role(smc),
             is_request ? "request" : "response",
             state,
             spdm_tla_epoch(smc, is_request),
             (unsigned long long)seq);
    spdm_tla_emit(buf);
}

void spdm_tla_emit_encode_success(void *smc, int is_request, uint64_t seq)
{
    char state[256], buf[512];
    build_state_json(state, sizeof(state), smc, is_request, false);
    snprintf(buf, sizeof(buf),
             "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"encode_success\","
             "\"node\":\"%s\",\"dir\":\"%s\","
             "\"state\":%s,"
             "\"msg\":{\"epoch\":%u,\"seq\":%llu,\"session_id_ok\":true,\"aead_ok\":true}}",
             (unsigned long long)spdm_tla_now_ms(),
             spdm_tla_role(smc),
             is_request ? "request" : "response",
             state,
             spdm_tla_epoch(smc, is_request),
             (unsigned long long)seq);
    spdm_tla_emit(buf);
}

/* For decode events, msg.seq must be the POST-increment value (seq_after) so it
 * matches the encoder's EncodeSuccess msg.seq and satisfies BagIn(m, msgs). */

void spdm_tla_emit_decode_increment_seq(void *smc, int is_request,
                                        uint64_t seq_after, uint64_t msg_seq)
{
    char state[256], buf[512];
    (void)msg_seq;  /* use seq_after to match encoder's post-increment msg.seq */
    build_state_json(state, sizeof(state), smc, is_request, false);
    snprintf(buf, sizeof(buf),
             "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"decode_increment_seq\","
             "\"node\":\"%s\",\"dir\":\"%s\","
             "\"state\":%s,"
             "\"msg\":{\"epoch\":%u,\"seq\":%llu,\"session_id_ok\":true,\"aead_ok\":true}}",
             (unsigned long long)spdm_tla_now_ms(),
             spdm_tla_role(smc),
             is_request ? "request" : "response",
             state,
             spdm_tla_epoch(smc, is_request),
             (unsigned long long)seq_after);
    spdm_tla_emit(buf);
}

void spdm_tla_emit_decode_success(void *smc, int is_request,
                                  uint64_t seq_after, uint64_t msg_seq)
{
    char state[256], buf[512];
    (void)msg_seq;
    build_state_json(state, sizeof(state), smc, is_request, false);
    snprintf(buf, sizeof(buf),
             "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"decode_success\","
             "\"node\":\"%s\",\"dir\":\"%s\","
             "\"state\":%s,"
             "\"msg\":{\"epoch\":%u,\"seq\":%llu,\"session_id_ok\":true,\"aead_ok\":true}}",
             (unsigned long long)spdm_tla_now_ms(),
             spdm_tla_role(smc),
             is_request ? "request" : "response",
             state,
             spdm_tla_epoch(smc, is_request),
             (unsigned long long)seq_after);
    spdm_tla_emit(buf);
}

void spdm_tla_emit_decode_session_id_fail(void *smc, int is_request,
                                          uint64_t seq_after, uint64_t msg_seq)
{
    char state[256], buf[512];
    (void)msg_seq;
    build_state_json(state, sizeof(state), smc, is_request, false);
    snprintf(buf, sizeof(buf),
             "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"decode_session_id_fail\","
             "\"node\":\"%s\",\"dir\":\"%s\","
             "\"state\":%s,"
             "\"msg\":{\"epoch\":%u,\"seq\":%llu,\"session_id_ok\":false,\"aead_ok\":false}}",
             (unsigned long long)spdm_tla_now_ms(),
             spdm_tla_role(smc),
             is_request ? "request" : "response",
             state,
             spdm_tla_epoch(smc, is_request),
             (unsigned long long)seq_after);
    spdm_tla_emit(buf);
}

void spdm_tla_emit_decode_aead_fail(void *smc, int is_request,
                                    uint64_t seq_after, uint64_t msg_seq)
{
    char state[256], buf[512];
    (void)msg_seq;
    build_state_json(state, sizeof(state), smc, is_request, false);
    snprintf(buf, sizeof(buf),
             "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"decode_aead_fail\","
             "\"node\":\"%s\",\"dir\":\"%s\","
             "\"state\":%s,"
             "\"msg\":{\"epoch\":%u,\"seq\":%llu,\"session_id_ok\":true,\"aead_ok\":false}}",
             (unsigned long long)spdm_tla_now_ms(),
             spdm_tla_role(smc),
             is_request ? "request" : "response",
             state,
             spdm_tla_epoch(smc, is_request),
             (unsigned long long)seq_after);
    spdm_tla_emit(buf);
}

void spdm_tla_emit_decode_aead_fail_backup(void *smc, int is_request,
                                           uint64_t seq_after, uint64_t msg_seq)
{
    char state[256], buf[512];
    (void)msg_seq;
    build_state_json(state, sizeof(state), smc, is_request, false);
    snprintf(buf, sizeof(buf),
             "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"decode_aead_fail_backup\","
             "\"node\":\"%s\",\"dir\":\"%s\","
             "\"state\":%s,"
             "\"msg\":{\"epoch\":%u,\"seq\":%llu,\"session_id_ok\":true,\"aead_ok\":false}}",
             (unsigned long long)spdm_tla_now_ms(),
             spdm_tla_role(smc),
             is_request ? "request" : "response",
             state,
             spdm_tla_epoch(smc, is_request),
             (unsigned long long)seq_after);
    spdm_tla_emit(buf);
}

/* ------------------------------------------------------------------ */
/* Key-update event emitters                                            */
/* ------------------------------------------------------------------ */

void spdm_tla_emit_create_update_responder_key(void *smc)
{
    /* Requester just called create_update(RESPONDER).
     * Captures: Requester / ResponseDir epoch state. */
    char buf[768];
    uint32_t ae  = spdm_tla_epoch(smc, 0 /* response dir */);
    uint32_t be  = spdm_tla_backup_epoch(smc, 0);
    libspdm_secured_message_context_t *ctx = smc;
    uint64_t seq  = ctx->application_secret.response_data_sequence_number;
    uint64_t bsq  = ctx->application_secret_backup.response_data_sequence_number;
    snprintf(buf, sizeof(buf),
             "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"create_update_responder_key\","
             "\"node\":\"requester\",\"dir\":\"response\","
             "\"state\":{\"seq\":%llu,\"active_epoch\":%u,\"backup_valid\":true,"
             "\"backup_epoch\":%u,\"backup_seq\":%llu}}",
             (unsigned long long)spdm_tla_now_ms(),
             (unsigned long long)seq, ae, be, (unsigned long long)bsq);
    spdm_tla_emit(buf);
}

void spdm_tla_emit_send_key_update_request(void *smc, bool all_keys, uint64_t seq)
{
    char buf[512];
    uint32_t ae = spdm_tla_epoch(smc, 1 /* request dir */);
    snprintf(buf, sizeof(buf),
             "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"send_key_update_request\","
             "\"node\":\"requester\",\"dir\":\"request\","
             "\"state\":{\"seq\":%llu,\"active_epoch\":%u,\"backup_valid\":false,"
             "\"update_phase\":\"PendingAck\",\"initiator_committed\":false},"
             "\"msg\":{\"epoch\":%u,\"seq\":%llu,\"all_keys\":%s}}",
             (unsigned long long)spdm_tla_now_ms(),
             (unsigned long long)seq, ae, ae, (unsigned long long)seq,
             all_keys ? "true" : "false");
    spdm_tla_emit(buf);
}

void spdm_tla_emit_responder_receive_key_update(void *smc, bool all_keys,
                                                uint64_t seq, uint32_t msg_epoch)
{
    char buf[768];
    libspdm_secured_message_context_t *ctx = smc;
    uint32_t req_ae = spdm_tla_epoch(smc, 1);
    uint32_t rsp_ae = spdm_tla_epoch(smc, 0);
    uint64_t req_seq = ctx->application_secret.request_data_sequence_number;
    snprintf(buf, sizeof(buf),
             "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"responder_receive_key_update\","
             "\"node\":\"responder\",\"dir\":\"request\","
             "\"state\":{\"seq\":%llu,\"active_epoch\":%u,\"backup_valid\":%s,"
             "\"rsp_active_epoch\":%u},"
             "\"msg\":{\"epoch\":%u,\"seq\":%llu,\"all_keys\":%s}}",
             (unsigned long long)spdm_tla_now_ms(),
             (unsigned long long)req_seq, req_ae,
             ctx->requester_backup_valid ? "true" : "false",
             rsp_ae,
             msg_epoch, (unsigned long long)seq,
             all_keys ? "true" : "false");
    spdm_tla_emit(buf);
}

void spdm_tla_emit_requester_receive_key_update_ack(void *smc, bool all_keys,
                                                    uint64_t seq, uint32_t msg_epoch)
{
    char buf[512];
    libspdm_secured_message_context_t *ctx = smc;
    uint32_t ae  = spdm_tla_epoch(smc, 1);
    uint64_t rsq = ctx->application_secret.request_data_sequence_number;
    snprintf(buf, sizeof(buf),
             "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"requester_receive_key_update_ack\","
             "\"node\":\"requester\",\"dir\":\"response\","
             "\"state\":{\"seq\":%llu,\"active_epoch\":%u,\"backup_valid\":false,"
             "\"update_phase\":\"PendingVerify\",\"initiator_committed\":true},"
             "\"msg\":{\"epoch\":%u,\"seq\":%llu,\"all_keys\":%s}}",
             (unsigned long long)spdm_tla_now_ms(),
             (unsigned long long)rsq, ae, msg_epoch, (unsigned long long)seq,
             all_keys ? "true" : "false");
    spdm_tla_emit(buf);
}

void spdm_tla_emit_responder_receive_verify_new_key(void *smc, uint64_t seq,
                                                    uint32_t msg_epoch)
{
    char buf[512];
    libspdm_secured_message_context_t *ctx = smc;
    uint32_t ae  = spdm_tla_epoch(smc, 1);
    uint64_t rsq = ctx->application_secret.request_data_sequence_number;
    snprintf(buf, sizeof(buf),
             "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"responder_receive_verify_new_key\","
             "\"node\":\"responder\",\"dir\":\"request\","
             "\"state\":{\"seq\":%llu,\"active_epoch\":%u,\"backup_valid\":false,"
             "\"update_phase\":\"Idle\"},"
             "\"msg\":{\"epoch\":%u,\"seq\":%llu}}",
             (unsigned long long)spdm_tla_now_ms(),
             (unsigned long long)rsq, ae, msg_epoch, (unsigned long long)seq);
    spdm_tla_emit(buf);
}

void spdm_tla_emit_responder_try_discard_key_update(void *smc, uint64_t seq,
                                                    uint32_t msg_epoch)
{
    char buf[512];
    libspdm_secured_message_context_t *ctx = smc;
    uint32_t ae  = spdm_tla_epoch(smc, 1);
    uint64_t rsq = ctx->application_secret.request_data_sequence_number;
    snprintf(buf, sizeof(buf),
             "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"responder_try_discard_key_update\","
             "\"node\":\"responder\",\"dir\":\"request\","
             "\"state\":{\"seq\":%llu,\"active_epoch\":%u,\"backup_valid\":false},"
             "\"msg\":{\"epoch\":%u,\"seq\":%llu}}",
             (unsigned long long)spdm_tla_now_ms(),
             (unsigned long long)rsq, ae, msg_epoch, (unsigned long long)seq);
    spdm_tla_emit(buf);
}

void spdm_tla_emit_requester_receive_verify_ack(void *smc, uint64_t seq,
                                                uint32_t msg_epoch)
{
    char buf[512];
    libspdm_secured_message_context_t *ctx = smc;
    uint64_t rsq = ctx->application_secret.response_data_sequence_number;
    snprintf(buf, sizeof(buf),
             "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"requester_receive_verify_ack\","
             "\"node\":\"requester\",\"dir\":\"response\","
             "\"state\":{\"seq\":%llu,\"active_epoch\":%u,\"backup_valid\":false,"
             "\"update_phase\":\"Idle\",\"initiator_committed\":false},"
             "\"msg\":{\"epoch\":%u,\"seq\":%llu}}",
             (unsigned long long)spdm_tla_now_ms(),
             (unsigned long long)rsq, spdm_tla_epoch(smc, 0),
             msg_epoch, (unsigned long long)seq);
    spdm_tla_emit(buf);
}

void spdm_tla_emit_encap_create_activate_rsp_key(void *smc)
{
    char buf[512];
    libspdm_secured_message_context_t *ctx = smc;
    uint32_t ae  = spdm_tla_epoch(smc, 0);
    uint64_t seq = ctx->application_secret.response_data_sequence_number;
    snprintf(buf, sizeof(buf),
             "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"encap_create_activate_rsp_key\","
             "\"node\":\"responder\",\"dir\":\"response\","
             "\"state\":{\"seq\":%llu,\"active_epoch\":%u,\"backup_valid\":false,"
             "\"update_phase\":\"PendingVerify\",\"initiator_committed\":true}}",
             (unsigned long long)spdm_tla_now_ms(),
             (unsigned long long)seq, ae);
    spdm_tla_emit(buf);
}

#endif /* SPDM_TLA_TRACE_ENABLE */
