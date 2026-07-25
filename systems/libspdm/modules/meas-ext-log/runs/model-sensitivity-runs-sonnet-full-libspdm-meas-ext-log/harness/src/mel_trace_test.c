/**
 * Standalone MEL trace test binary.
 *
 * Exercises four protocol paths through real libspdm requester + responder code:
 *  1. negotiate_no_session_cap  -> 1 negotiate_algorithms event (no PSK/KEY_EX cap)
 *  2. negotiate_session_cap     -> 1 negotiate_algorithms event (PSK cap set)
 *  3. single_chunk              -> send/respond/process first-chunk (MEL fits in one block)
 *  4. multi_chunk               -> two-chunk transfer with mel_update
 *
 * Each scenario writes to traces/<name>.ndjson.
 *
 * Build: added to test_spdm_requester CMakeLists.txt as a separate executable target.
 * Transport: test transport (LIBSPDM_TEST_TRANSPORT_HEADER_SIZE = 12 bytes header).
 */

#include "spdm_unit_test.h"
#include "internal/libspdm_requester_lib.h"
#include "internal/libspdm_responder_lib.h"
#include "library/spdm_transport_test_lib.h"
#include "tla_trace.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

#define MEL_TRACE_MAX_MSG 65536

/* ================================================================
 * Globals
 * ================================================================ */

/* Responder context - properly sized via libspdm_get_context_size() */
static void *g_rsp_ctx_buf = NULL;
#define g_rsp_ctx ((libspdm_context_t *)g_rsp_ctx_buf)

/* Scratch buffers */
static uint8_t g_rsp_scratch[MEL_TRACE_MAX_MSG * 2];
static uint8_t g_req_scratch[MEL_TRACE_MAX_MSG * 2];

/* ================================================================
 * Context initialisation helpers
 * ================================================================ */

extern libspdm_return_t spdm_device_acquire_sender_buffer(void *context, void **msg_buf_ptr);
extern void spdm_device_release_sender_buffer(void *context, const void *msg_buf_ptr);
extern libspdm_return_t spdm_device_acquire_receiver_buffer(void *context, void **msg_buf_ptr);
extern void spdm_device_release_receiver_buffer(void *context, const void *msg_buf_ptr);

static void init_req_ctx(libspdm_context_t *ctx,
                         libspdm_device_send_message_func    send_fn,
                         libspdm_device_receive_message_func recv_fn,
                         uint32_t max_spdm_msg_size)
{
    libspdm_init_context(ctx);
    libspdm_register_transport_layer_func(ctx,
        max_spdm_msg_size,
        LIBSPDM_TEST_TRANSPORT_HEADER_SIZE,
        LIBSPDM_TEST_TRANSPORT_TAIL_SIZE,
        libspdm_transport_test_encode_message,
        libspdm_transport_test_decode_message);
    libspdm_register_device_io_func(ctx, send_fn, recv_fn);
    libspdm_register_device_buffer_func(ctx,
        MEL_TRACE_MAX_MSG, MEL_TRACE_MAX_MSG,
        spdm_device_acquire_sender_buffer,
        spdm_device_release_sender_buffer,
        spdm_device_acquire_receiver_buffer,
        spdm_device_release_receiver_buffer);
    libspdm_set_scratch_buffer(ctx, g_req_scratch, sizeof(g_req_scratch));
}

static void init_rsp_ctx(libspdm_context_t *ctx)
{
    libspdm_init_context(ctx);
    ctx->connection_info.version =
        SPDM_MESSAGE_VERSION_13 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    ctx->connection_info.connection_state = LIBSPDM_CONNECTION_STATE_NEGOTIATED;
    ctx->response_state = LIBSPDM_RESPONSE_STATE_NORMAL;

    ctx->connection_info.capability.flags =
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MEL_CAP |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MEAS_CAP;
    ctx->local_context.capability.flags =
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MEL_CAP |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MEAS_CAP;
    ctx->local_context.capability.sender_data_transfer_size = LIBSPDM_MAX_SPDM_MSG_SIZE;
    ctx->local_context.capability.max_spdm_msg_size = LIBSPDM_MAX_SPDM_MSG_SIZE;

    ctx->connection_info.algorithm.mel_spec         = SPDM_MEL_SPECIFICATION_DMTF;
    ctx->connection_info.algorithm.measurement_spec = SPDM_MEASUREMENT_SPECIFICATION_DMTF;
    ctx->connection_info.algorithm.measurement_hash_algo =
        SPDM_ALGORITHMS_MEASUREMENT_HASH_ALGO_TPM_ALG_SHA_384;
    ctx->connection_info.algorithm.base_hash_algo  =
        SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256;

    libspdm_set_scratch_buffer(ctx, g_rsp_scratch, sizeof(g_rsp_scratch));
}

/* ================================================================
 * Transport callbacks: dummy send, real-responder receive
 * ================================================================ */

static libspdm_return_t mel_send_message(void *spdm_context,
    size_t request_size, const void *request, uint64_t timeout)
{
    (void)spdm_context; (void)request_size; (void)request; (void)timeout;
    return LIBSPDM_STATUS_SUCCESS;
}

/*
 * mel_receive_message:
 * Forward the requester's last request to the real responder,
 * then return the encoded response.
 */
static libspdm_return_t mel_receive_message(void *spdm_context,
    size_t *response_size, void **response, uint64_t timeout)
{
    libspdm_context_t *rc = (libspdm_context_t *)spdm_context;
    (void)timeout;

    const void *spdm_req      = rc->last_spdm_request;
    size_t      spdm_req_size = rc->last_spdm_request_size;

    uint8_t    *resp_start = (uint8_t *)*response + LIBSPDM_TEST_TRANSPORT_HEADER_SIZE;
    size_t      resp_cap   = *response_size - LIBSPDM_TEST_TRANSPORT_HEADER_SIZE;
    size_t      resp_len   = resp_cap;

    libspdm_return_t st = libspdm_get_response_measurement_extension_log(
        g_rsp_ctx, spdm_req_size, spdm_req, &resp_len, resp_start);
    if (LIBSPDM_STATUS_IS_ERROR(st)) {
        return LIBSPDM_STATUS_RECEIVE_FAIL;
    }

    libspdm_transport_test_encode_message(spdm_context, NULL, false, false,
                                         resp_len, resp_start,
                                         response_size, response);
    return LIBSPDM_STATUS_SUCCESS;
}

/* ================================================================
 * Scenario 3: single-chunk MEL transfer
 * MEL = 54 bytes, chunk_size = 1024 -> all bytes in one chunk.
 * Events: send_get_mel_first_chunk, respond_get_mel_first_chunk,
 *         process_mel_first_chunk_resp
 * ================================================================ */

static void run_single_chunk(const char *trace_path)
{
    void *req_ctx_buf = malloc(libspdm_get_context_size());
    libspdm_context_t *req_ctx = (libspdm_context_t *)req_ctx_buf;
    libspdm_return_t  status;
    uint8_t mel_buf[4096];
    size_t  mel_size = sizeof(mel_buf);

    tla_trace_open(trace_path);

    init_req_ctx(req_ctx, mel_send_message, mel_receive_message,
                 LIBSPDM_MAX_SPDM_MSG_SIZE);
    init_rsp_ctx(g_rsp_ctx);

    req_ctx->connection_info.version =
        SPDM_MESSAGE_VERSION_13 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    req_ctx->connection_info.connection_state = LIBSPDM_CONNECTION_STATE_AUTHENTICATED;
    req_ctx->connection_info.capability.flags =
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MEL_CAP |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MEAS_CAP;
    req_ctx->local_context.capability.flags = 0;
    req_ctx->local_context.capability.transport_header_size =
        LIBSPDM_TEST_TRANSPORT_HEADER_SIZE;
    req_ctx->local_context.capability.transport_tail_size =
        LIBSPDM_TEST_TRANSPORT_TAIL_SIZE;

    req_ctx->connection_info.algorithm.measurement_spec =
        SPDM_MEASUREMENT_SPECIFICATION_DMTF;
    req_ctx->connection_info.algorithm.measurement_hash_algo =
        SPDM_ALGORITHMS_MEASUREMENT_HASH_ALGO_TPM_ALG_SHA_384;
    req_ctx->connection_info.algorithm.base_hash_algo =
        SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256;
    req_ctx->connection_info.algorithm.mel_spec = SPDM_MEL_SPECIFICATION_DMTF;
    req_ctx->local_context.algorithm.mel_spec   = SPDM_MEL_SPECIFICATION_DMTF;
    req_ctx->local_context.algorithm.measurement_spec =
        SPDM_MEASUREMENT_SPECIFICATION_DMTF;

    libspdm_reset_message_b(req_ctx);
    libspdm_zero_mem(mel_buf, sizeof(mel_buf));

    status = libspdm_get_measurement_extension_log(req_ctx, NULL, &mel_size, mel_buf);
    if (LIBSPDM_STATUS_IS_ERROR(status)) {
        fprintf(stderr, "[single_chunk] FAILED: 0x%x\n", (unsigned)status);
    }

    tla_trace_close();
    free(req_ctx_buf);
}

/* ================================================================
 * Scenario 4: multi-chunk MEL transfer (6 chunks) with mel_update
 * MEL = 63 bytes. max_spdm_msg_size = 24 -> length = 12 per request.
 * Chunk 1: portion=12, remainder=51
 * mel_update fires on each subsequent HAL call (offset>0 request)
 * Chunk 6: portion=3, remainder=0
 * Events per chunk-after-first: send_next, mel_update, respond_next, process_next
 * Total: 3 + 5*4 = 23 events
 * ================================================================ */

static void run_multi_chunk(const char *trace_path)
{
    void *req_ctx_buf = malloc(libspdm_get_context_size());
    libspdm_context_t *req_ctx = (libspdm_context_t *)req_ctx_buf;
    libspdm_return_t  status;
    uint8_t mel_buf[4096];
    size_t  mel_size = sizeof(mel_buf);

    tla_trace_open(trace_path);

    /* max_spdm_msg_size=24 forces 6-chunk transfer:
     * req_length = 24 - sizeof(spdm_measurement_extension_log_response_t) = 24-12 = 12
     * MEL total = 63 bytes -> 5 full chunks of 12 + 1 chunk of 3 */
    init_req_ctx(req_ctx, mel_send_message, mel_receive_message, 24);
    init_rsp_ctx(g_rsp_ctx);

    req_ctx->connection_info.version =
        SPDM_MESSAGE_VERSION_13 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    req_ctx->connection_info.connection_state = LIBSPDM_CONNECTION_STATE_AUTHENTICATED;
    req_ctx->connection_info.capability.flags =
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MEL_CAP |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MEAS_CAP;
    req_ctx->local_context.capability.flags = 0;
    req_ctx->local_context.capability.transport_header_size =
        LIBSPDM_TEST_TRANSPORT_HEADER_SIZE;
    req_ctx->local_context.capability.transport_tail_size =
        LIBSPDM_TEST_TRANSPORT_TAIL_SIZE;

    req_ctx->connection_info.algorithm.measurement_spec =
        SPDM_MEASUREMENT_SPECIFICATION_DMTF;
    req_ctx->connection_info.algorithm.measurement_hash_algo =
        SPDM_ALGORITHMS_MEASUREMENT_HASH_ALGO_TPM_ALG_SHA_384;
    req_ctx->connection_info.algorithm.base_hash_algo =
        SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256;
    req_ctx->connection_info.algorithm.mel_spec = SPDM_MEL_SPECIFICATION_DMTF;
    req_ctx->local_context.algorithm.mel_spec   = SPDM_MEL_SPECIFICATION_DMTF;
    req_ctx->local_context.algorithm.measurement_spec =
        SPDM_MEASUREMENT_SPECIFICATION_DMTF;

    libspdm_reset_message_b(req_ctx);
    libspdm_zero_mem(mel_buf, sizeof(mel_buf));

    status = libspdm_get_measurement_extension_log(req_ctx, NULL, &mel_size, mel_buf);
    if (LIBSPDM_STATUS_IS_ERROR(status)) {
        fprintf(stderr, "[multi_chunk] FAILED: 0x%x\n", (unsigned)status);
    }

    tla_trace_close();
    free(req_ctx_buf);
}

/* ================================================================
 * Negotiate_algorithms transport callbacks
 * ================================================================ */

/* negotiate_algorithms response for has_session_cap=false:
 * SPDM 1.3, no KEY_EX/PSK flags, mel_spec=DMTF, 0 struct tables */
static libspdm_return_t nego_no_session_cap_receive(void *spdm_context,
    size_t *response_size, void **response, uint64_t timeout)
{
    (void)timeout;
    spdm_algorithms_response_t *rsp;
    size_t rsp_size = sizeof(spdm_algorithms_response_t);
    rsp = (void *)((uint8_t *)*response + LIBSPDM_TEST_TRANSPORT_HEADER_SIZE);

    libspdm_zero_mem(rsp, rsp_size);
    rsp->header.spdm_version         = SPDM_MESSAGE_VERSION_13;
    rsp->header.request_response_code = SPDM_ALGORITHMS;
    rsp->header.param1                = 0;
    rsp->header.param2                = 0;
    rsp->length                       = (uint16_t)rsp_size;
    rsp->measurement_specification_sel = SPDM_MEASUREMENT_SPECIFICATION_DMTF;
    rsp->measurement_hash_algo        =
        SPDM_ALGORITHMS_MEASUREMENT_HASH_ALGO_TPM_ALG_SHA_384;
    rsp->base_asym_sel                =
        SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_ECDSA_ECC_NIST_P256;
    rsp->base_hash_sel                =
        SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256;
    rsp->ext_asym_sel_count           = 0;
    rsp->ext_hash_sel_count           = 0;
    rsp->mel_specification_sel        = SPDM_MEL_SPECIFICATION_DMTF;

    libspdm_transport_test_encode_message(spdm_context, NULL, false, false,
                                         rsp_size, rsp,
                                         response_size, response);
    return LIBSPDM_STATUS_SUCCESS;
}

static libspdm_return_t nego_send_message(void *spdm_context,
    size_t request_size, const void *request, uint64_t timeout)
{
    (void)spdm_context; (void)request_size; (void)request; (void)timeout;
    return LIBSPDM_STATUS_SUCCESS;
}

/* negotiate_algorithms response for has_session_cap=true:
 * SPDM 1.3, PSK_CAP set, mel_spec=DMTF, 4 struct tables (DHE/AEAD/REQ_ASYM/KEY_SCHED) */
#pragma pack(1)
typedef struct {
    spdm_message_header_t header;
    uint16_t length;
    uint8_t measurement_specification_sel;
    uint8_t other_params_selection;
    uint32_t measurement_hash_algo;
    uint32_t base_asym_sel;
    uint32_t base_hash_sel;
    uint8_t reserved2[11];
    uint8_t mel_specification_sel;
    uint8_t ext_asym_sel_count;
    uint8_t ext_hash_sel_count;
    uint16_t reserved3;
    spdm_negotiate_algorithms_common_struct_table_t struct_table[4];
} mel_trace_algorithms_response_t;
#pragma pack()

static libspdm_return_t nego_session_cap_receive(void *spdm_context,
    size_t *response_size, void **response, uint64_t timeout)
{
    (void)timeout;
    mel_trace_algorithms_response_t *rsp;
    size_t rsp_size = sizeof(mel_trace_algorithms_response_t);
    rsp = (void *)((uint8_t *)*response + LIBSPDM_TEST_TRANSPORT_HEADER_SIZE);

    libspdm_zero_mem(rsp, rsp_size);
    rsp->header.spdm_version          = SPDM_MESSAGE_VERSION_13;
    rsp->header.request_response_code = SPDM_ALGORITHMS;
    rsp->header.param1                = 4;
    rsp->header.param2                = 0;
    rsp->length                       = (uint16_t)rsp_size;
    rsp->measurement_specification_sel = SPDM_MEASUREMENT_SPECIFICATION_DMTF;
    rsp->measurement_hash_algo        =
        SPDM_ALGORITHMS_MEASUREMENT_HASH_ALGO_TPM_ALG_SHA_384;
    rsp->base_asym_sel                =
        SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_ECDSA_ECC_NIST_P256;
    rsp->base_hash_sel                =
        SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256;
    rsp->ext_asym_sel_count           = 0;
    rsp->ext_hash_sel_count           = 0;
    rsp->mel_specification_sel        = SPDM_MEL_SPECIFICATION_DMTF;
    rsp->other_params_selection       = SPDM_ALGORITHMS_OPAQUE_DATA_FORMAT_1;

    rsp->struct_table[0].alg_type     =
        SPDM_NEGOTIATE_ALGORITHMS_STRUCT_TABLE_ALG_TYPE_DHE;
    rsp->struct_table[0].alg_count    = 0x20;
    rsp->struct_table[0].alg_supported =
        SPDM_ALGORITHMS_DHE_NAMED_GROUP_SECP_256_R1;

    rsp->struct_table[1].alg_type     =
        SPDM_NEGOTIATE_ALGORITHMS_STRUCT_TABLE_ALG_TYPE_AEAD;
    rsp->struct_table[1].alg_count    = 0x20;
    rsp->struct_table[1].alg_supported =
        SPDM_ALGORITHMS_AEAD_CIPHER_SUITE_AES_256_GCM;

    rsp->struct_table[2].alg_type     =
        SPDM_NEGOTIATE_ALGORITHMS_STRUCT_TABLE_ALG_TYPE_REQ_BASE_ASYM_ALG;
    rsp->struct_table[2].alg_count    = 0x20;
    rsp->struct_table[2].alg_supported =
        SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_RSASSA_2048;

    rsp->struct_table[3].alg_type     =
        SPDM_NEGOTIATE_ALGORITHMS_STRUCT_TABLE_ALG_TYPE_KEY_SCHEDULE;
    rsp->struct_table[3].alg_count    = 0x20;
    rsp->struct_table[3].alg_supported = SPDM_ALGORITHMS_KEY_SCHEDULE_SPDM;

    libspdm_transport_test_encode_message(spdm_context, NULL, false, false,
                                         rsp_size, rsp,
                                         response_size, response);
    return LIBSPDM_STATUS_SUCCESS;
}

/* ================================================================
 * Scenario 1: negotiate_algorithms, no session cap
 * ================================================================ */

static void run_negotiate_no_session_cap(const char *trace_path)
{
    void *req_ctx_buf = malloc(libspdm_get_context_size());
    libspdm_context_t *req_ctx = (libspdm_context_t *)req_ctx_buf;
    libspdm_return_t  status;

    tla_trace_open(trace_path);

    init_req_ctx(req_ctx, nego_send_message, nego_no_session_cap_receive,
                 LIBSPDM_MAX_SPDM_MSG_SIZE);

    req_ctx->connection_info.version =
        SPDM_MESSAGE_VERSION_13 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    req_ctx->connection_info.connection_state =
        LIBSPDM_CONNECTION_STATE_AFTER_CAPABILITIES;
    req_ctx->connection_info.capability.flags =
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MEAS_CAP |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MEL_CAP;
    /* No KEY_EX/PSK -> has_session_cap = false */
    req_ctx->local_context.capability.flags =
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_CERT_CAP;
    req_ctx->local_context.capability.transport_header_size =
        LIBSPDM_TEST_TRANSPORT_HEADER_SIZE;
    req_ctx->local_context.capability.transport_tail_size =
        LIBSPDM_TEST_TRANSPORT_TAIL_SIZE;

    req_ctx->local_context.algorithm.measurement_spec =
        SPDM_MEASUREMENT_SPECIFICATION_DMTF;
    req_ctx->local_context.algorithm.measurement_hash_algo =
        SPDM_ALGORITHMS_MEASUREMENT_HASH_ALGO_TPM_ALG_SHA_384;
    req_ctx->local_context.algorithm.base_hash_algo =
        SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256;
    req_ctx->local_context.algorithm.base_asym_algo =
        SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_ECDSA_ECC_NIST_P256;
    req_ctx->local_context.algorithm.mel_spec = SPDM_MEL_SPECIFICATION_DMTF;

    libspdm_reset_message_a(req_ctx);

    status = libspdm_negotiate_algorithms(req_ctx);
    if (LIBSPDM_STATUS_IS_ERROR(status)) {
        fprintf(stderr, "[nego_no_session_cap] FAILED: 0x%x\n", (unsigned)status);
    }

    tla_trace_close();
    free(req_ctx_buf);
}

/* ================================================================
 * Scenario 2: negotiate_algorithms, session cap (PSK)
 * ================================================================ */

static void run_negotiate_session_cap(const char *trace_path)
{
    void *req_ctx_buf = malloc(libspdm_get_context_size());
    libspdm_context_t *req_ctx = (libspdm_context_t *)req_ctx_buf;
    libspdm_return_t  status;

    tla_trace_open(trace_path);

    init_req_ctx(req_ctx, nego_send_message, nego_session_cap_receive,
                 LIBSPDM_MAX_SPDM_MSG_SIZE);

    req_ctx->connection_info.version =
        SPDM_MESSAGE_VERSION_13 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    req_ctx->connection_info.connection_state =
        LIBSPDM_CONNECTION_STATE_AFTER_CAPABILITIES;

    /* PSK_CAP set on both sides -> has_session_cap = true */
    req_ctx->local_context.capability.flags =
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_PSK_CAP |
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_CERT_CAP |
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_ENCRYPT_CAP |
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_MAC_CAP;
    req_ctx->connection_info.capability.flags =
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_PSK_CAP |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MEAS_CAP |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_ENCRYPT_CAP |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MAC_CAP |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MEL_CAP;
    req_ctx->local_context.capability.transport_header_size =
        LIBSPDM_TEST_TRANSPORT_HEADER_SIZE;
    req_ctx->local_context.capability.transport_tail_size =
        LIBSPDM_TEST_TRANSPORT_TAIL_SIZE;

    req_ctx->local_context.algorithm.measurement_spec =
        SPDM_MEASUREMENT_SPECIFICATION_DMTF;
    req_ctx->local_context.algorithm.measurement_hash_algo =
        SPDM_ALGORITHMS_MEASUREMENT_HASH_ALGO_TPM_ALG_SHA_384;
    req_ctx->local_context.algorithm.base_hash_algo =
        SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256;
    req_ctx->local_context.algorithm.base_asym_algo =
        SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_ECDSA_ECC_NIST_P256;
    req_ctx->local_context.algorithm.dhe_named_group =
        SPDM_ALGORITHMS_DHE_NAMED_GROUP_SECP_256_R1;
    req_ctx->local_context.algorithm.aead_cipher_suite =
        SPDM_ALGORITHMS_AEAD_CIPHER_SUITE_AES_256_GCM;
    req_ctx->local_context.algorithm.req_base_asym_alg =
        SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_RSASSA_2048;
    req_ctx->local_context.algorithm.key_schedule =
        SPDM_ALGORITHMS_KEY_SCHEDULE_SPDM;
    req_ctx->local_context.algorithm.mel_spec = SPDM_MEL_SPECIFICATION_DMTF;
    req_ctx->local_context.algorithm.other_params_support =
        SPDM_ALGORITHMS_OPAQUE_DATA_FORMAT_1;

    libspdm_reset_message_a(req_ctx);

    status = libspdm_negotiate_algorithms(req_ctx);
    if (LIBSPDM_STATUS_IS_ERROR(status)) {
        fprintf(stderr, "[nego_session_cap] FAILED: 0x%x\n", (unsigned)status);
    }

    tla_trace_close();
    free(req_ctx_buf);
}

/* ================================================================
 * main
 * ================================================================ */

int main(int argc, char *argv[])
{
    const char *out_dir = "traces";
    char path[512];

    if (argc > 1) {
        out_dir = argv[1];
    }

    /* Allocate properly-sized responder context */
    g_rsp_ctx_buf = malloc(libspdm_get_context_size());
    if (!g_rsp_ctx_buf) {
        fprintf(stderr, "ERROR: malloc failed for rsp_ctx\n");
        return 1;
    }

    /* Create output directory (ignore error if already exists) */
    char mkdir_cmd[600];
    snprintf(mkdir_cmd, sizeof(mkdir_cmd), "mkdir -p %s", out_dir);
    (void)system(mkdir_cmd);

    snprintf(path, sizeof(path), "%s/trace_negotiate_no_session_cap.ndjson", out_dir);
    run_negotiate_no_session_cap(path);

    snprintf(path, sizeof(path), "%s/trace_negotiate_session_cap.ndjson", out_dir);
    run_negotiate_session_cap(path);

    snprintf(path, sizeof(path), "%s/trace_single_chunk.ndjson", out_dir);
    run_single_chunk(path);

    snprintf(path, sizeof(path), "%s/trace_multi_chunk.ndjson", out_dir);
    run_multi_chunk(path);

    free(g_rsp_ctx_buf);
    return 0;
}
