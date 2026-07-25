/**
 * BUG-F1: base_asym_algo Selected Without Enabling Capability
 *
 * Root cause: libspdm_rsp_algorithms.c:739-742 sets base_asym_sel unconditionally
 * via libspdm_prioritize_algorithm(). Lines 927-950 then validate that base_asym != 0
 * WHEN CERT/CHAL/MEAS_CAP_SIG/KEY_EX is enabled — but never zeroes base_asym_sel
 * when NONE of those capabilities are set.
 *
 * If both sides advertise a non-zero base_asym_algo but no asym-requiring capability
 * (CERT, CHAL, MEAS_CAP_SIG, KEY_EX) is enabled, the ALGORITHMS response will
 * contain base_asym_sel != 0 even though no capability requires asymmetric algorithms.
 *
 * Historical note: Fix #1189 added the "must be non-zero when needed" check (lines
 * 927-950) but did not add the complementary "must be zero when not needed" check.
 *
 * Escalation: Level 0 (Pure black-box — SPDM v1.0 scenario with no capabilities
 * and non-zero base_asym_algo on both sides). The full VCA handshake completes
 * and the incoherent state is directly observable.
 *
 * Observable outcome: After NEGOTIATED state:
 *   connection_info.algorithm.base_asym_algo = RSAPSS_3072 (non-zero)
 *   connection_info.capability.flags = 0 (no CERT/CHAL/MEAS_SIG/KEY_EX)
 * This is an incoherent negotiated state — downstream code that checks
 * "is base_asym_algo set?" as a proxy for "do we have asymmetric capabilities?"
 * would incorrectly attempt asymmetric operations.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>

#include "hal/base.h"
#include "hal/library/memlib.h"
#include "library/spdm_requester_lib.h"
#include "library/spdm_responder_lib.h"
#include "library/spdm_common_lib.h"
#include "library/spdm_transport_test_lib.h"
#include "internal/libspdm_common_lib.h"
#include "internal/libspdm_requester_lib.h"
#include "internal/libspdm_responder_lib.h"
#include "industry_standard/spdm.h"

#define MY_TRANSPORT_OVERHEAD (LIBSPDM_TEST_TRANSPORT_HEADER_SIZE + \
                               LIBSPDM_TEST_TRANSPORT_TAIL_SIZE)
#define MY_SENDER_BUF    (0x1100 + MY_TRANSPORT_OVERHEAD)
#define MY_RECEIVER_BUF  (0x1200 + MY_TRANSPORT_OVERHEAD)
#define MY_XFER_SIZE     (MY_RECEIVER_BUF - MY_TRANSPORT_OVERHEAD)
#define MY_MSG_SIZE      0x1200

static uint8_t g_req_buf[MY_RECEIVER_BUF];
static bool g_req_sender_held = false;
static bool g_req_receiver_held = false;
static libspdm_context_t *g_rsp_ctx = NULL;
static void *g_req_scratch = NULL;

static libspdm_return_t req_acq_sender(void *c, void **p) {
    (void)c;
    assert(!g_req_sender_held && !g_req_receiver_held);
    memset(g_req_buf, 0, sizeof(g_req_buf));
    *p = g_req_buf; g_req_sender_held = true;
    return LIBSPDM_STATUS_SUCCESS;
}
static void req_rel_sender(void *c, const void *p) { (void)c; (void)p; g_req_sender_held = false; }
static libspdm_return_t req_acq_receiver(void *c, void **p) {
    (void)c;
    assert(!g_req_sender_held && !g_req_receiver_held);
    memset(g_req_buf, 0, sizeof(g_req_buf));
    *p = g_req_buf; g_req_receiver_held = true;
    return LIBSPDM_STATUS_SUCCESS;
}
static void req_rel_receiver(void *c, const void *p) { (void)c; (void)p; g_req_receiver_held = false; }
static libspdm_return_t req_send(void *c, size_t sz, const void *msg, uint64_t t) {
    (void)c; (void)sz; (void)msg; (void)t;
    return LIBSPDM_STATUS_SUCCESS;
}
static libspdm_return_t req_recv(void *c, size_t *sz, void **buf, uint64_t t) {
    libspdm_context_t *req = (libspdm_context_t *)c;
    const spdm_message_header_t *req_hdr =
        (const spdm_message_header_t *)req->last_spdm_request;
    size_t req_size = req->last_spdm_request_size;
    (void)t;
    uint8_t *tbuf = (uint8_t *)*buf;
    void *rsp_spdm = tbuf + sizeof(libspdm_test_message_header_t);
    size_t rsp_size = *sz - sizeof(libspdm_test_message_header_t);
    libspdm_return_t st;
    switch (req_hdr->request_response_code) {
    case SPDM_GET_VERSION:
        st = libspdm_get_response_version(g_rsp_ctx, req_size, req_hdr, &rsp_size, rsp_spdm);
        break;
    case SPDM_GET_CAPABILITIES:
        st = libspdm_get_response_capabilities(g_rsp_ctx, req_size, req_hdr, &rsp_size, rsp_spdm);
        break;
    case SPDM_NEGOTIATE_ALGORITHMS:
        st = libspdm_get_response_algorithms(g_rsp_ctx, req_size, req_hdr, &rsp_size, rsp_spdm);
        break;
    default:
        return LIBSPDM_STATUS_INVALID_STATE_LOCAL;
    }
    (void)st;
    ((libspdm_test_message_header_t *)tbuf)->message_type = LIBSPDM_TEST_MESSAGE_TYPE_SPDM;
    *sz = sizeof(libspdm_test_message_header_t) + rsp_size;
    return LIBSPDM_STATUS_SUCCESS;
}

static libspdm_context_t *new_requester_ctx(void) {
    libspdm_context_t *ctx = malloc(libspdm_get_context_size());
    assert(ctx);
    libspdm_init_context(ctx);
    libspdm_register_transport_layer_func(ctx, MY_MSG_SIZE,
        LIBSPDM_TEST_TRANSPORT_HEADER_SIZE, LIBSPDM_TEST_TRANSPORT_TAIL_SIZE,
        libspdm_transport_test_encode_message, libspdm_transport_test_decode_message);
    libspdm_register_device_io_func(ctx, req_send, req_recv);
    libspdm_register_device_buffer_func(ctx,
        MY_SENDER_BUF, MY_RECEIVER_BUF,
        req_acq_sender, req_rel_sender,
        req_acq_receiver, req_rel_receiver);
    size_t scratch_sz = libspdm_get_sizeof_required_scratch_buffer(ctx);
    g_req_scratch = malloc(scratch_sz);
    assert(g_req_scratch);
    libspdm_set_scratch_buffer(ctx, g_req_scratch, scratch_sz);
    return ctx;
}

static libspdm_context_t *new_responder_ctx(void) {
    libspdm_context_t *ctx = malloc(libspdm_get_context_size());
    assert(ctx);
    libspdm_init_context(ctx);
    return ctx;
}

int main(void)
{
    printf("=== BUG-F1: base_asym_algo Selected Without Enabling Capability ===\n");
    printf("Escalation level: 0 (Pure black-box — SPDM v1.0, no capabilities, non-zero asym algo)\n\n");

    libspdm_context_t *req = new_requester_ctx();
    libspdm_context_t *rsp = new_responder_ctx();

    /*
     * Configure both sides for SPDM v1.0 with NO capability flags but
     * with base_asym_algo = RSAPSS_3072 (non-zero).
     *
     * In v1.0, capability flags are not exchanged; capability.flags is effectively 0.
     * The NEGOTIATE_ALGORITHMS request includes base_asym_algo = RSAPSS_3072.
     * The responder unconditionally computes:
     *   base_asym_sel = prioritize(local.base_asym_algo, req.base_asym_algo)
     *                 = prioritize(RSAPSS_3072, RSAPSS_3072) = RSAPSS_3072
     * There is no check to zero base_asym_sel when no capability requires it.
     *
     * Invariant that should hold (but doesn't):
     *   (CERT_CAP || CHAL_CAP || MEAS_CAP_SIG || KEY_EX_CAP) <=> base_asym_sel != 0
     */
    {
        spdm_version_number_t ver10 = SPDM_MESSAGE_VERSION_10 << SPDM_VERSION_NUMBER_SHIFT_BIT;
        libspdm_data_parameter_t p = {0};
        p.location = LIBSPDM_DATA_LOCATION_LOCAL;
        libspdm_set_data(req, LIBSPDM_DATA_SPDM_VERSION, &p, &ver10, sizeof(ver10));
        libspdm_set_data(rsp, LIBSPDM_DATA_SPDM_VERSION, &p, &ver10, sizeof(ver10));
    }

    /* Requester: no caps, but requests base_asym_algo = RSAPSS_3072 */
    req->local_context.capability.flags = 0;
    req->local_context.capability.transport_header_size = LIBSPDM_TEST_TRANSPORT_HEADER_SIZE;
    req->local_context.capability.transport_tail_size   = LIBSPDM_TEST_TRANSPORT_TAIL_SIZE;
    req->local_context.algorithm.measurement_spec  = 0; /* no MEAS_CAP */
    req->local_context.algorithm.base_asym_algo    = SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_RSAPSS_3072;
    req->local_context.algorithm.base_hash_algo    = SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256;

    /*
     * Responder: no caps (no CERT/CHAL/MEAS_SIG/KEY_EX), but base_asym_algo = RSAPSS_3072.
     * The ASSERT in libspdm_get_response_algorithms() checks:
     *   !(( MEAS_CAP==0 ) ^ ( measurement_spec==0 ))  — must set both to 0 or both non-zero
     *   !(( MEAS_CAP==0 ) ^ ( measurement_hash_algo==0 ))
     * Since flags=0 (no MEAS_CAP), measurement_spec and measurement_hash_algo must be 0.
     */
    rsp->local_context.capability.flags = 0; /* no CERT, CHAL, MEAS_SIG, KEY_EX */
    rsp->local_context.capability.transport_header_size = LIBSPDM_TEST_TRANSPORT_HEADER_SIZE;
    rsp->local_context.capability.transport_tail_size   = LIBSPDM_TEST_TRANSPORT_TAIL_SIZE;
    rsp->local_context.algorithm.measurement_spec      = 0; /* required: MEAS_CAP=0 => must be 0 */
    rsp->local_context.algorithm.measurement_hash_algo = 0; /* required: MEAS_CAP=0 => must be 0 */
    rsp->local_context.algorithm.base_asym_algo        = SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_RSAPSS_3072;
    rsp->local_context.algorithm.base_hash_algo        = SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256;

    g_rsp_ctx = rsp;

    printf("Setup:\n");
    printf("  SPDM version: v1.0\n");
    printf("  Requester caps: 0x0 (no CERT/CHAL/KEY_EX/PSK)\n");
    printf("  Responder caps: 0x0 (no CERT/CHAL/KEY_EX/PSK)\n");
    printf("  Both sides: base_asym_algo = RSAPSS_3072 (0x%08x)\n\n",
           SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_RSAPSS_3072);

    /* Full VCA handshake */
    libspdm_return_t st;

    st = libspdm_get_version(req, NULL, NULL);
    if (LIBSPDM_STATUS_IS_ERROR(st)) {
        printf("FAIL: get_version: 0x%lx\n", (unsigned long)st);
        return 1;
    }
    printf("VERSION:   OK (negotiated v1.0)\n");

    st = libspdm_get_capabilities(req);
    if (LIBSPDM_STATUS_IS_ERROR(st)) {
        printf("FAIL: get_capabilities: 0x%lx\n", (unsigned long)st);
        return 1;
    }
    printf("CAPABILITIES: OK (both sides: flags=0)\n");

    st = libspdm_negotiate_algorithms(req);
    printf("NEGOTIATE_ALGORITHMS returned: 0x%lx (%s)\n",
           (unsigned long)st,
           LIBSPDM_STATUS_IS_ERROR(st) ? "ERROR" : "SUCCESS");

    printf("\nPost-handshake state (responder side):\n");
    printf("  rsp conn_state:              %d (NEGOTIATED=%d)\n",
           rsp->connection_info.connection_state,
           LIBSPDM_CONNECTION_STATE_NEGOTIATED);
    printf("  rsp capability.flags:        0x%08x (expect: 0 = no CERT/CHAL/KEY_EX)\n",
           rsp->connection_info.capability.flags);
    printf("  rsp algorithm.base_asym_algo: 0x%08x (expect: 0 since no enabling cap; BUG: non-zero)\n",
           rsp->connection_info.algorithm.base_asym_algo);
    printf("  rsp algorithm.base_hash_algo: 0x%08x\n",
           rsp->connection_info.algorithm.base_hash_algo);

    printf("\nPost-handshake state (requester side):\n");
    printf("  req conn_state:              %d\n",
           req->connection_info.connection_state);
    printf("  req capability.flags:        0x%08x\n",
           req->connection_info.capability.flags);
    printf("  req algorithm.base_asym_algo: 0x%08x\n",
           req->connection_info.algorithm.base_asym_algo);

    int bug_confirmed = 0;

    /*
     * CERT_CAP=0, CHAL_CAP=0, MEAS_CAP_SIG=0, KEY_EX_CAP=0 in the responder's
     * local_context.capability.flags means base_asym_sel SHOULD be 0.
     * The bug: it is not zero.
     */
    uint32_t rsp_cap = rsp->connection_info.capability.flags;
    uint32_t rsp_asym = rsp->connection_info.algorithm.base_asym_algo;
    bool has_asym_cap =
        ((rsp_cap & SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CERT_CAP) != 0) ||
        ((rsp_cap & SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CHAL_CAP) != 0) ||
        ((rsp_cap & SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MEAS_CAP_SIG) != 0) ||
        ((rsp_cap & SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_KEY_EX_CAP) != 0);

    if (!LIBSPDM_STATUS_IS_ERROR(st) &&
        rsp->connection_info.connection_state == LIBSPDM_CONNECTION_STATE_NEGOTIATED &&
        rsp_asym != 0 && !has_asym_cap) {
        printf("\nBUG-F1 CONFIRMED: Incoherent negotiated state!\n");
        printf("  The NEGOTIATE_ALGORITHMS exchange SUCCEEDED (both sides: NEGOTIATED state).\n");
        printf("  But the negotiated base_asym_algo=0x%08x is non-zero\n", rsp_asym);
        printf("  while NO asym-requiring capability (CERT/CHAL/MEAS_SIG/KEY_EX) is enabled.\n");
        printf("  Root cause: libspdm_rsp_algorithms.c:739-742 sets base_asym_sel unconditionally.\n");
        printf("  Lines 927-950 check 'non-zero when needed' but NOT 'zero when not needed'.\n");
        printf("  Downstream code using base_asym_algo!=0 as a proxy for asym capabilities\n");
        printf("  would incorrectly attempt asymmetric crypto operations.\n");
        bug_confirmed = 1;
    } else if (LIBSPDM_STATUS_IS_ERROR(st)) {
        printf("\nNOTE: NEGOTIATE_ALGORITHMS failed with 0x%lx.\n", (unsigned long)st);
        printf("  If this is INVALID_MSG_FIELD from the requester rejecting base_asym_sel,\n");
        printf("  the bug is still present in the responder — it sent non-zero base_asym_sel.\n");
        /* Still check responder state */
        if (rsp_asym != 0 && !has_asym_cap) {
            printf("  Responder DID set base_asym_algo=0x%08x without enabling cap — BUG CONFIRMED.\n", rsp_asym);
            bug_confirmed = 1;
        }
    } else {
        printf("\nUNEXPECTED: either handshake failed or base_asym_algo was correctly zeroed.\n");
    }

    free(g_req_scratch);
    free(req);
    free(rsp);

    return bug_confirmed ? 0 : 1;
}
