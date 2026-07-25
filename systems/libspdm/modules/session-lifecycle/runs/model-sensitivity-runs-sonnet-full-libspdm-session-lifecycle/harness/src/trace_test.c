/*
 * TLA+ trace collection test for libspdm session lifecycle.
 *
 * Uses two SPDM contexts (req_ctx + rsp_ctx) with identical session secrets.
 * req_ctx.send_message routes each request through real rsp_ctx responder code,
 * so both sides' instrumentation fires and is captured in the trace.
 *
 * Three scenarios, each writing to a separate .ndjson file:
 *   trace_heartbeat        — 4× heartbeat + 1× key_update_single + end_session
 *   trace_key_update_single — 4× key_update (single_direction) + end_session
 *   trace_key_update_all    — 4× key_update (all_keys) + end_session
 */

#include "internal/libspdm_requester_lib.h"
#include "internal/libspdm_responder_lib.h"
#include "internal/libspdm_secured_message_lib.h"
#include "library/spdm_responder_lib.h"
#include "library/spdm_requester_lib.h"
#include "library/spdm_transport_test_lib.h"
#include "tla_trace.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <assert.h>

/* Provided by algo.c (linked in) */
extern uint32_t m_libspdm_use_hash_algo;
extern uint32_t m_libspdm_use_aead_algo;
extern uint32_t m_libspdm_use_asym_algo;
extern uint32_t m_libspdm_use_dhe_algo;

/* ── buffer sizing (mirrors spdm_unit_test.h) ─────────────────────────────── */
#ifndef LIBSPDM_SENDER_BUFFER_SIZE
#define LIBSPDM_SENDER_BUFFER_SIZE (0x1100 + LIBSPDM_TEST_TRANSPORT_HEADER_SIZE)
#endif
#ifndef LIBSPDM_RECEIVER_BUFFER_SIZE
#define LIBSPDM_RECEIVER_BUFFER_SIZE (0x1100 + LIBSPDM_TEST_TRANSPORT_HEADER_SIZE)
#endif
#if (LIBSPDM_SENDER_BUFFER_SIZE > LIBSPDM_RECEIVER_BUFFER_SIZE)
#define LIBSPDM_MAX_SENDER_RECEIVER_BUFFER_SIZE LIBSPDM_SENDER_BUFFER_SIZE
#else
#define LIBSPDM_MAX_SENDER_RECEIVER_BUFFER_SIZE LIBSPDM_RECEIVER_BUFFER_SIZE
#endif
#ifndef LIBSPDM_MAX_SPDM_MSG_SIZE
#define LIBSPDM_MAX_SPDM_MSG_SIZE 0x1200
#endif

/* ── global routing state (set before each scenario) ─────────────────────── */

static void *g_rsp_ctx;

static uint8_t g_rsp_response_buf[LIBSPDM_MAX_SENDER_RECEIVER_BUFFER_SIZE];
static size_t  g_rsp_response_size;
static void   *g_rsp_response_ptr;

/* ── req_ctx I/O buffers ──────────────────────────────────────────────────── */

static uint8_t g_req_sender_buf  [LIBSPDM_MAX_SENDER_RECEIVER_BUFFER_SIZE];
static uint8_t g_req_receiver_buf[LIBSPDM_MAX_SENDER_RECEIVER_BUFFER_SIZE];

/* ── req_ctx buffer callbacks ─────────────────────────────────────────────── */

static libspdm_return_t req_acquire_sender(void *ctx, void **buf) {
    memset(g_req_sender_buf, 0, sizeof(g_req_sender_buf));
    *buf = g_req_sender_buf;
    return LIBSPDM_STATUS_SUCCESS;
}
static void req_release_sender(void *ctx, const void *buf) {}

static libspdm_return_t req_acquire_receiver(void *ctx, void **buf) {
    memset(g_req_receiver_buf, 0, sizeof(g_req_receiver_buf));
    *buf = g_req_receiver_buf;
    return LIBSPDM_STATUS_SUCCESS;
}
static void req_release_receiver(void *ctx, const void *buf) {}

/* ── rsp_ctx buffer stubs (not called via process_request/build_response) ─── */

static libspdm_return_t rsp_acquire_sender(void *ctx, void **buf) {
    return LIBSPDM_STATUS_ACQUIRE_FAIL;
}
static void rsp_release_sender(void *ctx, const void *buf) {}
static libspdm_return_t rsp_acquire_receiver(void *ctx, void **buf) {
    return LIBSPDM_STATUS_ACQUIRE_FAIL;
}
static void rsp_release_receiver(void *ctx, const void *buf) {}

/* ── req_ctx transport: forward each encrypted request to real rsp code ───── */

static libspdm_return_t req_send_message(void *ctx,
                                          size_t size, const void *msg,
                                          uint64_t timeout)
{
    uint32_t *session_id = NULL;
    bool      is_app     = false;
    libspdm_return_t status;

    /* Copy into a local buffer so rsp_ctx can mutate it during decode */
    static uint8_t rsp_req_buf[LIBSPDM_MAX_SENDER_RECEIVER_BUFFER_SIZE];
    memcpy(rsp_req_buf, msg, size);

    status = libspdm_process_request(g_rsp_ctx, &session_id, &is_app,
                                      size, rsp_req_buf);
    if (LIBSPDM_STATUS_IS_ERROR(status)) {
        fprintf(stderr, "libspdm_process_request: 0x%x\n", (unsigned)status);
        return LIBSPDM_STATUS_SEND_FAIL;
    }

    g_rsp_response_size = sizeof(g_rsp_response_buf);
    g_rsp_response_ptr  = g_rsp_response_buf;

    status = libspdm_build_response(g_rsp_ctx, session_id, is_app,
                                     &g_rsp_response_size, &g_rsp_response_ptr);
    if (LIBSPDM_STATUS_IS_ERROR(status)) {
        fprintf(stderr, "libspdm_build_response: 0x%x\n", (unsigned)status);
        return LIBSPDM_STATUS_SEND_FAIL;
    }

    if (g_rsp_response_ptr != (void *)g_rsp_response_buf) {
        memmove(g_rsp_response_buf, g_rsp_response_ptr, g_rsp_response_size);
        g_rsp_response_ptr = g_rsp_response_buf;
    }

    return LIBSPDM_STATUS_SUCCESS;
}

static libspdm_return_t req_receive_message(void *ctx,
                                             size_t *size, void **buf,
                                             uint64_t timeout)
{
    if (g_rsp_response_size == 0) return LIBSPDM_STATUS_RECEIVE_FAIL;
    memcpy(*buf, g_rsp_response_ptr, g_rsp_response_size);
    *size = g_rsp_response_size;
    return LIBSPDM_STATUS_SUCCESS;
}

/* ── context factory ──────────────────────────────────────────────────────── */

typedef struct { void *ctx; void *scratch; } spdm_ctx_t;

static spdm_ctx_t make_req_ctx(void)
{
    spdm_ctx_t c;
    c.ctx = malloc(libspdm_get_context_size());
    assert(c.ctx);
    libspdm_init_context(c.ctx);

    libspdm_register_device_io_func(c.ctx, req_send_message, req_receive_message);
    libspdm_register_transport_layer_func(c.ctx,
        LIBSPDM_MAX_SPDM_MSG_SIZE,
        LIBSPDM_TEST_TRANSPORT_HEADER_SIZE,
        LIBSPDM_TEST_TRANSPORT_TAIL_SIZE,
        libspdm_transport_test_encode_message,
        libspdm_transport_test_decode_message);
    libspdm_register_device_buffer_func(c.ctx,
        LIBSPDM_MAX_SENDER_RECEIVER_BUFFER_SIZE,
        LIBSPDM_MAX_SENDER_RECEIVER_BUFFER_SIZE,
        req_acquire_sender,  req_release_sender,
        req_acquire_receiver, req_release_receiver);

    size_t ssz = libspdm_get_sizeof_required_scratch_buffer(c.ctx);
    c.scratch  = malloc(ssz);
    assert(c.scratch);
    libspdm_set_scratch_buffer(c.ctx, c.scratch, ssz);

    libspdm_context_t *x = c.ctx;
    x->connection_info.version =
        SPDM_MESSAGE_VERSION_11 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    x->connection_info.connection_state = LIBSPDM_CONNECTION_STATE_NEGOTIATED;

    x->connection_info.capability.flags |=   /* peer = responder */
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_KEY_UPD_CAP |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_ENCRYPT_CAP |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MAC_CAP      |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_HBEAT_CAP;
    x->local_context.capability.flags |=     /* self = requester */
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_KEY_UPD_CAP |
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_ENCRYPT_CAP |
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_MAC_CAP      |
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_HBEAT_CAP;

    x->connection_info.algorithm.base_hash_algo    = m_libspdm_use_hash_algo;
    x->connection_info.algorithm.base_asym_algo    = m_libspdm_use_asym_algo;
    x->connection_info.algorithm.dhe_named_group   = m_libspdm_use_dhe_algo;
    x->connection_info.algorithm.aead_cipher_suite = m_libspdm_use_aead_algo;

    return c;
}

static spdm_ctx_t make_rsp_ctx(void)
{
    spdm_ctx_t c;
    c.ctx = malloc(libspdm_get_context_size());
    assert(c.ctx);
    libspdm_init_context(c.ctx);

    libspdm_register_transport_layer_func(c.ctx,
        LIBSPDM_MAX_SPDM_MSG_SIZE,
        LIBSPDM_TEST_TRANSPORT_HEADER_SIZE,
        LIBSPDM_TEST_TRANSPORT_TAIL_SIZE,
        libspdm_transport_test_encode_message,
        libspdm_transport_test_decode_message);
    libspdm_register_device_buffer_func(c.ctx,
        LIBSPDM_MAX_SENDER_RECEIVER_BUFFER_SIZE,
        LIBSPDM_MAX_SENDER_RECEIVER_BUFFER_SIZE,
        rsp_acquire_sender,  rsp_release_sender,
        rsp_acquire_receiver, rsp_release_receiver);

    size_t ssz = libspdm_get_sizeof_required_scratch_buffer(c.ctx);
    c.scratch  = malloc(ssz);
    assert(c.scratch);
    libspdm_set_scratch_buffer(c.ctx, c.scratch, ssz);

    libspdm_context_t *x = c.ctx;
    x->connection_info.version =
        SPDM_MESSAGE_VERSION_11 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    x->connection_info.connection_state = LIBSPDM_CONNECTION_STATE_NEGOTIATED;

    x->connection_info.capability.flags |=   /* peer = requester */
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_KEY_UPD_CAP |
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_ENCRYPT_CAP |
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_MAC_CAP      |
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_HBEAT_CAP;
    x->local_context.capability.flags |=     /* self = responder */
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_KEY_UPD_CAP |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_ENCRYPT_CAP |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MAC_CAP      |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_HBEAT_CAP;

    x->connection_info.algorithm.base_hash_algo    = m_libspdm_use_hash_algo;
    x->connection_info.algorithm.base_asym_algo    = m_libspdm_use_asym_algo;
    x->connection_info.algorithm.dhe_named_group   = m_libspdm_use_dhe_algo;
    x->connection_info.algorithm.aead_cipher_suite = m_libspdm_use_aead_algo;

    return c;
}

/* ── session setup: inject identical AEAD secrets into both contexts ──────── */

static uint32_t setup_session(void *req_ctx, void *rsp_ctx)
{
    const uint32_t session_id = 0xFFFFFFFF;
    const spdm_version_number_t ver =
        (spdm_version_number_t)(SECURED_SPDM_VERSION_11 << SPDM_VERSION_NUMBER_SHIFT_BIT);

    libspdm_context_t     *rc  = req_ctx;
    libspdm_session_info_t *rsi = &rc->session_info[0];
    libspdm_session_info_init(req_ctx, rsi, session_id, ver, true);
    libspdm_secured_message_set_session_state(
        rsi->secured_message_context, LIBSPDM_SESSION_STATE_ESTABLISHED);
    rsi->heartbeat_period = 1;

    libspdm_context_t     *sc  = rsp_ctx;
    libspdm_session_info_t *ssi = &sc->session_info[0];
    libspdm_session_info_init(rsp_ctx, ssi, session_id, ver, false);
    libspdm_secured_message_set_session_state(
        ssi->secured_message_context, LIBSPDM_SESSION_STATE_ESTABLISHED);
    ssi->heartbeat_period = 1;

    libspdm_secured_message_context_t *rmc = rsi->secured_message_context;
    libspdm_secured_message_context_t *smc = ssi->secured_message_context;

    uint8_t req_sec[LIBSPDM_MAX_HASH_SIZE], rsp_sec[LIBSPDM_MAX_HASH_SIZE];
    libspdm_set_mem(req_sec, rmc->hash_size, 0xEE);
    libspdm_set_mem(rsp_sec, rmc->hash_size, 0xFF);

    /* req_ctx: 0xEE = requester TX (encrypt), 0xFF = responder TX (decrypt) */
    libspdm_copy_mem(rmc->application_secret.request_data_secret,
                     sizeof(rmc->application_secret.request_data_secret),
                     req_sec, rmc->aead_key_size);
    libspdm_copy_mem(rmc->application_secret.response_data_secret,
                     sizeof(rmc->application_secret.response_data_secret),
                     rsp_sec, rmc->aead_key_size);
    libspdm_set_mem(rmc->application_secret.request_data_encryption_key,
                    rmc->aead_key_size, 0xEE);
    libspdm_set_mem(rmc->application_secret.request_data_salt,
                    rmc->aead_iv_size,  0xEE);
    libspdm_set_mem(rmc->application_secret.response_data_encryption_key,
                    rmc->aead_key_size, 0xFF);
    libspdm_set_mem(rmc->application_secret.response_data_salt,
                    rmc->aead_iv_size,  0xFF);
    rmc->application_secret.request_data_sequence_number  = 0;
    rmc->application_secret.response_data_sequence_number = 0;

    /* rsp_ctx: mirror (same key material, deterministic KDF syncs on update) */
    libspdm_copy_mem(smc->application_secret.request_data_secret,
                     sizeof(smc->application_secret.request_data_secret),
                     req_sec, smc->aead_key_size);
    libspdm_copy_mem(smc->application_secret.response_data_secret,
                     sizeof(smc->application_secret.response_data_secret),
                     rsp_sec, smc->aead_key_size);
    libspdm_set_mem(smc->application_secret.request_data_encryption_key,
                    smc->aead_key_size, 0xEE);
    libspdm_set_mem(smc->application_secret.request_data_salt,
                    smc->aead_iv_size,  0xEE);
    libspdm_set_mem(smc->application_secret.response_data_encryption_key,
                    smc->aead_key_size, 0xFF);
    libspdm_set_mem(smc->application_secret.response_data_salt,
                    smc->aead_iv_size,  0xFF);
    smc->application_secret.request_data_sequence_number  = 0;
    smc->application_secret.response_data_sequence_number = 0;

    return session_id;
}

/* ── shadow state reset between scenarios ────────────────────────────────── */

static void reset_tla_state(void) {
    g_tla.req_tx_gen              = 0;
    g_tla.rsp_rx_gen              = 0;
    g_tla.req_ku_state            = "idle";
    g_tla.rsp_last_key_op         = "none";
    g_tla.req_session_state       = "ESTABLISHED";
    g_tla.rsp_session_state       = "ESTABLISHED";
    g_tla.rsp_rx_backup_valid     = false;
    g_tla.end_session_sent        = false;
    g_tla.end_session_ack_encoded = false;
    g_tla.watchdog_active         = true;
}

/* ── scenarios ───────────────────────────────────────────────────────────── */

/* 4 heartbeats (12 events) + 1 single key_update (5 events) + end_session (4) = 21 */
static void scenario_heartbeat(const char *path)
{
    spdm_ctx_t req = make_req_ctx();
    spdm_ctx_t rsp = make_rsp_ctx();
    g_rsp_ctx = rsp.ctx;

    uint32_t sid = setup_session(req.ctx, rsp.ctx);
    reset_tla_state();
    tla_init(path);

    for (int i = 0; i < 4; i++) {
        libspdm_return_t s = libspdm_heartbeat(req.ctx, sid);
        if (LIBSPDM_STATUS_IS_ERROR(s))
            fprintf(stderr, "heartbeat[%d]: 0x%x\n", i, (unsigned)s);
    }

    libspdm_return_t s = libspdm_key_update(req.ctx, sid, true);
    if (LIBSPDM_STATUS_IS_ERROR(s))
        fprintf(stderr, "key_update_single: 0x%x\n", (unsigned)s);

    s = libspdm_send_receive_end_session(req.ctx, sid, 0);
    if (LIBSPDM_STATUS_IS_ERROR(s))
        fprintf(stderr, "end_session: 0x%x\n", (unsigned)s);

    tla_finish();
    free(req.scratch); free(req.ctx);
    free(rsp.scratch); free(rsp.ctx);
}

/* 4 × single-direction key_update (20) + end_session (4) = 24 */
static void scenario_ku_single(const char *path)
{
    spdm_ctx_t req = make_req_ctx();
    spdm_ctx_t rsp = make_rsp_ctx();
    g_rsp_ctx = rsp.ctx;

    uint32_t sid = setup_session(req.ctx, rsp.ctx);
    reset_tla_state();
    tla_init(path);

    for (int i = 0; i < 4; i++) {
        libspdm_return_t s = libspdm_key_update(req.ctx, sid, true);
        if (LIBSPDM_STATUS_IS_ERROR(s))
            fprintf(stderr, "key_update_single[%d]: 0x%x\n", i, (unsigned)s);
    }

    libspdm_return_t s = libspdm_send_receive_end_session(req.ctx, sid, 0);
    if (LIBSPDM_STATUS_IS_ERROR(s))
        fprintf(stderr, "end_session: 0x%x\n", (unsigned)s);

    tla_finish();
    free(req.scratch); free(req.ctx);
    free(rsp.scratch); free(rsp.ctx);
}

/* 4 × all-keys key_update (20) + end_session (4) = 24 */
static void scenario_ku_all(const char *path)
{
    spdm_ctx_t req = make_req_ctx();
    spdm_ctx_t rsp = make_rsp_ctx();
    g_rsp_ctx = rsp.ctx;

    uint32_t sid = setup_session(req.ctx, rsp.ctx);
    reset_tla_state();
    tla_init(path);

    for (int i = 0; i < 4; i++) {
        libspdm_return_t s = libspdm_key_update(req.ctx, sid, false);
        if (LIBSPDM_STATUS_IS_ERROR(s))
            fprintf(stderr, "key_update_all[%d]: 0x%x\n", i, (unsigned)s);
    }

    libspdm_return_t s = libspdm_send_receive_end_session(req.ctx, sid, 0);
    if (LIBSPDM_STATUS_IS_ERROR(s))
        fprintf(stderr, "end_session: 0x%x\n", (unsigned)s);

    tla_finish();
    free(req.scratch); free(req.ctx);
    free(rsp.scratch); free(rsp.ctx);
}

/* ── entry point ─────────────────────────────────────────────────────────── */

int main(int argc, char *argv[])
{
    const char *dir = (argc > 1) ? argv[1] : "traces";
    char path[512];

    snprintf(path, sizeof(path), "%s/trace_heartbeat.ndjson", dir);
    printf("scenario: heartbeat => %s\n", path);
    scenario_heartbeat(path);

    snprintf(path, sizeof(path), "%s/trace_key_update_single.ndjson", dir);
    printf("scenario: ku_single => %s\n", path);
    scenario_ku_single(path);

    snprintf(path, sizeof(path), "%s/trace_key_update_all_keys.ndjson", dir);
    printf("scenario: ku_all    => %s\n", path);
    scenario_ku_all(path);

    printf("All scenarios complete.\n");
    return 0;
}
