/**
 * TLA+ trace harness for libspdm key exchange / finish.
 *
 * Runs a loopback requester+responder pair in a single process using a
 * pre-negotiated state (VCA skipped) identical to the libspdm unit tests.
 * Each scenario writes one NDJSON trace file.
 *
 * Scenarios:
 *   normal_keyex  — basic key exchange + finish (non-HITC, no mut-auth)
 *   hitc_keyex    — HANDSHAKE_IN_THE_CLEAR key exchange + finish
 *   app_data      — normal KE+finish then 3 app data messages
 *
 * Build: must link against spdm_device_secret_lib_sample.
 * Run from build output dir (where sample_key certs are copied by cmake).
 * Usage: ./trace_test [traces_dir]
 */

#define LIBSPDM_MAX_CERT_CHAIN_SIZE 0x2000

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <assert.h>

#include "hal/base.h"
#include "hal/library/memlib.h"
#include "library/spdm_requester_lib.h"
#include "library/spdm_responder_lib.h"
#include "library/spdm_transport_test_lib.h"
#include "internal/libspdm_common_lib.h"
#include "internal/libspdm_requester_lib.h"
#include "internal/libspdm_secured_message_lib.h"
#include "spdm_device_secret_lib_internal.h"
#include "tla_trace.h"

/* ------------------------------------------------------------------ */
/* Buffer layout                                                        */
/* LIBSPDM_TEST_TRANSPORT_HEADER/TAIL_SIZE come from spdm_transport_test_lib.h */
#define LOOPBACK_BUF_SIZE (0x1200 + LIBSPDM_TEST_TRANSPORT_HEADER_SIZE + \
                           LIBSPDM_TEST_TRANSPORT_TAIL_SIZE)

/* ------------------------------------------------------------------ */
/* Loopback state                                                       */

typedef struct {
    uint8_t req_msg[LOOPBACK_BUF_SIZE]; /* latest requester outgoing msg */
    size_t  req_msg_size;
    uint8_t rsp_msg[LOOPBACK_BUF_SIZE]; /* built responder response     */
    size_t  rsp_msg_size;
    libspdm_context_t *responder;
} loopback_t;

static loopback_t g_lb;

/* ------------------------------------------------------------------ */
/* Separate device buffers for requester and responder                  */

static uint8_t g_req_buf[LOOPBACK_BUF_SIZE];
static bool    g_req_buf_in_use = false;

static uint8_t g_rsp_buf[LOOPBACK_BUF_SIZE];
static bool    g_rsp_buf_in_use = false;

static libspdm_return_t req_acq_send(void *c, void **p)
{
    (void)c;
    LIBSPDM_ASSERT(!g_req_buf_in_use);
    g_req_buf_in_use = true;
    memset(g_req_buf, 0, sizeof(g_req_buf));
    *p = g_req_buf;
    return LIBSPDM_STATUS_SUCCESS;
}
static void req_rel_send(void *c, const void *p) { (void)c; (void)p; g_req_buf_in_use = false; }
static libspdm_return_t req_acq_recv(void *c, void **p) { return req_acq_send(c, p); }
static void req_rel_recv(void *c, const void *p) { req_rel_send(c, p); }

static libspdm_return_t rsp_acq_send(void *c, void **p)
{
    (void)c;
    LIBSPDM_ASSERT(!g_rsp_buf_in_use);
    g_rsp_buf_in_use = true;
    memset(g_rsp_buf, 0, sizeof(g_rsp_buf));
    *p = g_rsp_buf;
    return LIBSPDM_STATUS_SUCCESS;
}
static void rsp_rel_send(void *c, const void *p) { (void)c; (void)p; g_rsp_buf_in_use = false; }
static libspdm_return_t rsp_acq_recv(void *c, void **p) { return rsp_acq_send(c, p); }
static void rsp_rel_recv(void *c, const void *p) { rsp_rel_send(c, p); }

/* ------------------------------------------------------------------ */
/* Requester I/O: send stores the message; receive drives the responder */

static libspdm_return_t req_send(void *ctx, size_t sz, const void *data, uint64_t to)
{
    (void)ctx; (void)to;
    LIBSPDM_ASSERT(sz <= sizeof(g_lb.req_msg));
    memcpy(g_lb.req_msg, data, sz);
    g_lb.req_msg_size = sz;
    return LIBSPDM_STATUS_SUCCESS;
}

static libspdm_return_t req_recv(void *ctx, size_t *sz, void **data, uint64_t to)
{
    (void)ctx; (void)to;

    libspdm_context_t *rsp = g_lb.responder;
    uint32_t *session_id   = NULL;
    bool      is_app       = false;

    /* Deliver request bytes directly to the responder (no I/O callback) */
    libspdm_return_t s = libspdm_process_request(
        rsp, &session_id, &is_app, g_lb.req_msg_size, g_lb.req_msg);
    if (LIBSPDM_STATUS_IS_ERROR(s)) {
        fprintf(stderr, "[rsp] process_request failed: 0x%x\n", (unsigned)s);
        return s;
    }

    /* Acquire the responder's sender buffer and build the response */
    size_t rsp_sz = 0;
    void  *rsp_p  = NULL;
    s = libspdm_acquire_sender_buffer(rsp, &rsp_sz, &rsp_p);
    if (LIBSPDM_STATUS_IS_ERROR(s)) return s;

    s = libspdm_build_response(rsp, session_id, is_app, &rsp_sz, &rsp_p);
    if (LIBSPDM_STATUS_IS_ERROR(s)) {
        libspdm_release_sender_buffer(rsp);
        fprintf(stderr, "[rsp] build_response failed: 0x%x\n", (unsigned)s);
        return s;
    }

    /* Copy response to loopback buffer and release responder's sender buffer */
    LIBSPDM_ASSERT(rsp_sz <= sizeof(g_lb.rsp_msg));
    memcpy(g_lb.rsp_msg, rsp_p, rsp_sz);
    g_lb.rsp_msg_size = rsp_sz;
    libspdm_release_sender_buffer(rsp);

    *sz   = g_lb.rsp_msg_size;
    *data = g_lb.rsp_msg;
    return LIBSPDM_STATUS_SUCCESS;
}

/* Responder device I/O — not exercised in this flow; provide stubs */
static libspdm_return_t rsp_send(void *c, size_t s, const void *d, uint64_t t)
{
    (void)c; (void)s; (void)d; (void)t;
    return LIBSPDM_STATUS_SUCCESS;
}
static libspdm_return_t rsp_recv(void *c, size_t *s, void **d, uint64_t t)
{
    (void)c; (void)t;
    *s = g_lb.req_msg_size;
    *d = g_lb.req_msg;
    return LIBSPDM_STATUS_SUCCESS;
}

/* ------------------------------------------------------------------ */
/* Context setup                                                        */
/*
 * We use the pre-negotiated state pattern (same as libspdm unit tests):
 * - connection_state = NEGOTIATED
 * - algorithms pre-populated in connection_info.algorithm
 * - peer cert chain pre-loaded
 * This avoids running GET_VERSION/GET_CAPABILITIES/NEGOTIATE_ALGORITHMS
 * and lets us focus on KEY_EXCHANGE + FINISH.
 */

#define HASH_ALGO   SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256
#define ASYM_ALGO   SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_ECDSA_ECC_NIST_P256
#define REQ_ASYM    SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_RSASSA_2048
#define DHE_GROUP   SPDM_ALGORITHMS_DHE_NAMED_GROUP_SECP_256_R1
#define AEAD_SUITE  SPDM_ALGORITHMS_AEAD_CIPHER_SUITE_AES_256_GCM
#define KEY_SCHED   SPDM_ALGORITHMS_KEY_SCHEDULE_SPDM
#define MEAS_HASH   SPDM_ALGORITHMS_MEASUREMENT_HASH_ALGO_TPM_ALG_SHA_256

static uint32_t g_rsp_cap_flags =
    SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CERT_CAP |
    SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CHAL_CAP |
    SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MEAS_CAP_SIG |
    SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MEAS_FRESH_CAP |
    SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_ENCRYPT_CAP |
    SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MAC_CAP |
    SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_KEY_EX_CAP |
    SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_ENCAP_CAP;

static uint32_t g_req_cap_flags =
    SPDM_GET_CAPABILITIES_REQUEST_FLAGS_CERT_CAP |
    SPDM_GET_CAPABILITIES_REQUEST_FLAGS_CHAL_CAP |
    SPDM_GET_CAPABILITIES_REQUEST_FLAGS_ENCRYPT_CAP |
    SPDM_GET_CAPABILITIES_REQUEST_FLAGS_MAC_CAP |
    SPDM_GET_CAPABILITIES_REQUEST_FLAGS_KEY_EX_CAP |
    SPDM_GET_CAPABILITIES_REQUEST_FLAGS_ENCAP_CAP;

static void setup_req_ctx(libspdm_context_t *ctx, bool hitc)
{
    libspdm_init_context(ctx);
    ctx->local_context.is_requester = true;

    uint32_t hitc_req = hitc ?
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_HANDSHAKE_IN_THE_CLEAR_CAP : 0;
    uint32_t hitc_rsp = hitc ?
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_HANDSHAKE_IN_THE_CLEAR_CAP : 0;

    ctx->local_context.capability.flags = g_req_cap_flags | hitc_req;
    ctx->local_context.capability.ct_exponent             = 0;
    ctx->local_context.capability.data_transfer_size      = 0x1200;
    ctx->local_context.capability.sender_data_transfer_size = 0x1200;
    ctx->local_context.capability.max_spdm_msg_size       = 0x1200;
    ctx->local_context.capability.transport_header_size   = LIBSPDM_TEST_TRANSPORT_HEADER_SIZE;
    ctx->local_context.capability.transport_tail_size     = LIBSPDM_TEST_TRANSPORT_TAIL_SIZE;

    /* Pre-negotiated connection state (skips VCA) */
    ctx->connection_info.version =
        SPDM_MESSAGE_VERSION_11 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    ctx->connection_info.connection_state = LIBSPDM_CONNECTION_STATE_NEGOTIATED;
    ctx->connection_info.capability.flags = g_rsp_cap_flags | hitc_rsp;
    ctx->connection_info.algorithm.base_hash_algo       = HASH_ALGO;
    ctx->connection_info.algorithm.base_asym_algo       = ASYM_ALGO;
    ctx->connection_info.algorithm.dhe_named_group      = DHE_GROUP;
    ctx->connection_info.algorithm.aead_cipher_suite    = AEAD_SUITE;
    ctx->connection_info.algorithm.key_schedule         = KEY_SCHED;
    ctx->connection_info.algorithm.req_base_asym_alg    = REQ_ASYM;
    ctx->connection_info.algorithm.measurement_hash_algo = MEAS_HASH;
    ctx->connection_info.algorithm.other_params_support =
        SPDM_ALGORITHMS_OPAQUE_DATA_FORMAT_1;

    /* Load responder cert chain into peer_used_cert_chain[0] */
    void *cert_data = NULL; size_t cert_sz = 0;
    void *hash_data = NULL; size_t hash_sz = 0;
    if (!libspdm_read_responder_public_certificate_chain(
            HASH_ALGO, ASYM_ALGO, &cert_data, &cert_sz, &hash_data, &hash_sz)) {
        fprintf(stderr, "ERROR: cannot read responder cert chain\n");
        exit(1);
    }
    /* hash_data points into cert_data — do NOT free separately */
    (void)hash_data; (void)hash_sz;

#if LIBSPDM_RECORD_TRANSCRIPT_DATA_SUPPORT
    LIBSPDM_ASSERT(cert_sz <= sizeof(ctx->connection_info.peer_used_cert_chain[0].buffer));
    ctx->connection_info.peer_used_cert_chain[0].buffer_size = cert_sz;
    memcpy(ctx->connection_info.peer_used_cert_chain[0].buffer, cert_data, cert_sz);
    free(cert_data);
#else
    libspdm_hash_all(HASH_ALGO, cert_data, cert_sz,
                     ctx->connection_info.peer_used_cert_chain[0].buffer_hash);
    ctx->connection_info.peer_used_cert_chain[0].buffer_hash_size =
        libspdm_get_hash_size(HASH_ALGO);
    libspdm_get_leaf_cert_public_key_from_cert_chain(
        HASH_ALGO, ASYM_ALGO, cert_data, cert_sz,
        &ctx->connection_info.peer_used_cert_chain[0].leaf_cert_public_key);
    free(cert_data);
#endif

    libspdm_register_transport_layer_func(ctx, 0x1200,
        LIBSPDM_TEST_TRANSPORT_HEADER_SIZE, LIBSPDM_TEST_TRANSPORT_TAIL_SIZE,
        libspdm_transport_test_encode_message,
        libspdm_transport_test_decode_message);
    libspdm_register_device_io_func(ctx, req_send, req_recv);
    libspdm_register_device_buffer_func(ctx,
        LOOPBACK_BUF_SIZE, LOOPBACK_BUF_SIZE,
        req_acq_send, req_rel_send,
        req_acq_recv, req_rel_recv);
}

static void setup_rsp_ctx(libspdm_context_t *ctx, bool hitc)
{
    libspdm_init_context(ctx);
    ctx->local_context.is_requester = false;

    uint32_t hitc_rsp = hitc ?
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_HANDSHAKE_IN_THE_CLEAR_CAP : 0;
    uint32_t hitc_req = hitc ?
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_HANDSHAKE_IN_THE_CLEAR_CAP : 0;

    ctx->local_context.capability.flags = g_rsp_cap_flags | hitc_rsp;
    ctx->local_context.capability.ct_exponent             = 0;
    ctx->local_context.capability.data_transfer_size      = 0x1200;
    ctx->local_context.capability.sender_data_transfer_size = 0x1200;
    ctx->local_context.capability.max_spdm_msg_size       = 0x1200;
    ctx->local_context.capability.transport_header_size   = LIBSPDM_TEST_TRANSPORT_HEADER_SIZE;
    ctx->local_context.capability.transport_tail_size     = LIBSPDM_TEST_TRANSPORT_TAIL_SIZE;

    /* Pre-negotiated state */
    ctx->connection_info.version =
        SPDM_MESSAGE_VERSION_11 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    ctx->connection_info.connection_state = LIBSPDM_CONNECTION_STATE_NEGOTIATED;
    ctx->connection_info.capability.flags = g_req_cap_flags | hitc_req;
    ctx->connection_info.algorithm.base_hash_algo       = HASH_ALGO;
    ctx->connection_info.algorithm.base_asym_algo       = ASYM_ALGO;
    ctx->connection_info.algorithm.dhe_named_group      = DHE_GROUP;
    ctx->connection_info.algorithm.aead_cipher_suite    = AEAD_SUITE;
    ctx->connection_info.algorithm.key_schedule         = KEY_SCHED;
    ctx->connection_info.algorithm.req_base_asym_alg    = REQ_ASYM;
    ctx->connection_info.algorithm.measurement_hash_algo = MEAS_HASH;
    ctx->connection_info.algorithm.other_params_support =
        SPDM_ALGORITHMS_OPAQUE_DATA_FORMAT_1;

    /* Load responder cert chain as local provision */
    void *cert_data = NULL; size_t cert_sz = 0;
    void *hash_data = NULL; size_t hash_sz = 0;
    if (!libspdm_read_responder_public_certificate_chain(
            HASH_ALGO, ASYM_ALGO, &cert_data, &cert_sz, &hash_data, &hash_sz)) {
        fprintf(stderr, "ERROR: cannot read responder cert chain for responder\n");
        exit(1);
    }
    /* hash_data points into cert_data — do NOT free separately */
    (void)hash_data; (void)hash_sz;
    ctx->local_context.local_cert_chain_provision[0]      = cert_data;
    ctx->local_context.local_cert_chain_provision_size[0] = cert_sz;

    libspdm_register_transport_layer_func(ctx, 0x1200,
        LIBSPDM_TEST_TRANSPORT_HEADER_SIZE, LIBSPDM_TEST_TRANSPORT_TAIL_SIZE,
        libspdm_transport_test_encode_message,
        libspdm_transport_test_decode_message);
    libspdm_register_device_io_func(ctx, rsp_send, rsp_recv);
    libspdm_register_device_buffer_func(ctx,
        LOOPBACK_BUF_SIZE, LOOPBACK_BUF_SIZE,
        rsp_acq_send, rsp_rel_send,
        rsp_acq_recv, rsp_rel_recv);
}

/* ------------------------------------------------------------------ */
/* Scratch buffer helper                                                */

static void *alloc_context_with_scratch(bool hitc, bool is_req)
{
    size_t ctx_sz = libspdm_get_context_size();
    libspdm_context_t *ctx = (libspdm_context_t *)malloc(ctx_sz);
    assert(ctx);

    if (is_req) setup_req_ctx(ctx, hitc);
    else        setup_rsp_ctx(ctx, hitc);

    size_t sc_sz = libspdm_get_sizeof_required_scratch_buffer(ctx);
    void  *sc    = malloc(sc_sz);
    assert(sc);
    libspdm_set_scratch_buffer(ctx, sc, sc_sz);

    return ctx;
}

/* ------------------------------------------------------------------ */
/* Run one scenario                                                     */

static void run_scenario(const char *trace_path, bool hitc, bool app_data)
{
    printf("[trace_test] %s hitc=%d app=%d\n", trace_path, hitc, app_data);
    tla_trace_open(trace_path);

    /* Reset loopback buffer flags */
    g_req_buf_in_use = false;
    g_rsp_buf_in_use = false;

    libspdm_context_t *req = (libspdm_context_t *)alloc_context_with_scratch(hitc, true);
    libspdm_context_t *rsp = (libspdm_context_t *)alloc_context_with_scratch(hitc, false);

    g_lb.responder = rsp;

    /* KEY_EXCHANGE */
    uint32_t session_id    = 0;
    uint8_t  heartbeat     = 0;
    uint8_t  req_slot_param = 0;
    uint8_t  mhash[64]     = {0};

    libspdm_return_t s = libspdm_send_receive_key_exchange(
        req,
        SPDM_KEY_EXCHANGE_REQUEST_NO_MEASUREMENT_SUMMARY_HASH,
        0, 0,
        &session_id, &heartbeat, &req_slot_param, mhash);
    if (LIBSPDM_STATUS_IS_ERROR(s)) {
        fprintf(stderr, "[req] key_exchange failed: 0x%x\n", (unsigned)s);
        goto done;
    }
    printf("[trace_test] KEY_EXCHANGE ok, session_id=0x%x\n", session_id);

    /* FINISH */
    s = libspdm_send_receive_finish(req, session_id, 0);
    if (LIBSPDM_STATUS_IS_ERROR(s)) {
        fprintf(stderr, "[req] finish failed: 0x%x\n", (unsigned)s);
        goto done;
    }
    printf("[trace_test] FINISH ok\n");

    if (app_data) {
        libspdm_session_info_t *si =
            libspdm_get_session_info_via_session_id(req, session_id);
        int tla_slot = si ? (int)(si - req->session_info) + 1 : 1;

        for (int i = 0; i < 3; i++) {
            uint8_t app_req[16]  = {0x01, 0x02, 0x03, 0x04};
            uint8_t app_rsp[256] = {0};
            size_t  app_rsp_sz   = sizeof(app_rsp);
            app_req[0] = (uint8_t)(i + 1);

            /* Emit req_send_app_data with current sequence number */
            libspdm_session_info_t *req_si =
                libspdm_get_session_info_via_session_id(req, session_id);
            uint64_t seq = 0;
            if (req_si) {
                libspdm_secured_message_context_t *smc =
                    (libspdm_secured_message_context_t *)req_si->secured_message_context;
                seq = smc->application_secret.request_data_sequence_number;
            }
            TLA_EMIT_REQ_SEND_APP_DATA(tla_slot, (int)seq);

            s = libspdm_send_receive_data(req, &session_id, false,
                                          app_req, sizeof(app_req),
                                          app_rsp, &app_rsp_sz);
            if (LIBSPDM_STATUS_IS_ERROR(s)) {
                fprintf(stderr, "[req] send_receive_data[%d] failed: 0x%x\n",
                        i, (unsigned)s);
                break;
            }
            printf("[trace_test] app_data[%d] ok seq=%llu\n",
                   i, (unsigned long long)seq);
        }
    }

done:
    tla_trace_close();
    free(req);
    free(rsp);
    /* Note: cert_data and scratch buffers are leaked intentionally —
     * the process exits immediately after scenarios complete. */
}

/* ------------------------------------------------------------------ */
int main(int argc, char *argv[])
{
    const char *dir = (argc > 1) ? argv[1] : "traces";
    char path[512];

    snprintf(path, sizeof(path), "%s/normal_keyex.ndjson", dir);
    run_scenario(path, false, false);

    snprintf(path, sizeof(path), "%s/hitc_keyex.ndjson", dir);
    run_scenario(path, true, false);

    snprintf(path, sizeof(path), "%s/app_data.ndjson", dir);
    run_scenario(path, false, true);

    printf("All scenarios complete. Traces in %s/\n", dir);
    return 0;
}
