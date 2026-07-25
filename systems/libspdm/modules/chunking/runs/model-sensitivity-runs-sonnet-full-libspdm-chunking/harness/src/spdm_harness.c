/**
 * spdm_harness.c — Test scenarios for libspdm chunking trace collection.
 *
 * Scenarios:
 *   1. chunk_send_normal    — Requester sends 300-byte message via CHUNK_SEND (11 chunks)
 *   2. chunk_send_invalid_seq — CHUNK_SEND with wrong seq-no (Family 2 bug path)
 *   3. chunk_get_normal     — Requester retrieves 300-byte response via CHUNK_GET
 *   4. chunk_get_overflow   — CHUNK_GET where large_size > response_capacity (Family 3)
 *
 * Each scenario produces one .ndjson trace file.
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>

#include "internal/libspdm_common_lib.h"
#include "spdm_trace.h"

/* ----------------------------------------------------------------
 * Forward declarations (from instrumented source files)
 * ---------------------------------------------------------------- */
extern libspdm_return_t libspdm_get_response_chunk_send(
    libspdm_context_t *spdm_context,
    size_t request_size, const void *request,
    size_t *response_size, void *response);

extern libspdm_return_t libspdm_get_response_chunk_get(
    libspdm_context_t *spdm_context,
    size_t request_size, const void *request,
    size_t *response_size, void *response);

extern libspdm_return_t libspdm_handle_error_large_response(
    libspdm_context_t *spdm_context,
    const uint32_t *session_id,
    size_t *inout_response_size,
    void *inout_response,
    size_t response_capacity,
    bool response_from_chunk);

extern void spdm_test_setup_context(
    libspdm_context_t *ctx,
    libspdm_context_t *requester,
    libspdm_context_t *responder,
    uint32_t data_transfer_size);

extern libspdm_context_t *g_requester_ctx;
extern libspdm_context_t *g_responder_ctx;
extern bool g_inject_oob_first;

/* ----------------------------------------------------------------
 * Test parameters
 * ---------------------------------------------------------------- */
#define DATA_TRANSFER_SIZE  44u       /* bytes per transport message */
#define LARGE_MSG_SIZE      300u      /* bytes in the large message/response */
#define RESPONSE_BUF_SIZE   512u      /* response assembly buffer */
/* For overflow test: capacity smaller than large_response_size */
#define OVERFLOW_CAPACITY   50u

/* ----------------------------------------------------------------
 * CHUNK_SEND helpers
 * ---------------------------------------------------------------- */

/* sizeof(spdm_chunk_send_request_t) = 12, plus 4 for LargeMessageSize on first chunk */
#define CHUNK_SEND_HEADER_SIZE   12u
#define CHUNK_SEND_FIRST_EXTRA    4u  /* uint32_t large_message_size */

/* Max payload per chunk (pre-1.4) */
#define CHUNK_SEND_FIRST_PAYLOAD  (DATA_TRANSFER_SIZE - CHUNK_SEND_HEADER_SIZE - CHUNK_SEND_FIRST_EXTRA)
#define CHUNK_SEND_SUBSEQ_PAYLOAD (DATA_TRANSFER_SIZE - CHUNK_SEND_HEADER_SIZE)

static void make_chunk_send_first(
    uint8_t *buf, size_t *size,
    uint8_t handle, uint32_t large_message_size,
    const uint8_t *data, uint32_t chunk_size)
{
    spdm_chunk_send_request_t *req = (spdm_chunk_send_request_t *)buf;
    req->header.spdm_version = SPDM_MESSAGE_VERSION_12;
    req->header.request_response_code = SPDM_CHUNK_SEND;
    req->header.param1 = 0; /* not last chunk */
    req->header.param2 = handle;
    req->chunk_seq_no  = 0;
    req->chunk_size    = chunk_size;
    /* uint32_t large_message_size follows the header */
    uint32_t *lms_field = (uint32_t *)(req + 1);
    *lms_field = large_message_size;
    /* chunk data follows */
    uint8_t *payload = (uint8_t *)(lms_field + 1);
    memcpy(payload, data, chunk_size);
    *size = CHUNK_SEND_HEADER_SIZE + CHUNK_SEND_FIRST_EXTRA + chunk_size;
}

static void make_chunk_send_next(
    uint8_t *buf, size_t *size,
    uint8_t handle, uint32_t seq_no, bool is_last,
    const uint8_t *data, uint32_t chunk_size)
{
    spdm_chunk_send_request_t *req = (spdm_chunk_send_request_t *)buf;
    req->header.spdm_version = SPDM_MESSAGE_VERSION_12;
    req->header.request_response_code = SPDM_CHUNK_SEND;
    req->header.param1 = is_last ? SPDM_CHUNK_SEND_REQUEST_ATTRIBUTE_LAST_CHUNK : 0;
    req->header.param2 = handle;
    req->chunk_seq_no  = (uint16_t)seq_no;
    req->chunk_size    = chunk_size;
    uint8_t *payload = (uint8_t *)(req + 1);
    memcpy(payload, data, chunk_size);
    *size = CHUNK_SEND_HEADER_SIZE + chunk_size;
}

/* ----------------------------------------------------------------
 * Scenario 1: Normal CHUNK_SEND
 * ---------------------------------------------------------------- */
static void run_chunk_send_normal(const char *trace_path)
{
    spdm_trace_init(trace_path);

    libspdm_context_t rsp_ctx;
    spdm_test_setup_context(&rsp_ctx, NULL, &rsp_ctx, DATA_TRANSFER_SIZE);

    /* Build a 300-byte large message (all 0xAA) */
    uint8_t large_msg[LARGE_MSG_SIZE];
    memset(large_msg, 0xAA, sizeof(large_msg));

    uint8_t req_buf[512];
    uint8_t rsp_buf[512];
    size_t rsp_size;
    uint32_t seq = 0;
    uint32_t offset = 0;
    bool done = false;

    while (!done) {
        size_t req_size = 0;
        uint32_t remaining = LARGE_MSG_SIZE - offset;
        uint32_t chunk_size;
        bool is_last;

        if (seq == 0) {
            chunk_size = CHUNK_SEND_FIRST_PAYLOAD;
            if (chunk_size > remaining) chunk_size = remaining;
            is_last = (chunk_size == remaining);
            make_chunk_send_first(req_buf, &req_size, 1,
                                  LARGE_MSG_SIZE, large_msg + offset, chunk_size);
            if (is_last) req_buf[2] |= SPDM_CHUNK_SEND_REQUEST_ATTRIBUTE_LAST_CHUNK;
        } else {
            chunk_size = CHUNK_SEND_SUBSEQ_PAYLOAD;
            if (chunk_size > remaining) chunk_size = remaining;
            is_last = (chunk_size == remaining);
            make_chunk_send_next(req_buf, &req_size, 1, seq, is_last,
                                 large_msg + offset, chunk_size);
        }

        rsp_size = sizeof(rsp_buf);
        libspdm_return_t st = libspdm_get_response_chunk_send(
            &rsp_ctx, req_size, req_buf, &rsp_size, rsp_buf);
        (void)st;

        offset += chunk_size;
        seq++;
        done = (offset >= LARGE_MSG_SIZE);
    }

    spdm_trace_close();
    printf("  [chunk_send_normal] events written, offset=%u seq=%u\n", offset, seq);
}

/* ----------------------------------------------------------------
 * Scenario 2: CHUNK_SEND with invalid seq-no (Family 2)
 * ---------------------------------------------------------------- */
static void run_chunk_send_invalid_seq(const char *trace_path)
{
    spdm_trace_init(trace_path);

    libspdm_context_t rsp_ctx;
    spdm_test_setup_context(&rsp_ctx, NULL, &rsp_ctx, DATA_TRANSFER_SIZE);

    uint8_t large_msg[LARGE_MSG_SIZE];
    memset(large_msg, 0xBB, sizeof(large_msg));

    uint8_t req_buf[512];
    uint8_t rsp_buf[512];
    size_t rsp_size;

    /* First chunk (valid) */
    size_t req_size = 0;
    make_chunk_send_first(req_buf, &req_size, 2,
                          LARGE_MSG_SIZE, large_msg, CHUNK_SEND_FIRST_PAYLOAD);
    rsp_size = sizeof(rsp_buf);
    libspdm_get_response_chunk_send(&rsp_ctx, req_size, req_buf, &rsp_size, rsp_buf);

    /* Second chunk with WRONG seq-no (should be 1, sending 5) */
    uint32_t wrong_seq = 5;
    make_chunk_send_next(req_buf, &req_size, 2, wrong_seq, false,
                         large_msg + CHUNK_SEND_FIRST_PAYLOAD, CHUNK_SEND_SUBSEQ_PAYLOAD);
    rsp_size = sizeof(rsp_buf);
    libspdm_get_response_chunk_send(&rsp_ctx, req_size, req_buf, &rsp_size, rsp_buf);

    /* Send a few more valid chunks to fill trace */
    /* After error, send_info gets reset; try sending a fresh large message */
    spdm_test_setup_context(&rsp_ctx, NULL, &rsp_ctx, DATA_TRANSFER_SIZE);
    memset(large_msg, 0xCC, sizeof(large_msg));

    uint32_t offset = 0, seq = 0;
    bool done = false;
    while (!done) {
        size_t req_size2 = 0;
        uint32_t remaining = LARGE_MSG_SIZE - offset;
        uint32_t chunk_size;
        bool is_last;

        if (seq == 0) {
            chunk_size = CHUNK_SEND_FIRST_PAYLOAD;
            if (chunk_size > remaining) chunk_size = remaining;
            is_last = (chunk_size == remaining);
            make_chunk_send_first(req_buf, &req_size2, 3,
                                  LARGE_MSG_SIZE, large_msg + offset, chunk_size);
            if (is_last) req_buf[2] |= SPDM_CHUNK_SEND_REQUEST_ATTRIBUTE_LAST_CHUNK;
        } else {
            chunk_size = CHUNK_SEND_SUBSEQ_PAYLOAD;
            if (chunk_size > remaining) chunk_size = remaining;
            is_last = (chunk_size == remaining);
            make_chunk_send_next(req_buf, &req_size2, 3, seq, is_last,
                                 large_msg + offset, chunk_size);
        }

        rsp_size = sizeof(rsp_buf);
        libspdm_get_response_chunk_send(&rsp_ctx, req_size2, req_buf, &rsp_size, rsp_buf);
        offset += chunk_size;
        seq++;
        done = (offset >= LARGE_MSG_SIZE);
    }

    spdm_trace_close();
    printf("  [chunk_send_invalid_seq] done\n");
}

/* ----------------------------------------------------------------
 * Responder setup helper for CHUNK_GET scenarios
 *
 * Sets up get_info and emits large_response_ready.
 * This simulates what libspdm_build_response does when a response
 * is too large for the transport MTU.
 * ---------------------------------------------------------------- */
static void setup_large_response_ready(
    libspdm_context_t *rsp_ctx,
    uint8_t handle,
    const uint8_t *large_data,
    size_t large_data_size)
{
    libspdm_chunk_info_t *get_info = &rsp_ctx->chunk_context.get;

    /* Clear and set up the large message scratch area */
    uint8_t *scratch;
    size_t scratch_size;
    libspdm_get_scratch_buffer(rsp_ctx, (void **)&scratch, &scratch_size);
    uint8_t *large_msg_buf = scratch; /* large_message_offset = 0 */
    memset(large_msg_buf, 0, large_data_size);
    memcpy(large_msg_buf, large_data, large_data_size);

    get_info->chunk_in_use = true;
    get_info->chunk_handle = handle;
    get_info->chunk_seq_no = 0;
    get_info->chunk_bytes_transferred = 0;
    get_info->large_message = large_msg_buf;
    get_info->large_message_size = large_data_size;
    get_info->large_message_capacity = 32768;

    /* Emit large_response_ready from the setup (represents what the real
     * libspdm_build_response path does when a response exceeds data_transfer_size) */
    SPDM_TRACE_LARGE_RESPONSE_READY(rsp_ctx, handle, (uint32_t)large_data_size);
}

/* Build the LARGE_RESPONSE error that the responder sends to the requester */
static void build_large_response_error(uint8_t *buf, size_t *size, uint8_t handle)
{
    spdm_error_response_t *err = (spdm_error_response_t *)buf;
    err->header.spdm_version = SPDM_MESSAGE_VERSION_12;
    err->header.request_response_code = SPDM_ERROR;
    err->header.param1 = SPDM_ERROR_CODE_LARGE_RESPONSE;
    err->header.param2 = 0;
    /* extend_error_data: just the 1-byte handle */
    buf[sizeof(spdm_error_response_t)] = handle;
    *size = sizeof(spdm_error_response_t) + sizeof(uint8_t);
}

/* ----------------------------------------------------------------
 * Scenario 3: Normal CHUNK_GET
 * ---------------------------------------------------------------- */
static void run_chunk_get_normal(const char *trace_path)
{
    spdm_trace_init(trace_path);

    libspdm_context_t req_ctx, rsp_ctx;
    spdm_test_setup_context(&req_ctx, &req_ctx, &rsp_ctx, DATA_TRANSFER_SIZE);
    spdm_test_setup_context(&rsp_ctx, &req_ctx, &rsp_ctx, DATA_TRANSFER_SIZE);

    /* Build large response data */
    uint8_t large_data[LARGE_MSG_SIZE];
    for (uint32_t i = 0; i < LARGE_MSG_SIZE; i++) large_data[i] = (uint8_t)(i & 0xFF);

    /* Setup responder (emits large_response_ready) */
    uint8_t chunk_handle = 1;
    setup_large_response_ready(&rsp_ctx, chunk_handle, large_data, LARGE_MSG_SIZE);

    /* Build LARGE_RESPONSE error message for requester */
    uint8_t error_buf[64];
    size_t error_size;
    build_large_response_error(error_buf, &error_size, chunk_handle);

    /* Prepare response assembly buffer */
    uint8_t response_buf[RESPONSE_BUF_SIZE];
    memcpy(response_buf, error_buf, error_size);
    size_t response_size = error_size;

    /* Run the requester's handle_error_large_response */
    libspdm_return_t status = libspdm_handle_error_large_response(
        &req_ctx,
        NULL, /* no session */
        &response_size,
        response_buf,
        RESPONSE_BUF_SIZE, /* response_capacity */
        false);

    printf("  [chunk_get_normal] status=0x%x response_size=%zu\n",
           (unsigned)status, response_size);

    spdm_trace_close();
}

/* ----------------------------------------------------------------
 * Scenario 4: CHUNK_GET with buffer overflow (Family 3)
 * ---------------------------------------------------------------- */
static void run_chunk_get_overflow(const char *trace_path)
{
    spdm_trace_init(trace_path);

    libspdm_context_t req_ctx, rsp_ctx;
    spdm_test_setup_context(&req_ctx, &req_ctx, &rsp_ctx, DATA_TRANSFER_SIZE);
    spdm_test_setup_context(&rsp_ctx, &req_ctx, &rsp_ctx, DATA_TRANSFER_SIZE);

    /* Large response that is bigger than caller's response_capacity */
    uint8_t large_data[LARGE_MSG_SIZE];
    for (uint32_t i = 0; i < LARGE_MSG_SIZE; i++) large_data[i] = (uint8_t)((i + 7) & 0xFF);

    uint8_t chunk_handle = 2;
    setup_large_response_ready(&rsp_ctx, chunk_handle, large_data, LARGE_MSG_SIZE);

    uint8_t error_buf[64];
    size_t error_size;
    build_large_response_error(error_buf, &error_size, chunk_handle);

    uint8_t response_buf[RESPONSE_BUF_SIZE];
    memcpy(response_buf, error_buf, error_size);
    size_t response_size = error_size;

    /* response_capacity set to OVERFLOW_CAPACITY (50) < LARGE_MSG_SIZE (300) */
    libspdm_return_t status = libspdm_handle_error_large_response(
        &req_ctx,
        NULL,
        &response_size,
        response_buf,
        OVERFLOW_CAPACITY, /* too small */
        false);

    printf("  [chunk_get_overflow] status=0x%x (expected SUCCESS for Family 3 bug)\n",
           (unsigned)status);

    spdm_trace_close();
}

/* ----------------------------------------------------------------
 * Scenario 5: CHUNK_GET while CHUNK_SEND is in progress (Family 5)
 *
 * Sets send.chunk_in_use=true so every CHUNK_GET_SERVED becomes
 * CHUNK_GET_DURING_SEND (the Family 5 anomaly path).
 * ---------------------------------------------------------------- */
static void run_chunk_get_during_send(const char *trace_path)
{
    spdm_trace_init(trace_path);

    libspdm_context_t req_ctx, rsp_ctx;
    spdm_test_setup_context(&req_ctx, &req_ctx, &rsp_ctx, DATA_TRANSFER_SIZE);
    spdm_test_setup_context(&rsp_ctx, &req_ctx, &rsp_ctx, DATA_TRANSFER_SIZE);

    uint8_t large_data[LARGE_MSG_SIZE];
    for (uint32_t i = 0; i < LARGE_MSG_SIZE; i++) large_data[i] = (uint8_t)(i & 0xFF);

    uint8_t chunk_handle = 3;
    setup_large_response_ready(&rsp_ctx, chunk_handle, large_data, LARGE_MSG_SIZE);

    /* Simulate mid-CHUNK_SEND: set send.chunk_in_use = true */
    rsp_ctx.chunk_context.send.chunk_in_use = true;
    rsp_ctx.chunk_context.send.chunk_handle = 7;

    uint8_t error_buf[64];
    size_t error_size;
    build_large_response_error(error_buf, &error_size, chunk_handle);

    uint8_t response_buf[RESPONSE_BUF_SIZE];
    memcpy(response_buf, error_buf, error_size);
    size_t response_size = error_size;

    libspdm_return_t status = libspdm_handle_error_large_response(
        &req_ctx, NULL, &response_size, response_buf, RESPONSE_BUF_SIZE, false);

    printf("  [chunk_get_during_send] status=0x%x response_size=%zu\n",
           (unsigned)status, response_size);
    spdm_trace_close();
}

/* ----------------------------------------------------------------
 * Scenario 6: CHUNK_RESPONSE source OOB (Family 4)
 *
 * Injects a crafted first CHUNK_RESPONSE where chunk_size (45) exceeds
 * the response payload bound (52-12=40), triggering chunk_response_source_oob.
 * LAST_CHUNK is set so the loop exits cleanly after 1 chunk.
 * ---------------------------------------------------------------- */
static void run_chunk_response_source_oob(const char *trace_path)
{
    spdm_trace_init(trace_path);

    libspdm_context_t req_ctx, rsp_ctx;
    spdm_test_setup_context(&req_ctx, &req_ctx, &rsp_ctx, DATA_TRANSFER_SIZE);
    spdm_test_setup_context(&rsp_ctx, &req_ctx, &rsp_ctx, DATA_TRANSFER_SIZE);

    uint8_t large_data[LARGE_MSG_SIZE];
    for (uint32_t i = 0; i < LARGE_MSG_SIZE; i++) large_data[i] = (uint8_t)(i & 0xFF);

    uint8_t chunk_handle = 4;
    setup_large_response_ready(&rsp_ctx, chunk_handle, large_data, LARGE_MSG_SIZE);

    g_inject_oob_first = true;

    uint8_t error_buf[64];
    size_t error_size;
    build_large_response_error(error_buf, &error_size, chunk_handle);

    uint8_t response_buf[RESPONSE_BUF_SIZE];
    memcpy(response_buf, error_buf, error_size);
    size_t response_size = error_size;

    libspdm_return_t status = libspdm_handle_error_large_response(
        &req_ctx, NULL, &response_size, response_buf, RESPONSE_BUF_SIZE, false);

    printf("  [chunk_response_source_oob] status=0x%x response_size=%zu\n",
           (unsigned)status, response_size);
    spdm_trace_close();
}

/* ----------------------------------------------------------------
 * main
 * ---------------------------------------------------------------- */
int main(int argc, char *argv[])
{
    const char *trace_dir = (argc > 1) ? argv[1] : "../../traces";

    char path[512];
    printf("Collecting libspdm chunking traces to: %s\n", trace_dir);

    snprintf(path, sizeof(path), "%s/chunk_send_normal.ndjson", trace_dir);
    printf("Scenario 1: Normal CHUNK_SEND...\n");
    run_chunk_send_normal(path);

    snprintf(path, sizeof(path), "%s/chunk_send_invalid_seq.ndjson", trace_dir);
    printf("Scenario 2: CHUNK_SEND invalid seq-no...\n");
    run_chunk_send_invalid_seq(path);

    snprintf(path, sizeof(path), "%s/chunk_get_normal.ndjson", trace_dir);
    printf("Scenario 3: Normal CHUNK_GET...\n");
    run_chunk_get_normal(path);

    snprintf(path, sizeof(path), "%s/chunk_get_overflow.ndjson", trace_dir);
    printf("Scenario 4: CHUNK_GET buffer overflow...\n");
    run_chunk_get_overflow(path);

    snprintf(path, sizeof(path), "%s/chunk_get_during_send.ndjson", trace_dir);
    printf("Scenario 5: CHUNK_GET during active CHUNK_SEND (Family 5)...\n");
    run_chunk_get_during_send(path);

    snprintf(path, sizeof(path), "%s/chunk_response_source_oob.ndjson", trace_dir);
    printf("Scenario 6: CHUNK_RESPONSE source OOB (Family 4)...\n");
    run_chunk_response_source_oob(path);

    printf("Done.\n");
    return 0;
}
