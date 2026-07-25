/**
 * spdm_stubs.c — Stub implementations for all libspdm functions used by
 * the chunking source files (chunk_send_ack, chunk_response,
 * req_handle_error_response) but NOT implemented in those files themselves.
 *
 * The mock network (libspdm_send_spdm_request / libspdm_receive_spdm_response)
 * routes CHUNK_GET requests through the real libspdm_get_response_chunk_get.
 */

#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <stdarg.h>

#include "internal/libspdm_common_lib.h"

/* ----------------------------------------------------------------
 * Global trace file (defined here, declared extern in spdm_trace.h)
 * ---------------------------------------------------------------- */
FILE *g_spdm_trace_file = NULL;

/* ----------------------------------------------------------------
 * Static scratch buffers — shared between all contexts via stub
 * The first context passed to libspdm_get_scratch_buffer gets
 * REQUESTER_SCRATCH; a second distinct pointer gets RESPONDER_SCRATCH.
 * We identify them by pointer value.
 * ---------------------------------------------------------------- */
#define SCRATCH_SIZE 65536
static uint8_t g_requester_scratch[SCRATCH_SIZE];
static uint8_t g_responder_scratch[SCRATCH_SIZE];

/* Contexts are passed in from the test harness */
libspdm_context_t *g_requester_ctx = NULL;
libspdm_context_t *g_responder_ctx = NULL;

static uint8_t *scratch_for(libspdm_context_t *ctx)
{
    if (ctx == g_responder_ctx) return g_responder_scratch;
    return g_requester_scratch; /* default / requester */
}

/* ----------------------------------------------------------------
 * Core libspdm stubs
 * ---------------------------------------------------------------- */

void libspdm_get_scratch_buffer(void *spdm_context,
                                void **scratch_buffer,
                                size_t *scratch_buffer_size)
{
    *scratch_buffer = scratch_for((libspdm_context_t *)spdm_context);
    *scratch_buffer_size = SCRATCH_SIZE;
}

uint32_t libspdm_get_scratch_buffer_large_message_offset(libspdm_context_t *spdm_context)
{
    (void)spdm_context;
    return 0;
}

uint32_t libspdm_get_scratch_buffer_large_message_capacity(libspdm_context_t *spdm_context)
{
    (void)spdm_context;
    return 32768; /* 32 KB — plenty for tests */
}

uint32_t libspdm_get_scratch_buffer_sender_receiver_offset(libspdm_context_t *spdm_context)
{
    (void)spdm_context;
    return 32768; /* after large message area */
}

uint32_t libspdm_get_scratch_buffer_sender_receiver_capacity(libspdm_context_t *spdm_context)
{
    (void)spdm_context;
    return 32768;
}

/* Connection version — return what the context says */
uint8_t libspdm_get_connection_version(const libspdm_context_t *spdm_context)
{
    return (uint8_t)(spdm_context->connection_info.version >> SPDM_VERSION_NUMBER_SHIFT_BIT);
}

bool libspdm_is_capabilities_flag_supported(
    const libspdm_context_t *spdm_context,
    bool is_requester,
    uint32_t requester_cap_flag,
    uint32_t responder_cap_flag)
{
    /* For our tests both sides support CHUNK_CAP and everything needed */
    (void)spdm_context;
    (void)is_requester;
    (void)requester_cap_flag;
    (void)responder_cap_flag;
    return true;
}

libspdm_return_t libspdm_generate_error_response(
    libspdm_context_t *spdm_context,
    uint8_t error_code,
    uint8_t error_data,
    size_t *response_size,
    void *response)
{
    (void)spdm_context;
    spdm_error_response_t *err = response;
    err->header.spdm_version = SPDM_MESSAGE_VERSION_12;
    err->header.request_response_code = SPDM_ERROR;
    err->header.param1 = error_code;
    err->header.param2 = error_data;
    *response_size = sizeof(spdm_error_response_t);
    return LIBSPDM_STATUS_SUCCESS;
}

libspdm_return_t libspdm_generate_extended_error_response(
    libspdm_context_t *spdm_context,
    uint8_t error_code,
    uint8_t error_data,
    size_t extended_data_size,
    const uint8_t *extended_data,
    size_t *response_size,
    void *response)
{
    (void)spdm_context;
    uint8_t *buf = response;
    spdm_error_response_t *err = response;
    err->header.spdm_version = SPDM_MESSAGE_VERSION_12;
    err->header.request_response_code = SPDM_ERROR;
    err->header.param1 = error_code;
    err->header.param2 = error_data;
    if (extended_data && extended_data_size > 0) {
        memcpy(buf + sizeof(spdm_error_response_t), extended_data, extended_data_size);
    }
    *response_size = sizeof(spdm_error_response_t) + extended_data_size;
    return LIBSPDM_STATUS_SUCCESS;
}

libspdm_return_t libspdm_responder_handle_response_state(
    libspdm_context_t *spdm_context,
    uint8_t request_code,
    size_t *response_size,
    void *response)
{
    (void)spdm_context; (void)request_code;
    return libspdm_generate_error_response(spdm_context, SPDM_ERROR_CODE_UNEXPECTED_REQUEST,
                                           0, response_size, response);
}

/* Used by chunk_send_ack when all chunks arrive: dispatch to handler */
typedef libspdm_return_t (*libspdm_get_spdm_response_func)(
    void *spdm_context, size_t request_size, const void *request,
    size_t *response_size, void *response);

static libspdm_return_t test_large_request_handler(
    void *spdm_context, size_t request_size, const void *request,
    size_t *response_size, void *response)
{
    /* Just return a minimal success response */
    (void)spdm_context; (void)request_size; (void)request;
    spdm_message_header_t *resp = response;
    resp->spdm_version = SPDM_MESSAGE_VERSION_12;
    resp->request_response_code = 0xFE; /* arbitrary non-chunk code */
    resp->param1 = 0;
    resp->param2 = 0;
    *response_size = sizeof(spdm_message_header_t);
    return LIBSPDM_STATUS_SUCCESS;
}

libspdm_get_spdm_response_func libspdm_get_response_func_via_request_code(uint8_t request_code)
{
    (void)request_code;
    return test_large_request_handler;
}

/* Memory ops — real implementations (void return matching header declarations) */
void libspdm_copy_mem(void *dst, size_t dst_size, const void *src, size_t src_size)
{
    if (src_size > dst_size) src_size = dst_size;
    memcpy(dst, src, src_size);
}

void libspdm_zero_mem(void *buf, size_t size)
{
    memset(buf, 0, size);
}

uint32_t libspdm_read_uint32(const uint8_t *buf)
{
    uint32_t val;
    memcpy(&val, buf, sizeof(uint32_t));
    return val;
}

/* Debug stubs */
void libspdm_debug_assert(const char *file, size_t line, const char *expr)
{
    fprintf(stderr, "ASSERT: %s:%zu: %s\n", file, (size_t)line, expr);
    abort();
}

void libspdm_debug_print(size_t error_level, const char *format, ...)
{
    (void)error_level;
    va_list args;
    va_start(args, format);
    vfprintf(stderr, format, args);
    va_end(args);
}

void libspdm_internal_dump_hex(const uint8_t *data, size_t size)
{
    (void)data; (void)size;
}

void libspdm_internal_dump_hex_str(const uint8_t *data, size_t size)
{
    (void)data; (void)size;
}

void libspdm_sleep(uint64_t microseconds)
{
    (void)microseconds;
}

void libspdm_free_session_id(libspdm_context_t *spdm_context, uint32_t session_id)
{
    (void)spdm_context; (void)session_id;
}

/* Buffer management — use scratch area */
libspdm_return_t libspdm_acquire_sender_buffer(
    libspdm_context_t *spdm_context, size_t *message_size, void **message)
{
    uint8_t *scratch = scratch_for(spdm_context);
    *message = scratch + 32768; /* sender/receiver area */
    *message_size = 32768;
    return LIBSPDM_STATUS_SUCCESS;
}

void libspdm_release_sender_buffer(libspdm_context_t *spdm_context)
{
    (void)spdm_context;
}

libspdm_return_t libspdm_acquire_receiver_buffer(
    libspdm_context_t *spdm_context, size_t *message_size, void **message)
{
    uint8_t *scratch = scratch_for(spdm_context);
    *message = scratch + 32768;
    *message_size = 32768;
    return LIBSPDM_STATUS_SUCCESS;
}

void libspdm_release_receiver_buffer(libspdm_context_t *spdm_context)
{
    (void)spdm_context;
}

/* ----------------------------------------------------------------
 * Mock network: routes CHUNK_GET from requester to responder
 * ---------------------------------------------------------------- */

/* Forward declaration of the real responder handler */
extern libspdm_return_t libspdm_get_response_chunk_get(
    libspdm_context_t *spdm_context,
    size_t request_size,
    const void *request,
    size_t *response_size,
    void *response);

static uint8_t g_mock_request_buf[512];
static size_t  g_mock_request_size = 0;

/* When true, receive_spdm_response injects one crafted OOB CHUNK_RESPONSE */
bool g_inject_oob_first = false;

libspdm_return_t libspdm_send_spdm_request(
    libspdm_context_t *spdm_context,
    const uint32_t *session_id,
    size_t request_size,
    const void *request)
{
    (void)spdm_context; (void)session_id;
    /* Save the SPDM request (CHUNK_GET) before the caller zeros the buffer */
    if (request_size > sizeof(g_mock_request_buf)) request_size = sizeof(g_mock_request_buf);
    memcpy(g_mock_request_buf, request, request_size);
    g_mock_request_size = request_size;
    return LIBSPDM_STATUS_SUCCESS;
}

libspdm_return_t libspdm_receive_spdm_response(
    libspdm_context_t *spdm_context,
    const uint32_t *session_id,
    size_t *response_size,
    void **response)
{
    (void)session_id;

    if (g_inject_oob_first) {
        g_inject_oob_first = false;
        /* Craft a CHUNK_RESPONSE where chunk_size (45) > payload_bound (52-12=40).
         * LAST_CHUNK is set and large_message_size==chunk_size so the loop exits cleanly
         * and TRANSFER_COMPLETE_SUCCESS fires after the OOB trace. */
        uint8_t *buf = (uint8_t *)(*response);
        memset(buf, 0xEE, 60);  /* pre-fill so the 45-byte copy reads valid bytes */
        spdm_chunk_response_response_t *rsp = (spdm_chunk_response_response_t *)buf;
        rsp->header.spdm_version  = SPDM_MESSAGE_VERSION_12;
        rsp->header.request_response_code = SPDM_CHUNK_RESPONSE;
        rsp->header.param1 = SPDM_CHUNK_GET_RESPONSE_ATTRIBUTE_LAST_CHUNK;
        rsp->header.param2 = 4;   /* handle matches run_chunk_response_source_oob */
        rsp->chunk_seq_no  = 0;
        rsp->reserved      = 0;
        rsp->chunk_size    = 45;  /* > payload_bound=40 → OOB */
        /* large_message_size on first chunk; set equal to chunk_size so loop exits OK */
        uint32_t *lms = (uint32_t *)(rsp + 1);
        *lms = 45;
        *response_size = 52;      /* 12 header + 4 lms + 36 dummy data */
        return LIBSPDM_STATUS_SUCCESS;
    }

    /* Process the saved CHUNK_GET through the real responder */
    if (!g_responder_ctx) return LIBSPDM_STATUS_INVALID_STATE_LOCAL;

    /* Sync responder version with requester */
    g_responder_ctx->connection_info.version = spdm_context->connection_info.version;

    size_t rsp_sz = *response_size;
    libspdm_return_t status = libspdm_get_response_chunk_get(
        g_responder_ctx,
        g_mock_request_size, g_mock_request_buf,
        &rsp_sz, *response);

    if (LIBSPDM_STATUS_IS_SUCCESS(status)) {
        *response_size = rsp_sz;
    }
    return status;
}

/* ----------------------------------------------------------------
 * Context setup helpers (called by the test harness)
 * ---------------------------------------------------------------- */

void spdm_test_setup_context(
    libspdm_context_t *ctx,
    libspdm_context_t *requester,
    libspdm_context_t *responder,
    uint32_t data_transfer_size)
{
    memset(ctx, 0, sizeof(*ctx));
    ctx->connection_info.version = SPDM_MESSAGE_VERSION_12 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    ctx->connection_info.connection_state = LIBSPDM_CONNECTION_STATE_NEGOTIATED;
    ctx->connection_info.capability.data_transfer_size = data_transfer_size;
    ctx->local_context.capability.data_transfer_size = data_transfer_size;
    ctx->local_context.capability.sender_data_transfer_size = data_transfer_size;
    ctx->local_context.capability.max_spdm_msg_size = 65536;
    ctx->local_context.capability.transport_header_size = 0; /* no transport */
    ctx->response_state = LIBSPDM_RESPONSE_STATE_NORMAL;

    if (requester) g_requester_ctx = requester;
    if (responder) g_responder_ctx = responder;
}
