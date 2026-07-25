/**
 * BUG-003 Reproduction: Session Slot Leak on Key-Derivation Failure
 *
 * Level 3 test: Uses --wrap=libspdm_calculate_th2_hash to intercept the TH2
 * hash call during FINISH processing and return false (simulating a crypto
 * failure). Verifies that after the failure, the session slot is still
 * occupied (not freed), causing the next KEY_EXCHANGE allocation to fail
 * when LIBSPDM_MAX_SESSION_COUNT slots are exhausted.
 *
 * Root cause: libspdm_rsp_finish_rsp.c:740-752 returns an error without
 * calling libspdm_free_session_id, unlike libspdm_rsp_key_exchange.c which
 * correctly calls libspdm_free_session_id on ALL failure paths.
 *
 * Observable: After TH2 hash failure, session slot is NOT freed. If all
 * MAX_SESSION_COUNT slots are in HANDSHAKING state, new KEY_EXCHANGE fails.
 *
 * Build requires: gcc WITHOUT -flto (so --wrap intercepts the symbol)
 *                 -Wl,--wrap=libspdm_calculate_th2_hash
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

/*
 * --wrap=libspdm_calculate_th2_hash interception.
 * When g_th2_fail_on_next is set, the VERY NEXT call returns false.
 * Build without -flto so --wrap intercepts the symbol (LTO inlines it away).
 */
static bool g_th2_fail_on_next = false;
static bool g_th2_wrap_fired   = false;

extern bool __real_libspdm_calculate_th2_hash(void *spdm_context,
                                               void *spdm_session_info,
                                               bool is_requester,
                                               uint8_t *th2_hash_data);

bool __wrap_libspdm_calculate_th2_hash(void *spdm_context,
                                        void *spdm_session_info,
                                        bool is_requester,
                                        uint8_t *th2_hash_data)
{
    if (g_th2_fail_on_next) {
        g_th2_fail_on_next = false;
        g_th2_wrap_fired   = true;
        printf("  [WRAP] libspdm_calculate_th2_hash: FORCED FAILURE\n");
        return false;
    }
    return __real_libspdm_calculate_th2_hash(spdm_context, spdm_session_info,
                                              is_requester, th2_hash_data);
}

/* --- Loopback state --- */

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

static libspdm_return_t req_send_fn(void *c, size_t sz, const void *d, uint64_t t)
{ (void)c;(void)t; assert(sz<=sizeof(g_lb.req_msg)); memcpy(g_lb.req_msg,d,sz); g_lb.req_msg_size=sz; return LIBSPDM_STATUS_SUCCESS; }

static libspdm_return_t req_recv_fn(void *ctx, size_t *sz, void **data, uint64_t to)
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

static libspdm_context_t *make_req(void)
{
    size_t sz = libspdm_get_context_size();
    libspdm_context_t *ctx = malloc(sz); assert(ctx);
    libspdm_init_context(ctx);
    ctx->local_context.is_requester = true;
    ctx->local_context.capability.flags = g_req_cap;
    ctx->local_context.capability.ct_exponent = 0;
    ctx->local_context.capability.data_transfer_size = 0x1200;
    ctx->local_context.capability.sender_data_transfer_size = 0x1200;
    ctx->local_context.capability.max_spdm_msg_size = 0x1200;
    ctx->local_context.capability.transport_header_size = LIBSPDM_TEST_TRANSPORT_HEADER_SIZE;
    ctx->local_context.capability.transport_tail_size = LIBSPDM_TEST_TRANSPORT_TAIL_SIZE;
    ctx->connection_info.version = SPDM_MESSAGE_VERSION_11 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    ctx->connection_info.connection_state = LIBSPDM_CONNECTION_STATE_NEGOTIATED;
    ctx->connection_info.capability.flags = g_rsp_cap;
    ctx->connection_info.algorithm.base_hash_algo    = HASH_ALGO;
    ctx->connection_info.algorithm.base_asym_algo    = ASYM_ALGO;
    ctx->connection_info.algorithm.dhe_named_group   = DHE_GROUP;
    ctx->connection_info.algorithm.aead_cipher_suite = AEAD_SUITE;
    ctx->connection_info.algorithm.key_schedule      = KEY_SCHED;
    ctx->connection_info.algorithm.req_base_asym_alg = REQ_ASYM;
    ctx->connection_info.algorithm.measurement_hash_algo = MEAS_HASH;
    ctx->connection_info.algorithm.other_params_support  = SPDM_ALGORITHMS_OPAQUE_DATA_FORMAT_1;

    void *cert_data = NULL; size_t cert_sz = 0;
    void *hash_data = NULL; size_t hash_sz = 0;
    libspdm_read_responder_public_certificate_chain(HASH_ALGO, ASYM_ALGO,
        &cert_data, &cert_sz, &hash_data, &hash_sz);
    (void)hash_data; (void)hash_sz;
#if LIBSPDM_RECORD_TRANSCRIPT_DATA_SUPPORT
    ctx->connection_info.peer_used_cert_chain[0].buffer_size = cert_sz;
    memcpy(ctx->connection_info.peer_used_cert_chain[0].buffer, cert_data, cert_sz);
    free(cert_data);
#else
    libspdm_hash_all(HASH_ALGO, cert_data, cert_sz,
                     ctx->connection_info.peer_used_cert_chain[0].buffer_hash);
    ctx->connection_info.peer_used_cert_chain[0].buffer_hash_size =
        libspdm_get_hash_size(HASH_ALGO);
    libspdm_get_leaf_cert_public_key_from_cert_chain(HASH_ALGO, ASYM_ALGO, cert_data, cert_sz,
        &ctx->connection_info.peer_used_cert_chain[0].leaf_cert_public_key);
    free(cert_data);
#endif
    libspdm_register_transport_layer_func(ctx, 0x1200,
        LIBSPDM_TEST_TRANSPORT_HEADER_SIZE, LIBSPDM_TEST_TRANSPORT_TAIL_SIZE,
        libspdm_transport_test_encode_message, libspdm_transport_test_decode_message);
    libspdm_register_device_io_func(ctx, req_send_fn, req_recv_fn);
    libspdm_register_device_buffer_func(ctx, LOOPBACK_BUF_SIZE, LOOPBACK_BUF_SIZE,
        req_acq_send, req_rel_send, req_acq_recv, req_rel_recv);

    size_t sc_sz = libspdm_get_sizeof_required_scratch_buffer(ctx);
    void *sc = malloc(sc_sz); assert(sc);
    libspdm_set_scratch_buffer(ctx, sc, sc_sz);
    return ctx;
}

static libspdm_context_t *make_rsp(void)
{
    size_t sz = libspdm_get_context_size();
    libspdm_context_t *ctx = malloc(sz); assert(ctx);
    libspdm_init_context(ctx);
    ctx->local_context.is_requester = false;
    ctx->local_context.capability.flags = g_rsp_cap;
    ctx->local_context.capability.ct_exponent = 0;
    ctx->local_context.capability.data_transfer_size = 0x1200;
    ctx->local_context.capability.sender_data_transfer_size = 0x1200;
    ctx->local_context.capability.max_spdm_msg_size = 0x1200;
    ctx->local_context.capability.transport_header_size = LIBSPDM_TEST_TRANSPORT_HEADER_SIZE;
    ctx->local_context.capability.transport_tail_size = LIBSPDM_TEST_TRANSPORT_TAIL_SIZE;
    ctx->connection_info.version = SPDM_MESSAGE_VERSION_11 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    ctx->connection_info.connection_state = LIBSPDM_CONNECTION_STATE_NEGOTIATED;
    ctx->connection_info.capability.flags = g_req_cap;
    ctx->connection_info.algorithm.base_hash_algo    = HASH_ALGO;
    ctx->connection_info.algorithm.base_asym_algo    = ASYM_ALGO;
    ctx->connection_info.algorithm.dhe_named_group   = DHE_GROUP;
    ctx->connection_info.algorithm.aead_cipher_suite = AEAD_SUITE;
    ctx->connection_info.algorithm.key_schedule      = KEY_SCHED;
    ctx->connection_info.algorithm.req_base_asym_alg = REQ_ASYM;
    ctx->connection_info.algorithm.measurement_hash_algo = MEAS_HASH;
    ctx->connection_info.algorithm.other_params_support  = SPDM_ALGORITHMS_OPAQUE_DATA_FORMAT_1;

    void *cert_data = NULL; size_t cert_sz = 0;
    void *hash_data = NULL; size_t hash_sz = 0;
    libspdm_read_responder_public_certificate_chain(HASH_ALGO, ASYM_ALGO,
        &cert_data, &cert_sz, &hash_data, &hash_sz);
    (void)hash_data; (void)hash_sz;
    ctx->local_context.local_cert_chain_provision[0] = cert_data;
    ctx->local_context.local_cert_chain_provision_size[0] = cert_sz;
    libspdm_register_transport_layer_func(ctx, 0x1200,
        LIBSPDM_TEST_TRANSPORT_HEADER_SIZE, LIBSPDM_TEST_TRANSPORT_TAIL_SIZE,
        libspdm_transport_test_encode_message, libspdm_transport_test_decode_message);
    libspdm_register_device_io_func(ctx, rsp_send_stub, rsp_recv_stub);
    libspdm_register_device_buffer_func(ctx, LOOPBACK_BUF_SIZE, LOOPBACK_BUF_SIZE,
        rsp_acq_send, rsp_rel_send, rsp_acq_recv, rsp_rel_recv);

    size_t sc_sz = libspdm_get_sizeof_required_scratch_buffer(ctx);
    void *sc = malloc(sc_sz); assert(sc);
    libspdm_set_scratch_buffer(ctx, sc, sc_sz);
    return ctx;
}

/* Count session slots that are NOT at INVALID_SESSION_ID */
static int count_occupied_sessions(libspdm_context_t *rsp)
{
    int count = 0;
    for (int i = 0; i < LIBSPDM_MAX_SESSION_COUNT; i++) {
        if (rsp->session_info[i].session_id != INVALID_SESSION_ID)
            count++;
    }
    return count;
}

/* Return session state: 0=not_started, 1=handshaking, 2=established, -1=not found */
static int get_session_state(libspdm_context_t *rsp, uint32_t session_id)
{
    libspdm_session_info_t *si = libspdm_get_session_info_via_session_id(rsp, session_id);
    if (!si) return -1;
    libspdm_secured_message_context_t *smc =
        (libspdm_secured_message_context_t *)si->secured_message_context;
    return (int)libspdm_secured_message_get_session_state(smc);
}

int main(void)
{
    printf("=== BUG-003: Session Slot Leak on Key-Derivation Failure ===\n");
    printf("LIBSPDM_MAX_SESSION_COUNT = %d\n\n", (int)LIBSPDM_MAX_SESSION_COUNT);

    libspdm_context_t *rsp = make_rsp();
    g_lb.responder = rsp;

    /* Step 1: Do KEY_EXCHANGE to put a session in HANDSHAKING state */
    libspdm_context_t *req1 = make_req();
    uint32_t session1_id = 0;
    uint8_t heartbeat = 0, req_slot = 0;
    uint8_t mhash[64] = {0};
    libspdm_return_t s = libspdm_send_receive_key_exchange(
        req1, SPDM_KEY_EXCHANGE_REQUEST_NO_MEASUREMENT_SUMMARY_HASH, 0, 0,
        &session1_id, &heartbeat, &req_slot, mhash);
    if (LIBSPDM_STATUS_IS_ERROR(s)) {
        fprintf(stderr, "SETUP FAILED: KEY_EXCHANGE failed: 0x%x\n", (unsigned)s); return 1;
    }
    printf("[Step 1] KEY_EXCHANGE succeeded, session_id=0x%x\n", session1_id);
    printf("         Responder slots: %d/%d, state=%d (1=HANDSHAKING)\n",
           count_occupied_sessions(rsp), (int)LIBSPDM_MAX_SESSION_COUNT,
           get_session_state(rsp, session1_id));

    /* Step 2: Trigger FINISH with forced TH2 hash failure */
    g_th2_fail_on_next = true;
    g_th2_wrap_fired   = false;
    s = libspdm_send_receive_finish(req1, session1_id, 0);
    printf("[Step 2] FINISH result: 0x%x (%s)\n",
           (unsigned)s, LIBSPDM_STATUS_IS_ERROR(s) ? "ERROR" : "SUCCESS");
    printf("         --wrap fired:   %s\n", g_th2_wrap_fired ? "YES" : "NO");
    printf("         Slots after:    %d/%d\n",
           count_occupied_sessions(rsp), (int)LIBSPDM_MAX_SESSION_COUNT);
    int state_after = get_session_state(rsp, session1_id);
    printf("         Session state:  %d (%s)\n", state_after,
           state_after == 1 ? "HANDSHAKING (leaked)" :
           state_after == 2 ? "ESTABLISHED (finish succeeded)" :
           state_after < 0  ? "NOT FOUND (freed correctly)" : "UNKNOWN");

    if (!g_th2_wrap_fired) {
        printf("\n[SKIP] --wrap did not intercept libspdm_calculate_th2_hash.\n");
        printf("  This means LTO inlined the function before --wrap could replace it.\n");
        printf("  Build test_bug3 without -flto: the run_repro.sh script already does this.\n");
        printf("  Verify: nm -C build_trace/lib/libspdm_responder_lib.a | grep th2_hash\n");
        return 1;
    }

    if (!LIBSPDM_STATUS_IS_ERROR(s)) {
        printf("\n[UNEXPECTED] FINISH succeeded despite forced TH2 failure.\n");
        printf("  The wrap fired but the error did not propagate. Check the call path.\n");
        return 1;
    }

    /* The wrap fired AND FINISH failed. Check for the bug: is the slot still occupied? */
    int slots_after = count_occupied_sessions(rsp);
    if (slots_after > 0 && state_after == 1 /* HANDSHAKING */) {
        printf("\n[BUG CONFIRMED] Session slot NOT freed after TH2 hash failure!\n");
        printf("  session_id=0x%x remains in HANDSHAKING state (slot not released).\n", session1_id);
        printf("\n  ROOT CAUSE: libspdm_rsp_finish_rsp.c:740-752 returns error without\n");
        printf("  calling libspdm_free_session_id(spdm_context, session_id).\n");
        printf("  Compare: libspdm_rsp_key_exchange.c calls libspdm_free_session_id on\n");
        printf("  ALL failure paths (lines 559, 564, 603, 615, 630, 650, 663...).\n");

        /* Step 3: Fill remaining slots and verify the zombie session blocks new connections */
        printf("\n[Step 3] Filling remaining %d session slots...\n",
               (int)LIBSPDM_MAX_SESSION_COUNT - 1);
        int filled = 0;
        libspdm_context_t *filler_reqs[LIBSPDM_MAX_SESSION_COUNT];
        uint32_t filler_ids[LIBSPDM_MAX_SESSION_COUNT];
        for (int i = 0; i < LIBSPDM_MAX_SESSION_COUNT - 1; i++) {
            filler_reqs[i] = make_req();
            filler_ids[i] = 0;
            heartbeat = 0; req_slot = 0;
            memset(mhash, 0, sizeof(mhash));
            s = libspdm_send_receive_key_exchange(
                filler_reqs[i], SPDM_KEY_EXCHANGE_REQUEST_NO_MEASUREMENT_SUMMARY_HASH, 0, 0,
                &filler_ids[i], &heartbeat, &req_slot, mhash);
            if (LIBSPDM_STATUS_IS_ERROR(s)) break;
            filled++;
            printf("         Filled slot %d: session_id=0x%x\n", i + 1, filler_ids[i]);
        }
        printf("         Total occupied: %d/%d (all slots full)\n",
               count_occupied_sessions(rsp), (int)LIBSPDM_MAX_SESSION_COUNT);

        /* Try one more KEY_EXCHANGE — must fail if all slots taken */
        libspdm_context_t *extra_req = make_req();
        uint32_t extra_id = 0;
        heartbeat = 0; req_slot = 0;
        memset(mhash, 0, sizeof(mhash));
        s = libspdm_send_receive_key_exchange(
            extra_req, SPDM_KEY_EXCHANGE_REQUEST_NO_MEASUREMENT_SUMMARY_HASH, 0, 0,
            &extra_id, &heartbeat, &req_slot, mhash);
        printf("[Step 4] Extra KEY_EXCHANGE: 0x%x (%s)\n",
               (unsigned)s, LIBSPDM_STATUS_IS_ERROR(s) ? "FAILED (expected)" : "SUCCEEDED");
        if (LIBSPDM_STATUS_IS_ERROR(s)) {
            printf("[DoS CONFIRMED] Zombie session from failed FINISH blocks new connections.\n");
        }
    } else if (slots_after == 0 || state_after < 0) {
        printf("\n[PATCHED or DIFFERENT BEHAVIOR] Session freed after TH2 failure.\n");
        printf("  The bug may have been fixed, or a different code path ran.\n");
    } else {
        printf("\n[UNEXPECTED STATE] slots=%d, state=%d\n", slots_after, state_after);
    }

    return 0;
}
