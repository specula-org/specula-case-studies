/**
 * TLA+ trace harness: libspdm VCA handshake scenarios.
 *
 * Scenarios:
 *   1. normal.ndjson    — clean VERSION→CAPABILITIES→ALGORITHMS (SHA256/RSA3072)
 *   2. normal2.ndjson   — clean VCA with ECDSA-P384 / SHA384
 *   3. reset.ndjson     — VCA + explicit context_reset + second VCA
 *   4. caps_error.ndjson— F4 path: caps request appended, response fails
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

#include "tla_trace.h"

/* ----------------------------------------------------------------------- */
/* Buffer sizes (matching spdm_unit_test_common)                            */
/* ----------------------------------------------------------------------- */
#define MY_TRANSPORT_OVERHEAD (LIBSPDM_TEST_TRANSPORT_HEADER_SIZE + \
                               LIBSPDM_TEST_TRANSPORT_TAIL_SIZE)
#define MY_SENDER_BUF    (0x1100 + MY_TRANSPORT_OVERHEAD)
#define MY_RECEIVER_BUF  (0x1200 + MY_TRANSPORT_OVERHEAD)
#define MY_XFER_SIZE     (MY_RECEIVER_BUF - MY_TRANSPORT_OVERHEAD)
#define MY_MSG_SIZE      0x1200

/* Shared send/receive buffer for the requester I/O */
static uint8_t g_req_buf[MY_RECEIVER_BUF];
static bool g_req_sender_held = false;
static bool g_req_receiver_held = false;

static libspdm_return_t req_acq_sender(void *c, void **p) {
    (void)c;
    assert(!g_req_sender_held && !g_req_receiver_held);
    memset(g_req_buf, 0, sizeof(g_req_buf));
    *p = g_req_buf; g_req_sender_held = true;
    return LIBSPDM_STATUS_SUCCESS;
}
static void req_rel_sender(void *c, const void *p) {
    (void)c; (void)p;
    assert(g_req_sender_held && !g_req_receiver_held);
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
    assert(!g_req_sender_held && g_req_receiver_held);
    g_req_receiver_held = false;
}

/* ----------------------------------------------------------------------- */
/* Loopback transport — routes requester requests to the global responder    */
/* ----------------------------------------------------------------------- */

static libspdm_context_t *g_rsp_ctx = NULL;

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
        st = libspdm_get_response_version(g_rsp_ctx, req_size, req_hdr,
                                          &rsp_size, rsp_spdm);
        break;
    case SPDM_GET_CAPABILITIES:
        st = libspdm_get_response_capabilities(g_rsp_ctx, req_size, req_hdr,
                                               &rsp_size, rsp_spdm);
        break;
    case SPDM_NEGOTIATE_ALGORITHMS:
        st = libspdm_get_response_algorithms(g_rsp_ctx, req_size, req_hdr,
                                             &rsp_size, rsp_spdm);
        break;
    default:
        fprintf(stderr, "Unexpected request code 0x%02x\n",
                req_hdr->request_response_code);
        return LIBSPDM_STATUS_INVALID_STATE_LOCAL;
    }

    /* Even if the responder returned an error response, it's still a valid
     * SPDM message that we should relay back. */
    (void)st;

    ((libspdm_test_message_header_t *)tbuf)->message_type =
        LIBSPDM_TEST_MESSAGE_TYPE_SPDM;
    *sz = sizeof(libspdm_test_message_header_t) + rsp_size;
    return LIBSPDM_STATUS_SUCCESS;
}

/* ----------------------------------------------------------------------- */
/* Context factory                                                           */
/* ----------------------------------------------------------------------- */

/* Scratch buffer for requester; freed after each scenario. */
static void *g_req_scratch = NULL;

static libspdm_context_t *new_requester_ctx(void)
{
    libspdm_context_t *ctx = malloc(libspdm_get_context_size());
    assert(ctx);
    libspdm_init_context(ctx);

    libspdm_register_transport_layer_func(ctx,
        MY_MSG_SIZE,
        LIBSPDM_TEST_TRANSPORT_HEADER_SIZE,
        LIBSPDM_TEST_TRANSPORT_TAIL_SIZE,
        libspdm_transport_test_encode_message,
        libspdm_transport_test_decode_message);

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

static libspdm_context_t *new_responder_ctx(void)
{
    libspdm_context_t *ctx = malloc(libspdm_get_context_size());
    assert(ctx);
    libspdm_init_context(ctx);
    /* Responder handlers are called directly; no device I/O or transport needed */
    return ctx;
}

static void free_requester(libspdm_context_t *ctx)
{
    free(g_req_scratch);
    g_req_scratch = NULL;
    free(ctx);
}

/* ----------------------------------------------------------------------- */
/* Configuration helpers                                                     */
/* ----------------------------------------------------------------------- */

/* Set local version list to only SPDM 1.2 */
static void set_version_12(libspdm_context_t *ctx)
{
    spdm_version_number_t ver12 = SPDM_MESSAGE_VERSION_12 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    libspdm_data_parameter_t p = {0};
    p.location = LIBSPDM_DATA_LOCATION_LOCAL;
    libspdm_set_data(ctx, LIBSPDM_DATA_SPDM_VERSION, &p, &ver12, sizeof(ver12));
}

/* Requester: configure capabilities and algorithms */
static void cfg_req(libspdm_context_t *ctx, uint32_t flags,
                    uint32_t asym, uint32_t hash)
{
    set_version_12(ctx);
    ctx->local_context.capability.flags             = flags;
    ctx->local_context.capability.ct_exponent       = 0;
    ctx->local_context.capability.data_transfer_size = MY_XFER_SIZE;
    ctx->local_context.capability.max_spdm_msg_size  = MY_MSG_SIZE;
    ctx->local_context.capability.transport_header_size = LIBSPDM_TEST_TRANSPORT_HEADER_SIZE;
    ctx->local_context.capability.transport_tail_size   = LIBSPDM_TEST_TRANSPORT_TAIL_SIZE;
    ctx->local_context.algorithm.measurement_spec   = SPDM_MEASUREMENT_SPECIFICATION_DMTF;
    ctx->local_context.algorithm.base_asym_algo     = asym;
    ctx->local_context.algorithm.base_hash_algo     = hash;
    ctx->local_context.algorithm.dhe_named_group    = 0;
    ctx->local_context.algorithm.aead_cipher_suite  = 0;
    ctx->local_context.algorithm.req_base_asym_alg  = 0;
    ctx->local_context.algorithm.key_schedule       = 0;
}

/* Responder: configure capabilities and algorithms */
static void cfg_rsp(libspdm_context_t *ctx, uint32_t flags,
                    uint32_t asym, uint32_t hash, uint32_t mhash)
{
    set_version_12(ctx);
    ctx->local_context.capability.flags             = flags;
    ctx->local_context.capability.ct_exponent       = 0;
    ctx->local_context.capability.data_transfer_size = MY_XFER_SIZE;
    ctx->local_context.capability.max_spdm_msg_size  = MY_MSG_SIZE;
    ctx->local_context.capability.transport_header_size = LIBSPDM_TEST_TRANSPORT_HEADER_SIZE;
    ctx->local_context.capability.transport_tail_size   = LIBSPDM_TEST_TRANSPORT_TAIL_SIZE;
    ctx->local_context.algorithm.measurement_spec   = SPDM_MEASUREMENT_SPECIFICATION_DMTF;
    ctx->local_context.algorithm.measurement_hash_algo = mhash;
    ctx->local_context.algorithm.base_asym_algo     = asym;
    ctx->local_context.algorithm.base_hash_algo     = hash;
    ctx->local_context.algorithm.dhe_named_group    = 0;
    ctx->local_context.algorithm.aead_cipher_suite  = 0;
    ctx->local_context.algorithm.req_base_asym_alg  = 0;
    ctx->local_context.algorithm.key_schedule       = 0;
}

/* ----------------------------------------------------------------------- */
/* Run a full VCA handshake on the given pair of contexts                   */
/* ----------------------------------------------------------------------- */

static int do_vca(libspdm_context_t *req, libspdm_context_t *rsp,
                   const char *tag)
{
    g_rsp_ctx = rsp;
    libspdm_return_t st;

    st = libspdm_get_version(req, NULL, NULL);
    if (LIBSPDM_STATUS_IS_ERROR(st)) {
        fprintf(stderr, "[%s] get_version failed: 0x%lx\n", tag, (unsigned long)st);
        return -1;
    }
    st = libspdm_get_capabilities(req);
    if (LIBSPDM_STATUS_IS_ERROR(st)) {
        fprintf(stderr, "[%s] get_capabilities failed: 0x%lx\n", tag, (unsigned long)st);
        return -1;
    }
    st = libspdm_negotiate_algorithms(req);
    if (LIBSPDM_STATUS_IS_ERROR(st)) {
        fprintf(stderr, "[%s] negotiate_algorithms failed: 0x%lx\n", tag, (unsigned long)st);
        return -1;
    }
    return 0;
}

/* ----------------------------------------------------------------------- */
/* SCENARIO 1: Normal VCA — SHA256, RSA3072, CERT+CHAL                     */
/* ----------------------------------------------------------------------- */
static void scenario_normal(const char *path)
{
    printf("[scenario] normal -> %s\n", path);
    tla_trace_open(path);

    libspdm_context_t *req = new_requester_ctx();
    libspdm_context_t *rsp = new_responder_ctx();

    cfg_req(req,
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_CERT_CAP |
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_CHAL_CAP,
        SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_RSAPSS_3072,
        SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256);

    cfg_rsp(rsp,
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CERT_CAP |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CHAL_CAP |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MEAS_CAP_NO_SIG,
        SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_RSAPSS_3072,
        SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256,
        SPDM_ALGORITHMS_MEASUREMENT_HASH_ALGO_TPM_ALG_SHA_256);

    int rc = do_vca(req, rsp, "normal");
    printf("  %s, conn_state=%d\n", rc == 0 ? "OK" : "FAIL",
           req->connection_info.connection_state);

    tla_trace_close();
    free_requester(req);
    free(rsp);
}

/* ----------------------------------------------------------------------- */
/* SCENARIO 2: Normal VCA — SHA384, ECDSA-P384, CERT+CHAL+MEAS_SIG        */
/* ----------------------------------------------------------------------- */
static void scenario_normal2(const char *path)
{
    printf("[scenario] normal2 -> %s\n", path);
    tla_trace_open(path);

    libspdm_context_t *req = new_requester_ctx();
    libspdm_context_t *rsp = new_responder_ctx();

    cfg_req(req,
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_CERT_CAP |
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_CHAL_CAP,
        SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_ECDSA_ECC_NIST_P384,
        SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_384);

    cfg_rsp(rsp,
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CERT_CAP |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CHAL_CAP |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MEAS_CAP_SIG,
        SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_ECDSA_ECC_NIST_P384,
        SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_384,
        SPDM_ALGORITHMS_MEASUREMENT_HASH_ALGO_TPM_ALG_SHA_384);

    int rc = do_vca(req, rsp, "normal2");
    printf("  %s\n", rc == 0 ? "OK" : "FAIL");

    tla_trace_close();
    free_requester(req);
    free(rsp);
}

/* ----------------------------------------------------------------------- */
/* SCENARIO 3: VCA + context_reset + second VCA                            */
/* ----------------------------------------------------------------------- */
static void scenario_reset(const char *path)
{
    printf("[scenario] reset -> %s\n", path);
    tla_trace_open(path);

    libspdm_context_t *req = new_requester_ctx();
    libspdm_context_t *rsp = new_responder_ctx();

    cfg_req(req,
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_CERT_CAP |
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_CHAL_CAP,
        SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_RSAPSS_3072,
        SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256);
    cfg_rsp(rsp,
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CERT_CAP |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CHAL_CAP |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MEAS_CAP_NO_SIG,
        SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_RSAPSS_3072,
        SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256,
        SPDM_ALGORITHMS_MEASUREMENT_HASH_ALGO_TPM_ALG_SHA_256);

    /* First VCA */
    if (do_vca(req, rsp, "reset-vca1") != 0) goto done;
    printf("  VCA1 OK, state=%d\n", req->connection_info.connection_state);

    /* Emit context_reset BEFORE calling libspdm_reset_context */
    tla_trace_context_reset(req->connection_info.connection_state);
    libspdm_reset_context(req);
    libspdm_reset_context(rsp);
    /* local_context (caps, algos, versions) is preserved after reset */

    /* Second VCA */
    if (do_vca(req, rsp, "reset-vca2") != 0) goto done;
    printf("  VCA2 OK, state=%d\n", req->connection_info.connection_state);

done:
    tla_trace_close();
    free_requester(req);
    free(rsp);
}

/* ----------------------------------------------------------------------- */
/* SCENARIO 4: F4 error path — capabilities request appended, response fails*/
/* We achieve this by filling the responder's message_a buffer to capacity  */
/* after the VERSION phase, leaving just enough room for the request but    */
/* not the response.                                                         */
/* ----------------------------------------------------------------------- */
static void scenario_caps_error(const char *path)
{
    printf("[scenario] caps_error -> %s\n", path);
    tla_trace_open(path);

    libspdm_context_t *req = new_requester_ctx();
    libspdm_context_t *rsp = new_responder_ctx();

    cfg_req(req,
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_CERT_CAP |
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_CHAL_CAP,
        SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_RSAPSS_3072,
        SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256);
    cfg_rsp(rsp,
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CERT_CAP |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CHAL_CAP |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MEAS_CAP_NO_SIG,
        SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_RSAPSS_3072,
        SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256,
        SPDM_ALGORITHMS_MEASUREMENT_HASH_ALGO_TPM_ALG_SHA_256);

    g_rsp_ctx = rsp;

    /* Step 1: VERSION phase */
    libspdm_return_t st = libspdm_get_version(req, NULL, NULL);
    if (LIBSPDM_STATUS_IS_ERROR(st)) {
        fprintf(stderr, "[caps_error] get_version failed: 0x%lx\n", (unsigned long)st);
        goto done;
    }

    /* Step 2: Fill the responder transcript to trigger response-append failure.
     * LIBSPDM_MAX_MESSAGE_VCA_BUFFER_SIZE controls the message_a buffer.
     * Leave exactly sizeof(GET_CAPABILITIES request) free but not enough for
     * the CAPABILITIES response. */
    {
        size_t used  = rsp->transcript.message_a.buffer_size;
        size_t cap   = rsp->transcript.message_a.max_buffer_size;
        size_t caps_req_sz = sizeof(spdm_get_capabilities_request_t);
        /* Caps response size (v1.2): sizeof(spdm_capabilities_response_t) = 20 bytes */
        size_t caps_rsp_sz = sizeof(spdm_capabilities_response_t);
        /* Fill up to: cap - caps_req_sz (leaves room for request but not response) */
        size_t target_used = cap - caps_req_sz;
        if (target_used > used) {
            size_t fill_needed = target_used - used;
            /* Append filler bytes to responder's message_a */
            static uint8_t filler[512];
            while (fill_needed > 0) {
                size_t chunk = fill_needed < sizeof(filler) ? fill_needed : sizeof(filler);
                libspdm_return_t r = libspdm_append_message_a(rsp, filler, chunk);
                if (LIBSPDM_STATUS_IS_ERROR(r)) break;
                fill_needed -= chunk;
            }
        }
        printf("  After fill: transcript used=%zu / cap=%zu, caps_rsp needs %zu\n",
               rsp->transcript.message_a.buffer_size,
               rsp->transcript.message_a.max_buffer_size,
               caps_rsp_sz);
    }

    /* Step 3: CAPABILITIES — responder should fail on response append */
    st = libspdm_get_capabilities(req);
    if (LIBSPDM_STATUS_IS_ERROR(st)) {
        printf("  caps_error: get_capabilities returned 0x%lx (F4 triggered)\n",
               (unsigned long)st);
    } else {
        printf("  caps_error: get_capabilities succeeded (no overflow — adjust fill size)\n");
    }

done:
    tla_trace_close();
    free_requester(req);
    free(rsp);
}

/* ----------------------------------------------------------------------- */
/* Main                                                                      */
/* ----------------------------------------------------------------------- */
int main(int argc, char **argv)
{
    const char *traces_dir = (argc > 1) ? argv[1] : "traces";
    char path[512];

    printf("Writing traces to: %s/\n\n", traces_dir);

    snprintf(path, sizeof(path), "%s/normal.ndjson", traces_dir);
    scenario_normal(path);

    snprintf(path, sizeof(path), "%s/normal2.ndjson", traces_dir);
    scenario_normal2(path);

    snprintf(path, sizeof(path), "%s/reset.ndjson", traces_dir);
    scenario_reset(path);

    snprintf(path, sizeof(path), "%s/caps_error.ndjson", traces_dir);
    scenario_caps_error(path);

    printf("\nDone.\n");
    return 0;
}
