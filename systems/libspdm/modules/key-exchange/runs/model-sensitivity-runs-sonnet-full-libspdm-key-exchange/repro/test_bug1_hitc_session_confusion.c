/**
 * BUG-001 Reproduction: HITC Session Identity Confusion
 *
 * Level 0 test: One requester, one responder. Both use HITC.
 * The requester initiates TWO KEY_EXCHANGE sessions before sending FINISH
 * for the first one. The second KEY_EXCHANGE overwrites latest_session_id
 * on the responder. When session 1's FINISH arrives cleartext (HITC path,
 * no session_id in header), the responder uses latest_session_id = S2 and
 * applies session 1's FINISH to the wrong session context.
 *
 * Trigger:
 *   1. req KEY_EXCHANGE session S1 (HITC=TRUE)  -> latest_session_id = S1
 *   2. req KEY_EXCHANGE session S2 (HITC=TRUE)  -> latest_session_id = S2 (BUG: overwrites)
 *   3. req FINISH for S1 (cleartext, HITC path) -> responder uses latest_session_id = S2
 *
 * Expected (correct): FINISH for S1 routes to S1, verifies S1 HMAC, succeeds.
 * Observed (buggy):   FINISH for S1 is delivered to S2's handler, HMAC
 *                     mismatch causes an error, and S1 can never be established.
 *
 * Root cause: libspdm_com_context_data_session.c:221 unconditionally updates
 *             latest_session_id on every session allocation.
 *             libspdm_rsp_finish_rsp.c:484 uses latest_session_id when
 *             last_spdm_request_session_id_valid=false (HITC cleartext path).
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

#define LOOPBACK_BUF_SIZE (0x1200 + LIBSPDM_TEST_TRANSPORT_HEADER_SIZE + \
                           LIBSPDM_TEST_TRANSPORT_TAIL_SIZE)

#define HASH_ALGO   SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256
#define ASYM_ALGO   SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_ECDSA_ECC_NIST_P256
#define REQ_ASYM    SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_RSASSA_2048
#define DHE_GROUP   SPDM_ALGORITHMS_DHE_NAMED_GROUP_SECP_256_R1
#define AEAD_SUITE  SPDM_ALGORITHMS_AEAD_CIPHER_SUITE_AES_256_GCM
#define KEY_SCHED   SPDM_ALGORITHMS_KEY_SCHEDULE_SPDM
#define MEAS_HASH   SPDM_ALGORITHMS_MEASUREMENT_HASH_ALGO_TPM_ALG_SHA_256

static uint32_t g_cap_hitc_rsp =
    SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CERT_CAP |
    SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CHAL_CAP |
    SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_ENCRYPT_CAP |
    SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MAC_CAP |
    SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_KEY_EX_CAP |
    SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_HANDSHAKE_IN_THE_CLEAR_CAP;

static uint32_t g_cap_hitc_req =
    SPDM_GET_CAPABILITIES_REQUEST_FLAGS_CERT_CAP |
    SPDM_GET_CAPABILITIES_REQUEST_FLAGS_ENCRYPT_CAP |
    SPDM_GET_CAPABILITIES_REQUEST_FLAGS_MAC_CAP |
    SPDM_GET_CAPABILITIES_REQUEST_FLAGS_KEY_EX_CAP |
    SPDM_GET_CAPABILITIES_REQUEST_FLAGS_HANDSHAKE_IN_THE_CLEAR_CAP;

/* --- Loopback --- */

typedef struct {
    uint8_t req_msg[LOOPBACK_BUF_SIZE];
    size_t  req_msg_size;
    uint8_t rsp_msg[LOOPBACK_BUF_SIZE];
    size_t  rsp_msg_size;
    libspdm_context_t *responder;
} loopback_t;

static loopback_t g_lb;
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

static libspdm_return_t req_send(void *c, size_t sz, const void *d, uint64_t t)
{ (void)c;(void)t; assert(sz<=sizeof(g_lb.req_msg)); memcpy(g_lb.req_msg,d,sz); g_lb.req_msg_size=sz; return LIBSPDM_STATUS_SUCCESS; }

static libspdm_return_t req_recv(void *ctx, size_t *sz, void **data, uint64_t to)
{
    (void)ctx; (void)to;
    libspdm_context_t *rsp = g_lb.responder;
    uint32_t *session_id = NULL;
    bool is_app = false;
    libspdm_return_t s = libspdm_process_request(rsp, &session_id, &is_app,
                                                  g_lb.req_msg_size, g_lb.req_msg);
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

static void load_rsp_cert_to_peer(libspdm_context_t *ctx)
{
    void *cd = NULL; size_t cs = 0;
    void *hd = NULL; size_t hs = 0;
    if (!libspdm_read_responder_public_certificate_chain(HASH_ALGO, ASYM_ALGO, &cd, &cs, &hd, &hs)) {
        fprintf(stderr, "ERROR: cannot read cert chain\n"); exit(1);
    }
    (void)hd; (void)hs;
#if LIBSPDM_RECORD_TRANSCRIPT_DATA_SUPPORT
    ctx->connection_info.peer_used_cert_chain[0].buffer_size = cs;
    memcpy(ctx->connection_info.peer_used_cert_chain[0].buffer, cd, cs);
    free(cd);
#else
    libspdm_hash_all(HASH_ALGO, cd, cs, ctx->connection_info.peer_used_cert_chain[0].buffer_hash);
    ctx->connection_info.peer_used_cert_chain[0].buffer_hash_size = libspdm_get_hash_size(HASH_ALGO);
    libspdm_get_leaf_cert_public_key_from_cert_chain(HASH_ALGO, ASYM_ALGO, cd, cs,
        &ctx->connection_info.peer_used_cert_chain[0].leaf_cert_public_key);
    free(cd);
#endif
}

int main(void)
{
    printf("=== BUG-001: HITC Session Identity Confusion ===\n");
    printf("One requester, one responder, both HITC-capable.\n");
    printf("Requester initiates TWO KEY_EXCHANGE sessions before either FINISH.\n\n");

    /* Set up requester (HITC) */
    size_t ctx_sz = libspdm_get_context_size();
    libspdm_context_t *req = malloc(ctx_sz); assert(req);
    libspdm_init_context(req);
    req->local_context.is_requester = true;
    req->local_context.capability.flags = g_cap_hitc_req;
    req->local_context.capability.ct_exponent = 0;
    req->local_context.capability.data_transfer_size = 0x1200;
    req->local_context.capability.sender_data_transfer_size = 0x1200;
    req->local_context.capability.max_spdm_msg_size = 0x1200;
    req->local_context.capability.transport_header_size = LIBSPDM_TEST_TRANSPORT_HEADER_SIZE;
    req->local_context.capability.transport_tail_size = LIBSPDM_TEST_TRANSPORT_TAIL_SIZE;
    req->connection_info.version = SPDM_MESSAGE_VERSION_11 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    req->connection_info.connection_state = LIBSPDM_CONNECTION_STATE_NEGOTIATED;
    req->connection_info.capability.flags = g_cap_hitc_rsp;
    req->connection_info.algorithm.base_hash_algo    = HASH_ALGO;
    req->connection_info.algorithm.base_asym_algo    = ASYM_ALGO;
    req->connection_info.algorithm.dhe_named_group   = DHE_GROUP;
    req->connection_info.algorithm.aead_cipher_suite = AEAD_SUITE;
    req->connection_info.algorithm.key_schedule      = KEY_SCHED;
    req->connection_info.algorithm.req_base_asym_alg = REQ_ASYM;
    req->connection_info.algorithm.measurement_hash_algo = MEAS_HASH;
    req->connection_info.algorithm.other_params_support  = SPDM_ALGORITHMS_OPAQUE_DATA_FORMAT_1;
    load_rsp_cert_to_peer(req);
    libspdm_register_transport_layer_func(req, 0x1200,
        LIBSPDM_TEST_TRANSPORT_HEADER_SIZE, LIBSPDM_TEST_TRANSPORT_TAIL_SIZE,
        libspdm_transport_test_encode_message, libspdm_transport_test_decode_message);
    libspdm_register_device_io_func(req, req_send, req_recv);
    libspdm_register_device_buffer_func(req, LOOPBACK_BUF_SIZE, LOOPBACK_BUF_SIZE,
        req_acq_send, req_rel_send, req_acq_recv, req_rel_recv);
    size_t sc_sz = libspdm_get_sizeof_required_scratch_buffer(req);
    libspdm_set_scratch_buffer(req, malloc(sc_sz), sc_sz);

    /* Set up responder (HITC) */
    libspdm_context_t *rsp = malloc(ctx_sz); assert(rsp);
    libspdm_init_context(rsp);
    rsp->local_context.is_requester = false;
    rsp->local_context.capability.flags = g_cap_hitc_rsp;
    rsp->local_context.capability.ct_exponent = 0;
    rsp->local_context.capability.data_transfer_size = 0x1200;
    rsp->local_context.capability.sender_data_transfer_size = 0x1200;
    rsp->local_context.capability.max_spdm_msg_size = 0x1200;
    rsp->local_context.capability.transport_header_size = LIBSPDM_TEST_TRANSPORT_HEADER_SIZE;
    rsp->local_context.capability.transport_tail_size = LIBSPDM_TEST_TRANSPORT_TAIL_SIZE;
    rsp->connection_info.version = SPDM_MESSAGE_VERSION_11 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    rsp->connection_info.connection_state = LIBSPDM_CONNECTION_STATE_NEGOTIATED;
    rsp->connection_info.capability.flags = g_cap_hitc_req;
    rsp->connection_info.algorithm.base_hash_algo    = HASH_ALGO;
    rsp->connection_info.algorithm.base_asym_algo    = ASYM_ALGO;
    rsp->connection_info.algorithm.dhe_named_group   = DHE_GROUP;
    rsp->connection_info.algorithm.aead_cipher_suite = AEAD_SUITE;
    rsp->connection_info.algorithm.key_schedule      = KEY_SCHED;
    rsp->connection_info.algorithm.req_base_asym_alg = REQ_ASYM;
    rsp->connection_info.algorithm.measurement_hash_algo = MEAS_HASH;
    rsp->connection_info.algorithm.other_params_support  = SPDM_ALGORITHMS_OPAQUE_DATA_FORMAT_1;
    void *cd = NULL; size_t cs = 0;
    void *hd = NULL; size_t hs = 0;
    if (!libspdm_read_responder_public_certificate_chain(HASH_ALGO, ASYM_ALGO, &cd, &cs, &hd, &hs)) {
        fprintf(stderr, "ERROR: cert read failed\n"); return 1;
    }
    (void)hd; (void)hs;
    rsp->local_context.local_cert_chain_provision[0] = cd;
    rsp->local_context.local_cert_chain_provision_size[0] = cs;
    libspdm_register_transport_layer_func(rsp, 0x1200,
        LIBSPDM_TEST_TRANSPORT_HEADER_SIZE, LIBSPDM_TEST_TRANSPORT_TAIL_SIZE,
        libspdm_transport_test_encode_message, libspdm_transport_test_decode_message);
    libspdm_register_device_io_func(rsp, rsp_send_stub, rsp_recv_stub);
    libspdm_register_device_buffer_func(rsp, LOOPBACK_BUF_SIZE, LOOPBACK_BUF_SIZE,
        rsp_acq_send, rsp_rel_send, rsp_acq_recv, rsp_rel_recv);
    sc_sz = libspdm_get_sizeof_required_scratch_buffer(rsp);
    libspdm_set_scratch_buffer(rsp, malloc(sc_sz), sc_sz);
    g_lb.responder = rsp;

    /* Step 1: KEY_EXCHANGE session S1 (HITC=TRUE) */
    uint32_t session1_id = 0;
    uint8_t heartbeat = 0, req_slot = 0, mhash[64] = {0};
    printf("[Step 1] req KEY_EXCHANGE session S1 (HITC=TRUE)\n");
    libspdm_return_t s = libspdm_send_receive_key_exchange(
        req, SPDM_KEY_EXCHANGE_REQUEST_NO_MEASUREMENT_SUMMARY_HASH, 0, 0,
        &session1_id, &heartbeat, &req_slot, mhash);
    if (LIBSPDM_STATUS_IS_ERROR(s)) {
        fprintf(stderr, "SETUP FAILED: session S1 KEY_EXCHANGE failed: 0x%x\n", (unsigned)s);
        return 1;
    }
    uint32_t latest_after_s1 = rsp->latest_session_id;
    printf("       session1_id=0x%x, responder->latest_session_id=0x%x\n",
           session1_id, latest_after_s1);

    /* Step 2: KEY_EXCHANGE session S2 (HITC=TRUE) — overwrites latest_session_id */
    uint32_t session2_id = 0;
    heartbeat = 0; req_slot = 0;
    memset(mhash, 0, sizeof(mhash));
    printf("[Step 2] req KEY_EXCHANGE session S2 (HITC=TRUE) — overwrites latest_session_id\n");
    s = libspdm_send_receive_key_exchange(
        req, SPDM_KEY_EXCHANGE_REQUEST_NO_MEASUREMENT_SUMMARY_HASH, 0, 0,
        &session2_id, &heartbeat, &req_slot, mhash);
    if (LIBSPDM_STATUS_IS_ERROR(s)) {
        fprintf(stderr, "SETUP FAILED: session S2 KEY_EXCHANGE failed: 0x%x\n", (unsigned)s);
        return 1;
    }
    uint32_t latest_after_s2 = rsp->latest_session_id;
    printf("       session2_id=0x%x, responder->latest_session_id=0x%x\n",
           session2_id, latest_after_s2);

    /* Verify the BUG CONDITION exists */
    if (latest_after_s2 == session2_id && session2_id != session1_id) {
        printf("\n[BUG CONDITION] latest_session_id=0x%x (S2), NOT session1_id=0x%x\n",
               latest_after_s2, session1_id);
        printf("               req1's FINISH (HITC, cleartext) will use latest_session_id=S2!\n\n");
    }

    /* Step 3: FINISH for session S1 (HITC path, cleartext, no session_id in header) */
    printf("[Step 3] FINISH for session S1 (HITC cleartext path)\n");
    printf("         responder->latest_session_id = 0x%x (S2, not S1=0x%x)\n",
           latest_after_s2, session1_id);
    printf("         libspdm_rsp_finish_rsp.c:484: session_id = latest_session_id = 0x%x\n",
           latest_after_s2);

    s = libspdm_send_receive_finish(req, session1_id, 0);

    if (LIBSPDM_STATUS_IS_ERROR(s)) {
        printf("\n[BUG CONFIRMED] FINISH for S1 failed: 0x%x\n", (unsigned)s);
        printf("  Responder processed FINISH using S2's context (latest_session_id=0x%x)\n",
               latest_after_s2);
        printf("  S1's HMAC (keyed with S1 handshake secret) was verified against S2's context\n");
        printf("  → HMAC verification failed → session S1 can never be established\n");
        printf("\n  ROOT CAUSE: libspdm_com_context_data_session.c:221 overwrites\n");
        printf("  latest_session_id unconditionally; libspdm_rsp_finish_rsp.c:484 uses it\n");
        printf("  for HITC FINISH (last_spdm_request_session_id_valid=false path).\n");
        printf("\n  IMPACT: An attacker who can initiate a concurrent KEY_EXCHANGE at the\n");
        printf("  right moment prevents any HITC session from being established (DoS).\n");
        return 0;
    } else {
        printf("\nUNEXPECTED: S1 FINISH succeeded. Session IDs: S1=0x%x, S2=0x%x\n",
               session1_id, session2_id);
        if (session1_id == session2_id) {
            printf("NOTE: S1 and S2 got the same session_id — cannot distinguish them.\n");
            printf("Try with LIBSPDM_MAX_SESSION_COUNT >= 2 and distinct DHE keys.\n");
        }
        return 1;
    }
}
