/**
 * BUG-F4: Transcript Corruption on GET_CAPABILITIES Error Return Path
 *
 * Root cause: libspdm_rsp_capabilities.c appends the GET_CAPABILITIES
 * request to message_a before generating the response. If the response
 * append fails (BUFFER_TOO_SMALL), the request is left in the transcript
 * without a corresponding response. This corrupts message_a, causing
 * transcript mismatch in any downstream KEY_EXCHANGE that signs over it.
 *
 * Escalation: Level 2 (State Injection) — pre-fill message_a to force the
 * response-append to fail. Level 0 is not feasible because the default buffer
 * is large enough to hold any valid VCA exchange; the overflow only occurs
 * when the buffer is nearly full from prior data.
 *
 * Observable outcome: after the failed GET_CAPABILITIES exchange,
 * rsp->transcript.message_a.buffer_size has grown by exactly request_size
 * (the request was appended), while the response was NOT appended.
 * Any retry would append a second copy of the request, creating a
 * permanently corrupted transcript.
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
static void req_rel_sender(void *c, const void *p) {
    (void)c; (void)p;
    g_req_sender_held = false;
}
static libspdm_return_t req_acq_receiver(void *c, void **p) {
    (void)c;
    assert(!g_req_sender_held && !g_req_receiver_held);
    memset(g_req_buf, 0, sizeof(g_req_buf));
    *p = g_req_buf; g_req_receiver_held = true;
    return LIBSPDM_STATUS_SUCCESS;
}
static void req_rel_receiver(void *c, const void *p) {
    (void)c; (void)p;
    g_req_receiver_held = false;
}
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

static void set_version_12(libspdm_context_t *ctx) {
    spdm_version_number_t ver12 = SPDM_MESSAGE_VERSION_12 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    libspdm_data_parameter_t p = {0};
    p.location = LIBSPDM_DATA_LOCATION_LOCAL;
    libspdm_set_data(ctx, LIBSPDM_DATA_SPDM_VERSION, &p, &ver12, sizeof(ver12));
}

int main(void)
{
    printf("=== BUG-F4: Transcript Corruption on GET_CAPABILITIES Error Path ===\n");
    printf("Escalation level: 2 (State Injection — pre-fill message_a)\n\n");

    libspdm_context_t *req = new_requester_ctx();
    libspdm_context_t *rsp = new_responder_ctx();

    /* Configure both sides for v1.2 with CERT+CHAL */
    set_version_12(req);
    req->local_context.capability.flags =
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_CERT_CAP |
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_CHAL_CAP;
    req->local_context.capability.ct_exponent = 0;
    req->local_context.capability.data_transfer_size = MY_XFER_SIZE;
    req->local_context.capability.max_spdm_msg_size  = MY_MSG_SIZE;
    req->local_context.capability.transport_header_size = LIBSPDM_TEST_TRANSPORT_HEADER_SIZE;
    req->local_context.capability.transport_tail_size   = LIBSPDM_TEST_TRANSPORT_TAIL_SIZE;
    req->local_context.algorithm.measurement_spec  = SPDM_MEASUREMENT_SPECIFICATION_DMTF;
    req->local_context.algorithm.base_asym_algo    = SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_RSAPSS_3072;
    req->local_context.algorithm.base_hash_algo    = SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256;

    set_version_12(rsp);
    rsp->local_context.capability.flags =
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CERT_CAP |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CHAL_CAP |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MEAS_CAP_NO_SIG;
    rsp->local_context.capability.ct_exponent = 0;
    rsp->local_context.capability.data_transfer_size = MY_XFER_SIZE;
    rsp->local_context.capability.max_spdm_msg_size  = MY_MSG_SIZE;
    rsp->local_context.capability.transport_header_size = LIBSPDM_TEST_TRANSPORT_HEADER_SIZE;
    rsp->local_context.capability.transport_tail_size   = LIBSPDM_TEST_TRANSPORT_TAIL_SIZE;
    rsp->local_context.algorithm.measurement_spec  = SPDM_MEASUREMENT_SPECIFICATION_DMTF;
    rsp->local_context.algorithm.measurement_hash_algo = SPDM_ALGORITHMS_MEASUREMENT_HASH_ALGO_TPM_ALG_SHA_256;
    rsp->local_context.algorithm.base_asym_algo    = SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_RSAPSS_3072;
    rsp->local_context.algorithm.base_hash_algo    = SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256;

    g_rsp_ctx = rsp;

    /* Step 1: VERSION phase — this appends to message_a on both sides */
    libspdm_return_t st = libspdm_get_version(req, NULL, NULL);
    if (LIBSPDM_STATUS_IS_ERROR(st)) {
        printf("FAIL: get_version failed: 0x%lx\n", (unsigned long)st);
        return 1;
    }

    /* Step 2: State injection — pre-fill responder's message_a to force
     * the CAPABILITIES response append to fail.
     * Target: max - sizeof(GET_CAPABILITIES request v1.2) bytes used,
     * so the request fits but the response does not.
     *
     * The request size for v1.2 is sizeof(spdm_get_capabilities_request_t) = 20 bytes.
     * The response size for v1.2 is sizeof(spdm_capabilities_response_t) = 20 bytes.
     * With exactly 20 bytes free: request fills the buffer, response cannot fit.
     */
    {
        size_t used  = rsp->transcript.message_a.buffer_size;
        size_t cap   = rsp->transcript.message_a.max_buffer_size;
        size_t caps_req_sz = sizeof(spdm_get_capabilities_request_t); /* 20 bytes v1.2 */
        size_t target_used = cap - caps_req_sz;

        printf("Responder message_a before fill: used=%zu / cap=%zu\n", used, cap);

        if (target_used > used) {
            size_t fill_needed = target_used - used;
            static uint8_t filler[512];
            memset(filler, 0xAB, sizeof(filler));
            while (fill_needed > 0) {
                size_t chunk = fill_needed < sizeof(filler) ? fill_needed : sizeof(filler);
                libspdm_return_t r = libspdm_append_message_a(rsp, filler, chunk);
                if (LIBSPDM_STATUS_IS_ERROR(r)) {
                    printf("FAIL: filler append failed unexpectedly: 0x%lx\n", (unsigned long)r);
                    return 1;
                }
                fill_needed -= chunk;
            }
        }

        printf("Responder message_a after fill:  used=%zu / cap=%zu\n",
               rsp->transcript.message_a.buffer_size, cap);
        printf("GET_CAPABILITIES request needs %zu bytes, response needs %zu bytes\n",
               caps_req_sz, sizeof(spdm_capabilities_response_t));
        printf("Available space: %zu bytes (fits request but not request+response)\n\n",
               cap - rsp->transcript.message_a.buffer_size);
    }

    size_t transcript_before_caps = rsp->transcript.message_a.buffer_size;

    /* Step 3: GET_CAPABILITIES — request will fit, but response will fail */
    st = libspdm_get_capabilities(req);

    size_t transcript_after_caps = rsp->transcript.message_a.buffer_size;

    printf("Requester get_capabilities returned: 0x%lx (%s)\n",
           (unsigned long)st,
           LIBSPDM_STATUS_IS_ERROR(st) ? "ERROR (expected: responder sent error response)" : "SUCCESS (unexpected)");

    printf("\nResponder transcript.message_a.buffer_size:\n");
    printf("  Before GET_CAPABILITIES: %zu bytes\n", transcript_before_caps);
    printf("  After  GET_CAPABILITIES: %zu bytes\n", transcript_after_caps);

    size_t delta = transcript_after_caps - transcript_before_caps;
    size_t caps_req_sz = sizeof(spdm_get_capabilities_request_t);

    printf("  Delta: %zu bytes (GET_CAPABILITIES request = %zu bytes)\n\n", delta, caps_req_sz);

    int bug_confirmed = 0;

    if (LIBSPDM_STATUS_IS_ERROR(st) && delta == caps_req_sz) {
        printf("BUG-F4 CONFIRMED: Transcript corruption detected!\n");
        printf("  The GET_CAPABILITIES exchange FAILED (error response sent),\n");
        printf("  but the request was appended to message_a (delta=%zu = request size).\n", delta);
        printf("  The response was NOT appended (transcript is now incoherent).\n");
        printf("  Any retry would append the request a second time, corrupting message_a.\n");
        printf("  Downstream KEY_EXCHANGE would compute a wrong transcript hash.\n");
        bug_confirmed = 1;
    } else if (!LIBSPDM_STATUS_IS_ERROR(st)) {
        printf("NOTE: GET_CAPABILITIES succeeded (fill did not trigger the overflow).\n");
        printf("  Adjust fill size — test needs to be re-run with a larger filler.\n");
    } else {
        printf("REPRODUCTION FAILED: Expected delta=%zu but got %zu\n", caps_req_sz, delta);
    }

    free(g_req_scratch);
    free(req);
    free(rsp);

    return bug_confirmed ? 0 : 1;
}
