/**
 * BUG-F2: Responder Capability Flags Not Self-Validated
 *
 * Root cause: libspdm_get_response_capabilities() validates the REQUESTER's
 * capability flags via libspdm_check_request_flag_compatibility(), but never
 * calls that function (or equivalent) on the RESPONDER's own local_context flags
 * before advertising them in the CAPABILITIES response.
 *
 * A responder configured with MAC_CAP=1 but KEY_EX_CAP=0 and PSK_CAP=0 sends
 * a CAPABILITIES response with these incoherent flags. The SPDM spec (1.1+)
 * requires MAC_CAP to imply KEY_EX_CAP or PSK_CAP.
 *
 * Escalation: Level 0 (Pure black-box) — the bug triggers through normal API
 * usage whenever the responder is misconfigured. No state injection needed.
 *
 * Observable outcome:
 *   - The responder successfully sends CAPABILITIES with MAC_CAP=1, KEY_EX_CAP=0, PSK_CAP=0
 *   - The requester's validate_responder_capability() detects the incoherence and
 *     returns LIBSPDM_STATUS_INVALID_MSG_FIELD
 *   - The responder transitions to AFTER_CAPABILITIES state; the requester does NOT
 *   - Both sides are now in different states — the session is deadlocked
 *
 * The bug: the responder should have returned INVALID_REQUEST itself (before the
 * requester had to detect the error). It sent a bad response and the protocol state
 * machine is now split.
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
    printf("=== BUG-F2: Responder Capability Flags Not Self-Validated ===\n");
    printf("Escalation level: 0 (Pure black-box — no state injection)\n\n");

    libspdm_context_t *req = new_requester_ctx();
    libspdm_context_t *rsp = new_responder_ctx();

    /* Requester: v1.1, no session capabilities (valid flags) */
    {
        spdm_version_number_t ver11 = SPDM_MESSAGE_VERSION_11 << SPDM_VERSION_NUMBER_SHIFT_BIT;
        libspdm_data_parameter_t p = {0};
        p.location = LIBSPDM_DATA_LOCATION_LOCAL;
        libspdm_set_data(req, LIBSPDM_DATA_SPDM_VERSION, &p, &ver11, sizeof(ver11));
    }
    req->local_context.capability.flags = 0; /* no session caps */
    req->local_context.capability.ct_exponent = 0;
    req->local_context.capability.transport_header_size = LIBSPDM_TEST_TRANSPORT_HEADER_SIZE;
    req->local_context.capability.transport_tail_size   = LIBSPDM_TEST_TRANSPORT_TAIL_SIZE;
    req->local_context.algorithm.measurement_spec  = SPDM_MEASUREMENT_SPECIFICATION_DMTF;
    req->local_context.algorithm.base_asym_algo    = SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_RSAPSS_3072;
    req->local_context.algorithm.base_hash_algo    = SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256;

    /*
     * Responder: v1.1 with INCOHERENT flags:
     *   MAC_CAP = 1, KEY_EX_CAP = 0, PSK_CAP = 0
     *
     * The SPDM 1.1 spec requires: ~KEY_EX_CAP ∧ ~PSK_CAP ⟹ ~MAC_CAP
     * libspdm_check_request_flag_compatibility() enforces this for REQUESTER flags
     * but is NEVER called on the RESPONDER's own local_context.capability.flags.
     */
    {
        spdm_version_number_t ver11 = SPDM_MESSAGE_VERSION_11 << SPDM_VERSION_NUMBER_SHIFT_BIT;
        libspdm_data_parameter_t p = {0};
        p.location = LIBSPDM_DATA_LOCATION_LOCAL;
        libspdm_set_data(rsp, LIBSPDM_DATA_SPDM_VERSION, &p, &ver11, sizeof(ver11));
    }
    /* Incoherent: MAC without KEY_EX or PSK */
    rsp->local_context.capability.flags = SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MAC_CAP;
    rsp->local_context.capability.ct_exponent = 0;
    rsp->local_context.capability.transport_header_size = LIBSPDM_TEST_TRANSPORT_HEADER_SIZE;
    rsp->local_context.capability.transport_tail_size   = LIBSPDM_TEST_TRANSPORT_TAIL_SIZE;
    rsp->local_context.algorithm.measurement_spec  = 0; /* no MEAS_CAP */
    rsp->local_context.algorithm.measurement_hash_algo = 0;
    rsp->local_context.algorithm.base_asym_algo    = 0;
    rsp->local_context.algorithm.base_hash_algo    = SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256;

    g_rsp_ctx = rsp;

    printf("Responder configured with incoherent flags:\n");
    printf("  MAC_CAP=1, KEY_EX_CAP=0, PSK_CAP=0 (violates SPDM 1.1 rule: MAC requires KEY_EX or PSK)\n");
    printf("  SPDM spec: 'If KEY_EX_CAP=0 and PSK_CAP=0, then MAC_CAP must be 0'\n\n");

    /* Step 1: VERSION phase */
    libspdm_return_t st = libspdm_get_version(req, NULL, NULL);
    if (LIBSPDM_STATUS_IS_ERROR(st)) {
        printf("FAIL: get_version failed: 0x%lx\n", (unsigned long)st);
        return 1;
    }
    printf("VERSION phase: OK (conn_state=%d)\n", req->connection_info.connection_state);

    /* Step 2: GET_CAPABILITIES — the responder will send MAC_CAP without KEY_EX/PSK */
    st = libspdm_get_capabilities(req);

    printf("GET_CAPABILITIES returned: 0x%lx\n", (unsigned long)st);
    printf("  Requester connection_state: %d\n", req->connection_info.connection_state);
    printf("  Responder connection_state: %d (AFTER_CAPABILITIES=%d)\n",
           rsp->connection_info.connection_state,
           LIBSPDM_CONNECTION_STATE_AFTER_CAPABILITIES);

    /* Print the responder's negotiated cap flags */
    printf("  Responder local flags (what it advertised): 0x%08x\n",
           rsp->local_context.capability.flags);
    printf("    MAC_CAP=1, KEY_EX_CAP=0, PSK_CAP=0 (INCOHERENT)\n");
    printf("  Responder conn_info flags: 0x%08x\n",
           rsp->connection_info.capability.flags);

    int bug_confirmed = 0;

    /*
     * Expected (correct) behavior:
     *   The responder should detect its own incoherent flags and return INVALID_REQUEST.
     *   The requester would then get LIBSPDM_STATUS_ERROR_PEER.
     *   Both sides would remain in the same state.
     *
     * Actual (buggy) behavior:
     *   The responder sends CAPABILITIES with MAC_CAP=1 (status SUCCESS from responder side).
     *   The requester's validate_responder_capability() catches the incoherence.
     *   The requester returns LIBSPDM_STATUS_INVALID_MSG_FIELD.
     *   State split: responder=AFTER_CAPABILITIES, requester=still AFTER_VERSION.
     */
    if (st == LIBSPDM_STATUS_INVALID_MSG_FIELD &&
        rsp->connection_info.connection_state == LIBSPDM_CONNECTION_STATE_AFTER_CAPABILITIES &&
        req->connection_info.connection_state != LIBSPDM_CONNECTION_STATE_AFTER_CAPABILITIES) {
        printf("\nBUG-F2 CONFIRMED: Responder flag incoherence not caught by responder!\n");
        printf("  The responder sent CAPABILITIES with MAC_CAP=1 but no KEY_EX/PSK (SUCCESS).\n");
        printf("  The REQUESTER detected the incoherence (LIBSPDM_STATUS_INVALID_MSG_FIELD).\n");
        printf("  The responder is in AFTER_CAPS state; the requester is NOT.\n");
        printf("  Protocol is deadlocked — both sides are in different connection states.\n");
        printf("  Fix: call libspdm_check_request_flag_compatibility on own flags in\n");
        printf("       libspdm_get_response_capabilities() before sending the response.\n");
        bug_confirmed = 1;
    } else if (st == LIBSPDM_STATUS_ERROR_PEER) {
        printf("\nNOTE: The responder DID detect the incoherence (sent INVALID_REQUEST).\n");
        printf("  Bug may have been fixed in this version.\n");
    } else {
        printf("\nUNEXPECTED: status=0x%lx, rsp_state=%d, req_state=%d\n",
               (unsigned long)st,
               rsp->connection_info.connection_state,
               req->connection_info.connection_state);
    }

    free(g_req_scratch);
    free(req);
    free(rsp);

    return bug_confirmed ? 0 : 1;
}
