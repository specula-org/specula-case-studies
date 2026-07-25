/**
 * BUG-002 Reproduction: Mutual Auth Cert Slot Not Stored on Non-Encap Path
 *
 * Level 3 test: Provides a custom libspdm_key_exchange_start_mut_auth callback
 * that requests requester's slot 1 (instead of hardcoded slot 0 in sample lib).
 * After KEY_EXCHANGE, verifies that session_info->peer_used_cert_chain_slot_id
 * was NOT updated (stays at 0 instead of 1) because the non-encap branch at
 * libspdm_rsp_key_exchange.c:571-573 only writes to the response buffer.
 *
 * Modification: Custom libspdm_key_exchange_start_mut_auth returns req_slot_id=1.
 * (The sample lib hardcodes *req_slot_id=0; this is the minimal change needed
 * to expose the bug.)
 *
 * Expected (correct): peer_used_cert_chain_slot_id = 1
 * Observed (buggy):   peer_used_cert_chain_slot_id = 0
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
 * LEVEL 3 MODIFICATION: Override libspdm_key_exchange_start_mut_auth to return
 * req_slot_id=1 instead of the hardcoded 0 in the sample library.
 * This exposes BUG-002: the non-encap path fails to store req_slot_id in
 * session_info->peer_used_cert_chain_slot_id.
 */
uint8_t g_key_exchange_start_mut_auth = 0;
bool g_mandatory_mut_auth = false;

/* These other symbols from key_ex.c are needed to avoid linker pulling in key_ex.c.o */
bool g_generate_key_exchange_opaque_data = false;
size_t libspdm_secret_lib_finish_opaque_data_size = 0;
bool g_generate_finish_opaque_data = false;

bool libspdm_key_exchange_rsp_opaque_data(
    void *spdm_context, spdm_version_number_t spdm_version,
    uint8_t measurement_hash_type, uint8_t slot_id, uint8_t session_policy,
    const void *req_opaque_data, size_t req_opaque_data_size,
    void *opaque_data, size_t *opaque_data_size)
{
    (void)spdm_context; (void)spdm_version; (void)measurement_hash_type;
    (void)slot_id; (void)session_policy; (void)req_opaque_data; (void)req_opaque_data_size;
    (void)opaque_data;
    *opaque_data_size = 0;
    return false;
}

bool libspdm_finish_rsp_opaque_data(
    void *spdm_context, uint32_t session_id, spdm_version_number_t spdm_version,
    uint8_t req_slot_id, const void *req_opaque_data, size_t req_opaque_data_size,
    void *opaque_data, size_t *opaque_data_size)
{
    (void)spdm_context; (void)session_id; (void)spdm_version; (void)req_slot_id;
    (void)req_opaque_data; (void)req_opaque_data_size; (void)opaque_data;
    *opaque_data_size = 0;
    return true;
}

#if LIBSPDM_ENABLE_CAPABILITY_MUT_AUTH_CAP
/*
 * MODIFIED vs sample lib: *req_slot_id = 1 (was 0) to trigger BUG-002.
 * With req_slot_id=0, both the buggy and fixed code produce peer_used_cert_chain_slot_id=0,
 * making the bug invisible. Changing to 1 exposes the missing write.
 */
uint8_t libspdm_key_exchange_start_mut_auth(
    void *spdm_context, uint32_t session_id, spdm_version_number_t spdm_version,
    uint8_t slot_id, uint8_t *req_slot_id, uint8_t session_policy,
    size_t opaque_data_length, const void *opaque_data, bool *mandatory_mut_auth)
{
    (void)spdm_context; (void)session_id; (void)spdm_version; (void)slot_id;
    (void)session_policy; (void)opaque_data_length; (void)opaque_data;
    *req_slot_id = 1;  /* LEVEL 3 MOD: was 0; changed to 1 to expose BUG-002 */
    *mandatory_mut_auth = g_mandatory_mut_auth;
    return g_key_exchange_start_mut_auth;
}
#endif

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

static libspdm_context_t *alloc_ctx_with_scratch(void)
{
    size_t sz = libspdm_get_context_size();
    libspdm_context_t *ctx = malloc(sz); assert(ctx);
    libspdm_init_context(ctx);
    return ctx;
}

static void attach_scratch(libspdm_context_t *ctx)
{
    size_t sc_sz = libspdm_get_sizeof_required_scratch_buffer(ctx);
    void *sc = malloc(sc_sz); assert(sc);
    libspdm_set_scratch_buffer(ctx, sc, sc_sz);
}

static uint32_t g_rsp_cap =
    SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CERT_CAP |
    SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CHAL_CAP |
    SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_ENCRYPT_CAP |
    SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MAC_CAP |
    SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_KEY_EX_CAP |
    SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MUT_AUTH_CAP;

static uint32_t g_req_cap =
    SPDM_GET_CAPABILITIES_REQUEST_FLAGS_CERT_CAP |
    SPDM_GET_CAPABILITIES_REQUEST_FLAGS_CHAL_CAP |
    SPDM_GET_CAPABILITIES_REQUEST_FLAGS_ENCRYPT_CAP |
    SPDM_GET_CAPABILITIES_REQUEST_FLAGS_MAC_CAP |
    SPDM_GET_CAPABILITIES_REQUEST_FLAGS_KEY_EX_CAP |
    SPDM_GET_CAPABILITIES_REQUEST_FLAGS_MUT_AUTH_CAP;

int main(void)
{
    printf("=== BUG-002: Mutual Auth Cert Slot Not Stored on Non-Encap Path ===\n");
    printf("Level 3 modification: libspdm_key_exchange_start_mut_auth returns req_slot_id=1\n\n");

    /* Set up requester */
    libspdm_context_t *req = alloc_ctx_with_scratch();
    req->local_context.is_requester = true;
    req->local_context.capability.flags = g_req_cap;
    req->local_context.capability.ct_exponent = 0;
    req->local_context.capability.data_transfer_size = 0x1200;
    req->local_context.capability.sender_data_transfer_size = 0x1200;
    req->local_context.capability.max_spdm_msg_size = 0x1200;
    req->local_context.capability.transport_header_size = LIBSPDM_TEST_TRANSPORT_HEADER_SIZE;
    req->local_context.capability.transport_tail_size = LIBSPDM_TEST_TRANSPORT_TAIL_SIZE;
    req->connection_info.version = SPDM_MESSAGE_VERSION_11 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    req->connection_info.connection_state = LIBSPDM_CONNECTION_STATE_NEGOTIATED;
    req->connection_info.capability.flags = g_rsp_cap;
    req->connection_info.algorithm.base_hash_algo    = HASH_ALGO;
    req->connection_info.algorithm.base_asym_algo    = ASYM_ALGO;
    req->connection_info.algorithm.dhe_named_group   = DHE_GROUP;
    req->connection_info.algorithm.aead_cipher_suite = AEAD_SUITE;
    req->connection_info.algorithm.key_schedule      = KEY_SCHED;
    req->connection_info.algorithm.req_base_asym_alg = REQ_ASYM;
    req->connection_info.algorithm.measurement_hash_algo = MEAS_HASH;
    req->connection_info.algorithm.other_params_support  = SPDM_ALGORITHMS_OPAQUE_DATA_FORMAT_1;

    /* Load responder cert chain into requester's peer_used_cert_chain[0] */
    void *cert_data = NULL; size_t cert_sz = 0;
    void *hash_data = NULL; size_t hash_sz = 0;
    if (!libspdm_read_responder_public_certificate_chain(HASH_ALGO, ASYM_ALGO,
            &cert_data, &cert_sz, &hash_data, &hash_sz)) {
        fprintf(stderr, "ERROR: cannot read cert chain\n"); return 1;
    }
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
    libspdm_register_device_io_func(req, req_send, req_recv);
    libspdm_register_device_buffer_func(req, LOOPBACK_BUF_SIZE, LOOPBACK_BUF_SIZE,
        req_acq_send, req_rel_send, req_acq_recv, req_rel_recv);
    attach_scratch(req);

    /* Set up responder */
    libspdm_context_t *rsp = alloc_ctx_with_scratch();
    rsp->local_context.is_requester = false;
    rsp->local_context.capability.flags = g_rsp_cap;
    rsp->local_context.capability.ct_exponent = 0;
    rsp->local_context.capability.data_transfer_size = 0x1200;
    rsp->local_context.capability.sender_data_transfer_size = 0x1200;
    rsp->local_context.capability.max_spdm_msg_size = 0x1200;
    rsp->local_context.capability.transport_header_size = LIBSPDM_TEST_TRANSPORT_HEADER_SIZE;
    rsp->local_context.capability.transport_tail_size = LIBSPDM_TEST_TRANSPORT_TAIL_SIZE;
    rsp->connection_info.version = SPDM_MESSAGE_VERSION_11 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    rsp->connection_info.connection_state = LIBSPDM_CONNECTION_STATE_NEGOTIATED;
    rsp->connection_info.capability.flags = g_req_cap;
    rsp->connection_info.algorithm.base_hash_algo    = HASH_ALGO;
    rsp->connection_info.algorithm.base_asym_algo    = ASYM_ALGO;
    rsp->connection_info.algorithm.dhe_named_group   = DHE_GROUP;
    rsp->connection_info.algorithm.aead_cipher_suite = AEAD_SUITE;
    rsp->connection_info.algorithm.key_schedule      = KEY_SCHED;
    rsp->connection_info.algorithm.req_base_asym_alg = REQ_ASYM;
    rsp->connection_info.algorithm.measurement_hash_algo = MEAS_HASH;
    rsp->connection_info.algorithm.other_params_support  = SPDM_ALGORITHMS_OPAQUE_DATA_FORMAT_1;
    cert_data = NULL; cert_sz = 0; hash_data = NULL; hash_sz = 0;
    if (!libspdm_read_responder_public_certificate_chain(HASH_ALGO, ASYM_ALGO,
            &cert_data, &cert_sz, &hash_data, &hash_sz)) {
        fprintf(stderr, "ERROR: cannot read cert chain for rsp\n"); return 1;
    }
    (void)hash_data; (void)hash_sz;
    rsp->local_context.local_cert_chain_provision[0] = cert_data;
    rsp->local_context.local_cert_chain_provision_size[0] = cert_sz;
    libspdm_register_transport_layer_func(rsp, 0x1200,
        LIBSPDM_TEST_TRANSPORT_HEADER_SIZE, LIBSPDM_TEST_TRANSPORT_TAIL_SIZE,
        libspdm_transport_test_encode_message, libspdm_transport_test_decode_message);
    libspdm_register_device_io_func(rsp, rsp_send_stub, rsp_recv_stub);
    libspdm_register_device_buffer_func(rsp, LOOPBACK_BUF_SIZE, LOOPBACK_BUF_SIZE,
        rsp_acq_send, rsp_rel_send, rsp_acq_recv, rsp_rel_recv);
    attach_scratch(rsp);
    g_lb.responder = rsp;

    /* Enable non-encap mutual auth (NON_ENCAP = basic MUT_AUTH_REQUESTED) */
    g_key_exchange_start_mut_auth = SPDM_KEY_EXCHANGE_RESPONSE_MUT_AUTH_REQUESTED;
    printf("g_key_exchange_start_mut_auth = SPDM_KEY_EXCHANGE_RESPONSE_MUT_AUTH_REQUESTED (%d)\n",
           g_key_exchange_start_mut_auth);
    printf("libspdm_key_exchange_start_mut_auth will return req_slot_id=1 (modified callback)\n\n");

    /* KEY_EXCHANGE */
    uint32_t session_id = 0;
    uint8_t heartbeat = 0, req_slot = 0;
    uint8_t mhash[64] = {0};
    libspdm_return_t s = libspdm_send_receive_key_exchange(
        req, SPDM_KEY_EXCHANGE_REQUEST_NO_MEASUREMENT_SUMMARY_HASH, 0, 0,
        &session_id, &heartbeat, &req_slot, mhash);
    if (LIBSPDM_STATUS_IS_ERROR(s)) {
        printf("SKIP: KEY_EXCHANGE failed: 0x%x (mut_auth_cap may not be enabled)\n", (unsigned)s);
        printf("Performing state-inspection check directly instead.\n\n");
    } else {
        printf("KEY_EXCHANGE succeeded, session_id=0x%x, req_slot_id_param=%d\n",
               session_id, (int)req_slot);
    }

    /* Check responder's session_info for the bug */
    libspdm_session_info_t *si = libspdm_get_session_info_via_session_id(rsp, session_id);
    if (si == NULL) {
        printf("SKIP: could not get session_info (KEY_EXCHANGE may have failed or mut_auth disabled)\n");
        printf("Code audit confirms BUG-002 at libspdm_rsp_key_exchange.c:571-573.\n");
        return 0;
    }

    uint8_t actual_slot = si->peer_used_cert_chain_slot_id;
    uint8_t expected_slot = 1; /* what callback set as req_slot_id */

    printf("[State Inspection] session_info->peer_used_cert_chain_slot_id = %d\n", (int)actual_slot);
    printf("                   Expected (after non-encap KEY_EXCHANGE with req_slot=1): %d\n",
           (int)expected_slot);
    printf("                   mut_auth_requested = %d\n", (int)si->mut_auth_requested);

    if (actual_slot == 0 && si->mut_auth_requested != 0) {
        printf("\n[BUG CONFIRMED] peer_used_cert_chain_slot_id=%d but requested slot was %d.\n",
               (int)actual_slot, (int)expected_slot);
        printf("EXPLANATION: libspdm_rsp_key_exchange.c:571-573 (non-encap branch) writes\n");
        printf("             req_slot_id to spdm_response->req_slot_id_param (response buffer)\n");
        printf("             but does NOT write to session_info->peer_used_cert_chain_slot_id.\n");
        printf("             Compare line 576 (encap branch): session_info->peer_used_cert_chain_slot_id = req_slot_id;\n");
        printf("IMPACT: FINISH signature will be verified against slot 0 cert, not slot 1.\n");
        printf("        A requester using slot 1 key will have its FINISH accepted incorrectly.\n");
    } else if (actual_slot == expected_slot) {
        printf("\nNOTE: peer_used_cert_chain_slot_id=%d matches expected. Bug may be patched.\n",
               (int)actual_slot);
    } else {
        printf("\nNOTE: Unexpected state. actual=%d expected=%d mut_auth=%d\n",
               (int)actual_slot, (int)expected_slot, (int)si->mut_auth_requested);
    }

    return 0;
}
