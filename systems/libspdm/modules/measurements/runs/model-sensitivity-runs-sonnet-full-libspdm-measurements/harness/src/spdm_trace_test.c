/**
 * spdm_trace_test.c — libspdm GET_MEASUREMENTS TLA+ trace collection
 *
 * Exercises 4 scenarios via a loopback requester/responder pair:
 *   trace_nosig.ndjson    — nosig exchange (validates RequesterParseResponseNoSig)
 *   trace_sig.ndjson      — signature exchange (validates ResponderGenerateSignature)
 *   trace_reset.ndjson    — reset_context after exchange (ResetContext)
 *   trace_resync.ndjson   — need_resync response state (NeedResync)
 *
 * Run from a directory containing ecp256/bundle_responder.certchain.der
 * (i.e. the build's bin/ directory after "make copy_sample_key").
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "internal/libspdm_requester_lib.h"
#include "internal/libspdm_responder_lib.h"
#include "library/spdm_transport_test_lib.h"
#include "spdm_device_secret_lib_internal.h"
#include "tla_trace.h"

/* ---- constants ---- */
#define SEND_RECV_BUF_SIZE (0x2200)
#define LIBSPDM_MAX_SPDM_MSG_SIZE 0x1200

/* ---- global loopback state ---- */
static libspdm_context_t *g_rsp_ctx;
static uint8_t g_raw_req_buf[SEND_RECV_BUF_SIZE];
static size_t  g_raw_req_size;

/* One shared buffer for requester I/O — sender/receiver are never held simultaneously */
static uint8_t g_req_io_buf[SEND_RECV_BUF_SIZE];

/* ---- requester device I/O callbacks ---- */

static libspdm_return_t req_acquire_sender(void *ctx, void **buf)
{
    (void)ctx;
    *buf = g_req_io_buf;
    return LIBSPDM_STATUS_SUCCESS;
}
static void req_release_sender(void *ctx, const void *buf) { (void)ctx; (void)buf; }

static libspdm_return_t req_acquire_receiver(void *ctx, void **buf)
{
    (void)ctx;
    *buf = g_req_io_buf;
    return LIBSPDM_STATUS_SUCCESS;
}
static void req_release_receiver(void *ctx, const void *buf) { (void)ctx; (void)buf; }

static libspdm_return_t req_send_message(void *ctx, size_t req_size,
                                         const void *req, uint64_t to)
{
    (void)ctx; (void)to;
    /* strip 1-byte test transport header to get raw SPDM request */
    if (req_size < 1) return LIBSPDM_STATUS_SEND_FAIL;
    g_raw_req_size = req_size - 1;
    memcpy(g_raw_req_buf, (const uint8_t *)req + 1, g_raw_req_size);
    return LIBSPDM_STATUS_SUCCESS;
}

static libspdm_return_t req_receive_message(void *ctx, size_t *rsp_size,
                                             void **rsp, uint64_t to)
{
    (void)ctx; (void)to;
    /* Write 1-byte transport header then raw SPDM response into the receiver buffer */
    uint8_t *buf = (uint8_t *)*rsp;
    uint8_t *raw_rsp = buf + 1;
    size_t raw_rsp_max = *rsp_size - 1;

    libspdm_return_t status = libspdm_get_response_measurements(
        g_rsp_ctx, g_raw_req_size, g_raw_req_buf, &raw_rsp_max, raw_rsp);
    if (LIBSPDM_STATUS_IS_ERROR(status)) {
        fprintf(stderr, "[loopback] responder error: 0x%x\n", (unsigned)status);
        return LIBSPDM_STATUS_RECEIVE_FAIL;
    }
    buf[0] = LIBSPDM_TEST_MESSAGE_TYPE_SPDM; /* message_type = SPDM (0x01) */
    /* Align to LIBSPDM_TEST_ALIGNMENT (4) bytes as required by transport decode */
    size_t aligned = (raw_rsp_max + 3) & ~(size_t)3;
    if (aligned > raw_rsp_max) {
        memset(raw_rsp + raw_rsp_max, 0, aligned - raw_rsp_max);
    }
    *rsp_size = 1 + aligned;
    return LIBSPDM_STATUS_SUCCESS;
}

/* ---- context allocation helpers ---- */

/*
 * Allocate and initialize a libspdm context with a properly-sized scratch buffer.
 * transport_header and transport_tail must reflect the values that will be passed to
 * libspdm_register_transport_layer_func, so the scratch buffer capacity is computed correctly.
 */
static libspdm_context_t *alloc_ctx_with_scratch(uint8_t **scratch_out,
                                                  size_t *scratch_size_out,
                                                  uint32_t transport_header,
                                                  uint32_t transport_tail)
{
    size_t ctx_size = libspdm_get_context_size();
    libspdm_context_t *ctx = malloc(ctx_size);
    if (!ctx) return NULL;
    libspdm_init_context(ctx);

    /* Set all three transport-size fields before sizing the scratch buffer */
    ctx->local_context.capability.max_spdm_msg_size      = LIBSPDM_MAX_SPDM_MSG_SIZE;
    ctx->local_context.capability.transport_header_size   = transport_header;
    ctx->local_context.capability.transport_tail_size     = transport_tail;

    size_t scratch_size = libspdm_get_sizeof_required_scratch_buffer(ctx);
    uint8_t *scratch = malloc(scratch_size);
    if (!scratch) { free(ctx); return NULL; }
    libspdm_set_scratch_buffer(ctx, scratch, scratch_size);

    if (scratch_out) *scratch_out = scratch;
    if (scratch_size_out) *scratch_size_out = scratch_size;
    return ctx;
}

/* ---- cert chain loading ---- */
static void *g_cert_data = NULL;
static size_t g_cert_size = 0;

static bool load_cert_chain(libspdm_context_t *rsp_ctx)
{
    if (g_cert_data) return true; /* already loaded */
    bool ok = libspdm_read_responder_public_certificate_chain(
        SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256,
        SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_ECDSA_ECC_NIST_P256,
        &g_cert_data, &g_cert_size, NULL, NULL);
    if (!ok) {
        fprintf(stderr, "[trace_test] libspdm_read_responder_public_certificate_chain failed\n"
                        "  (run from a directory containing ecp256/bundle_responder.certchain.der)\n");
        return false;
    }
    return true;
}

/* ---- requester context setup ---- */

static libspdm_context_t *setup_requester(uint8_t **scratch_out)
{
    libspdm_context_t *ctx = alloc_ctx_with_scratch(scratch_out, NULL,
                                                    LIBSPDM_TEST_TRANSPORT_HEADER_SIZE,
                                                    LIBSPDM_TEST_TRANSPORT_TAIL_SIZE);
    if (!ctx) return NULL;

    libspdm_register_device_io_func(ctx, req_send_message, req_receive_message);
    libspdm_register_transport_layer_func(ctx,
        LIBSPDM_MAX_SPDM_MSG_SIZE,
        LIBSPDM_TEST_TRANSPORT_HEADER_SIZE,
        LIBSPDM_TEST_TRANSPORT_TAIL_SIZE,
        libspdm_transport_test_encode_message,
        libspdm_transport_test_decode_message);
    libspdm_register_device_buffer_func(ctx,
        SEND_RECV_BUF_SIZE, SEND_RECV_BUF_SIZE,
        req_acquire_sender, req_release_sender,
        req_acquire_receiver, req_release_receiver);

    ctx->connection_info.version =
        SPDM_MESSAGE_VERSION_11 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    ctx->connection_info.connection_state = LIBSPDM_CONNECTION_STATE_NEGOTIATED;
    ctx->connection_info.capability.flags =
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MEAS_CAP_SIG |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CERT_CAP;
    ctx->connection_info.algorithm.base_hash_algo =
        SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256;
    ctx->connection_info.algorithm.base_asym_algo =
        SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_ECDSA_ECC_NIST_P256;
    ctx->connection_info.algorithm.measurement_spec =
        SPDM_MEASUREMENT_SPECIFICATION_DMTF;
    ctx->connection_info.algorithm.measurement_hash_algo =
        SPDM_ALGORITHMS_MEASUREMENT_HASH_ALGO_TPM_ALG_SHA_256;
    ctx->local_context.algorithm.measurement_spec =
        SPDM_MEASUREMENT_SPECIFICATION_DMTF;

    /* provision requester with responder's cert chain for signature verification */
    if (g_cert_data) {
        ctx->connection_info.peer_used_cert_chain[0].buffer_size = g_cert_size;
        libspdm_copy_mem(ctx->connection_info.peer_used_cert_chain[0].buffer,
                         sizeof(ctx->connection_info.peer_used_cert_chain[0].buffer),
                         g_cert_data, g_cert_size);
    }

    return ctx;
}

/* ---- responder context setup ---- */

static libspdm_context_t *setup_responder(uint8_t **scratch_out)
{
    /* Responder is called directly (no transport layer), so header/tail = 0 */
    libspdm_context_t *ctx = alloc_ctx_with_scratch(scratch_out, NULL, 0, 0);
    if (!ctx) return NULL;

    ctx->connection_info.version =
        SPDM_MESSAGE_VERSION_11 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    ctx->connection_info.connection_state = LIBSPDM_CONNECTION_STATE_AUTHENTICATED;
    ctx->connection_info.capability.flags =
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MEAS_CAP_SIG |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CERT_CAP;
    ctx->local_context.capability.flags =
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MEAS_CAP_SIG |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CERT_CAP;
    ctx->connection_info.algorithm.base_hash_algo =
        SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256;
    ctx->connection_info.algorithm.base_asym_algo =
        SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_ECDSA_ECC_NIST_P256;
    ctx->connection_info.algorithm.measurement_spec =
        SPDM_MEASUREMENT_SPECIFICATION_DMTF;
    ctx->connection_info.algorithm.measurement_hash_algo =
        SPDM_ALGORITHMS_MEASUREMENT_HASH_ALGO_TPM_ALG_SHA_256;
    ctx->response_state = LIBSPDM_RESPONSE_STATE_NORMAL;

    /* provision cert chain for all slots */
    for (int i = 0; i < SPDM_MAX_SLOT_COUNT; i++) {
        ctx->local_context.local_cert_chain_provision[i] = g_cert_data;
        ctx->local_context.local_cert_chain_provision_size[i] = g_cert_size;
    }

    return ctx;
}

/* ---- emit synthetic negotiate_version to bootstrap spec state ---- */
static void emit_negotiate_version(void)
{
    tla_trace_emit("negotiate_version",
                   "{\"version\":\"1.1\"}",
                   "{\"spdm_version\":\"1.1\",\"connection_state\":\"NEGOTIATED\"}");
}

/* ====================================================================
   Scenario 1: trace_nosig.ndjson
   4 successive nosig exchanges (measurement indices 0-3).
   Each exchange: requester_send + responder_append + responder_build +
                  requester_parse_nosig + complete_exchange (5 events)
   Total: 1 negotiate_version + 4 × 5 = 21 events
   ==================================================================== */
static int scenario_nosig(const char *trace_path)
{
    printf("[scenario_nosig] -> %s\n", trace_path);
    tla_trace_init(trace_path);

    uint8_t *req_scratch, *rsp_scratch;
    libspdm_context_t *req_ctx = setup_requester(&req_scratch);
    libspdm_context_t *rsp_ctx = setup_responder(&rsp_scratch);
    if (!req_ctx || !rsp_ctx) return -1;

    g_rsp_ctx = rsp_ctx;
    emit_negotiate_version();

    /* 4 nosig exchanges with different measurement operations */
    static const uint8_t ops[] = {
        SPDM_GET_MEASUREMENTS_REQUEST_MEASUREMENT_OPERATION_TOTAL_NUMBER_OF_MEASUREMENTS,
        1, 2, 3
    };
    libspdm_return_t status = LIBSPDM_STATUS_SUCCESS;
    for (int i = 0; i < 4; i++) {
        uint8_t  meas_rec[1024] = {0};
        uint32_t meas_rec_len = sizeof(meas_rec);
        uint8_t  blocks = 0;
        status = libspdm_get_measurement(req_ctx, NULL, 0, ops[i], 0,
                                         NULL, &blocks, &meas_rec_len, meas_rec);
        printf("[scenario_nosig] op=%u status=0x%x blocks=%u len=%u\n",
               (unsigned)ops[i], (unsigned)status, (unsigned)blocks, (unsigned)meas_rec_len);
        if (LIBSPDM_STATUS_IS_ERROR(status)) break;
    }

    free(req_scratch); free(rsp_scratch); free(req_ctx); free(rsp_ctx);
    tla_trace_fini();
    return LIBSPDM_STATUS_IS_ERROR(status) ? -1 : 0;
}

/* ====================================================================
   Scenario 2: trace_sig.ndjson
   3 successive signature exchanges.
   Each exchange: requester_send + responder_append + responder_build +
                  responder_generate_signature + requester_parse_sig +
                  requester_verify_signature + complete_exchange (7 events)
   Total: 1 negotiate_version + 3 × 7 = 22 events
   ==================================================================== */
static int scenario_sig(const char *trace_path)
{
    printf("[scenario_sig] -> %s\n", trace_path);
    tla_trace_init(trace_path);

    uint8_t *req_scratch, *rsp_scratch;
    libspdm_context_t *req_ctx = setup_requester(&req_scratch);
    libspdm_context_t *rsp_ctx = setup_responder(&rsp_scratch);
    if (!req_ctx || !rsp_ctx) return -1;

    g_rsp_ctx = rsp_ctx;
    emit_negotiate_version();

    libspdm_return_t status = LIBSPDM_STATUS_SUCCESS;
    for (int i = 0; i < 3; i++) {
        uint8_t  meas_rec[1024] = {0};
        uint32_t meas_rec_len = sizeof(meas_rec);
        uint8_t  blocks = 0;
        uint8_t  content_changed = 0;
        status = libspdm_get_measurement(
            req_ctx, NULL,
            SPDM_GET_MEASUREMENTS_REQUEST_ATTRIBUTES_GENERATE_SIGNATURE,
            SPDM_GET_MEASUREMENTS_REQUEST_MEASUREMENT_OPERATION_ALL_MEASUREMENTS,
            0, &content_changed, &blocks, &meas_rec_len, meas_rec);
        printf("[scenario_sig] iter=%d status=0x%x blocks=%u len=%u\n",
               i, (unsigned)status, (unsigned)blocks, (unsigned)meas_rec_len);
        if (LIBSPDM_STATUS_IS_ERROR(status)) break;
    }

    free(req_scratch); free(rsp_scratch); free(req_ctx); free(rsp_ctx);
    tla_trace_fini();
    return LIBSPDM_STATUS_IS_ERROR(status) ? -1 : 0;
}

/* ====================================================================
   Scenario 3: trace_reset.ndjson
   4 nosig exchanges then reset_context (exercises ResetContext).
   Events: 1 negotiate_version + 4 × 5 nosig events + 1 reset_context = 22
   ==================================================================== */
static int scenario_reset(const char *trace_path)
{
    printf("[scenario_reset] -> %s\n", trace_path);
    tla_trace_init(trace_path);

    uint8_t *req_scratch, *rsp_scratch;
    libspdm_context_t *req_ctx = setup_requester(&req_scratch);
    libspdm_context_t *rsp_ctx = setup_responder(&rsp_scratch);
    if (!req_ctx || !rsp_ctx) return -1;

    g_rsp_ctx = rsp_ctx;
    emit_negotiate_version();

    static const uint8_t ops[] = {
        SPDM_GET_MEASUREMENTS_REQUEST_MEASUREMENT_OPERATION_TOTAL_NUMBER_OF_MEASUREMENTS,
        1, 2, 3
    };
    for (int i = 0; i < 4; i++) {
        uint8_t meas_rec[1024] = {0};
        uint32_t meas_rec_len = sizeof(meas_rec);
        uint8_t blocks = 0;
        libspdm_get_measurement(req_ctx, NULL, 0, ops[i], 0,
                                NULL, &blocks, &meas_rec_len, meas_rec);
    }

    /* perform reset — fires reset_context event */
    libspdm_reset_context(rsp_ctx);
    printf("[scenario_reset] context reset OK\n");

    free(req_scratch); free(rsp_scratch); free(req_ctx); free(rsp_ctx);
    tla_trace_fini();
    return 0;
}

/* ====================================================================
   Scenario 4: trace_resync.ndjson
   4 nosig exchanges then one NEED_RESYNC exchange.
   Events: 1 negotiate_version + 4 × 5 nosig + (requester_send + need_resync +
           complete_exchange) = 24 events
   ==================================================================== */
static int scenario_resync(const char *trace_path)
{
    printf("[scenario_resync] -> %s\n", trace_path);
    tla_trace_init(trace_path);

    uint8_t *req_scratch, *rsp_scratch;
    libspdm_context_t *req_ctx = setup_requester(&req_scratch);
    libspdm_context_t *rsp_ctx = setup_responder(&rsp_scratch);
    if (!req_ctx || !rsp_ctx) return -1;

    g_rsp_ctx = rsp_ctx;
    emit_negotiate_version();

    /* 4 normal nosig exchanges first */
    static const uint8_t ops[] = {
        SPDM_GET_MEASUREMENTS_REQUEST_MEASUREMENT_OPERATION_TOTAL_NUMBER_OF_MEASUREMENTS,
        1, 2, 3
    };
    for (int i = 0; i < 4; i++) {
        uint8_t meas_rec[1024] = {0};
        uint32_t meas_rec_len = sizeof(meas_rec);
        uint8_t blocks = 0;
        libspdm_get_measurement(req_ctx, NULL, 0, ops[i], 0,
                                NULL, &blocks, &meas_rec_len, meas_rec);
    }

    /* Force responder into NEED_RESYNC state */
    rsp_ctx->response_state = LIBSPDM_RESPONSE_STATE_NEED_RESYNC;

    uint8_t  meas_rec[1024] = {0};
    uint32_t meas_rec_len = sizeof(meas_rec);
    uint8_t  number_of_blocks = 0;

    libspdm_return_t status = libspdm_get_measurement(
        req_ctx, NULL, 0,
        SPDM_GET_MEASUREMENTS_REQUEST_MEASUREMENT_OPERATION_TOTAL_NUMBER_OF_MEASUREMENTS,
        0, NULL, &number_of_blocks, &meas_rec_len, meas_rec);

    printf("[scenario_resync] status=0x%x (expected error)\n", (unsigned)status);

    free(req_scratch); free(rsp_scratch); free(req_ctx); free(rsp_ctx);
    tla_trace_fini();
    return 0; /* error expected */
}

/* ====================================================================
   main
   ==================================================================== */
int main(int argc, char *argv[])
{
    const char *trace_dir = ".";
    if (argc > 1) trace_dir = argv[1];

    /* Load cert chain once */
    {
        libspdm_context_t *tmp = malloc(libspdm_get_context_size());
        libspdm_init_context(tmp);
        if (!load_cert_chain(tmp)) { free(tmp); return 1; }
        free(tmp);
    }

    char path[512];
    int rc = 0;

    snprintf(path, sizeof(path), "%s/trace_nosig.ndjson", trace_dir);
    rc |= scenario_nosig(path);

    snprintf(path, sizeof(path), "%s/trace_sig.ndjson", trace_dir);
    rc |= scenario_sig(path);

    snprintf(path, sizeof(path), "%s/trace_reset.ndjson", trace_dir);
    rc |= scenario_reset(path);

    snprintf(path, sizeof(path), "%s/trace_resync.ndjson", trace_dir);
    rc |= scenario_resync(path);

    if (rc == 0) {
        printf("\nAll scenarios completed. Traces written to %s/\n", trace_dir);
    } else {
        printf("\nSome scenarios failed (rc=%d)\n", rc);
    }
    return rc;
}
