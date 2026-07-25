/**
 * Reproduction test — Bug 5: MutualExclusionAsymmetry
 *
 * Root cause: libspdm_rsp_chunk_response.c (libspdm_get_response_chunk_get)
 * checks get_info->chunk_in_use == false at line 101 (rejects if no active
 * GET), but does NOT check send_info->chunk_in_use.
 * The CHUNK_SEND handler (libspdm_rsp_chunk_send_ack.c line 91) DOES guard:
 *   if (spdm_context->chunk_context.get.chunk_in_use) { return UNEXPECTED_REQUEST; }
 *
 * Both send and get large_message pointers resolve to the same scratch offset.
 * So CHUNK_GET while SEND is in-flight corrupts the in-progress SEND data.
 *
 * Expected: UNEXPECTED_REQUEST returned when send_in_use == true.
 * Actual:   CHUNK_RESPONSE returned — the GET proceeds and the scratch
 *           buffer (which the SEND is still accumulating into) is corrupted.
 *
 * Escalation Level 0 — state injection:
 *   1. Inject send_in_use=true, get_in_use=true (both point to same scratch).
 *   2. Send a valid CHUNK_GET request (correct handle, seq_no=0).
 *   3. If CHUNK_RESPONSE returned instead of UNEXPECTED_REQUEST → bug confirmed.
 */

#include <stdarg.h>
#include <stddef.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "hal/base.h"
#include "hal/library/memlib.h"
#include "library/spdm_responder_lib.h"
#include "library/spdm_transport_test_lib.h"
#include "internal/libspdm_common_lib.h"
#include "internal/libspdm_responder_lib.h"

#define BUF_SIZE (0x1200 + 32)
#define BUG5_DATA_TRANSFER_SIZE 42

static uint8_t m_sender_buf[BUF_SIZE];
static uint8_t m_receiver_buf[BUF_SIZE];
static uint8_t m_large_response[200];

static libspdm_return_t stub_send(void *ctx, size_t sz, const void *buf, uint64_t t)
{ (void)ctx; (void)sz; (void)buf; (void)t; return LIBSPDM_STATUS_SUCCESS; }
static libspdm_return_t stub_recv(void *ctx, size_t *sz, void **buf, uint64_t t)
{ (void)ctx; (void)sz; (void)buf; (void)t; return LIBSPDM_STATUS_SUCCESS; }

static libspdm_return_t acquire_sender(void *ctx, void **buf)
{ (void)ctx; *buf = m_sender_buf; return LIBSPDM_STATUS_SUCCESS; }
static void release_sender(void *ctx, const void *buf) { (void)ctx; (void)buf; }
static libspdm_return_t acquire_receiver(void *ctx, void **buf)
{ (void)ctx; *buf = m_receiver_buf; return LIBSPDM_STATUS_SUCCESS; }
static void release_receiver(void *ctx, const void *buf) { (void)ctx; (void)buf; }

static libspdm_context_t *alloc_context(void)
{
    libspdm_context_t *ctx = malloc(libspdm_get_context_size());
    if (!ctx) { fputs("OOM\n", stderr); exit(1); }
    libspdm_init_context(ctx);
    libspdm_register_device_io_func(ctx, stub_send, stub_recv);
    libspdm_register_transport_layer_func(
        ctx, LIBSPDM_MAX_SPDM_MSG_SIZE,
        LIBSPDM_TEST_TRANSPORT_HEADER_SIZE, LIBSPDM_TEST_TRANSPORT_TAIL_SIZE,
        libspdm_transport_test_encode_message,
        libspdm_transport_test_decode_message);
    libspdm_register_device_buffer_func(
        ctx, BUF_SIZE, BUF_SIZE,
        acquire_sender, release_sender,
        acquire_receiver, release_receiver);
    size_t scratch_size = libspdm_get_sizeof_required_scratch_buffer(ctx);
    void *scratch = malloc(scratch_size);
    if (!scratch) { fputs("OOM scratch\n", stderr); exit(1); }
    libspdm_set_scratch_buffer(ctx, scratch, scratch_size);

    ctx->response_state = LIBSPDM_RESPONSE_STATE_NORMAL;
    ctx->connection_info.connection_state = LIBSPDM_CONNECTION_STATE_AFTER_CAPABILITIES;
    ctx->connection_info.version = SPDM_MESSAGE_VERSION_12 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    ctx->local_context.capability.flags = 0;
    ctx->connection_info.capability.flags = 0;
    ctx->local_context.capability.flags  |= SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CHUNK_CAP;
    ctx->connection_info.capability.flags |= SPDM_GET_CAPABILITIES_REQUEST_FLAGS_CHUNK_CAP;
    ctx->local_context.capability.data_transfer_size = BUG5_DATA_TRANSFER_SIZE;
    ctx->local_context.capability.sender_data_transfer_size = BUG5_DATA_TRANSFER_SIZE;
    ctx->local_context.capability.max_spdm_msg_size = LIBSPDM_MAX_SPDM_MSG_SIZE;
    ctx->connection_info.capability.data_transfer_size = BUG5_DATA_TRANSFER_SIZE;
    return ctx;
}

int main(void)
{
    libspdm_return_t status;
    libspdm_context_t *ctx = alloc_context();
    libspdm_chunk_info_t *send_info = &ctx->chunk_context.send;
    libspdm_chunk_info_t *get_info  = &ctx->chunk_context.get;
    void *scratch_buffer;
    size_t scratch_buffer_size;
    uint8_t *large_buf;
    size_t i;

    for (i = 0; i < sizeof(m_large_response); i++)
        m_large_response[i] = (uint8_t)(i & 0xFF);

    /* Set up GET context: large response ready for chunking */
    libspdm_get_scratch_buffer(ctx, &scratch_buffer, &scratch_buffer_size);
    large_buf = (uint8_t *)scratch_buffer
                + libspdm_get_scratch_buffer_large_message_offset(ctx);
    libspdm_copy_mem(large_buf,
                     libspdm_get_scratch_buffer_large_message_capacity(ctx),
                     m_large_response, sizeof(m_large_response));

    get_info->chunk_in_use            = true;
    get_info->chunk_handle            = 0xAB;
    get_info->chunk_seq_no            = 0;
    get_info->chunk_bytes_transferred = 0;
    get_info->large_message           = large_buf;
    get_info->large_message_size      = sizeof(m_large_response);
    get_info->large_message_capacity  = libspdm_get_scratch_buffer_large_message_capacity(ctx);

    /* Simulate a CHUNK_SEND in-progress (send_in_use = true, same scratch region) */
    send_info->chunk_in_use            = true;
    send_info->chunk_handle            = 0x01;
    send_info->chunk_seq_no            = 0;
    send_info->chunk_bytes_transferred = 20;
    send_info->large_message           = large_buf; /* SAME region as get */
    send_info->large_message_size      = 100;
    send_info->large_message_capacity  = libspdm_get_scratch_buffer_large_message_capacity(ctx);

    printf("State: send_in_use=%d, get_in_use=%d, shared large_buf=%p\n",
           send_info->chunk_in_use, get_info->chunk_in_use, (void *)large_buf);

    /* Send a valid CHUNK_GET request (correct handle and seq_no) */
    spdm_chunk_get_request_t request;
    uint8_t response[LIBSPDM_MAX_SPDM_MSG_SIZE];
    size_t response_size = sizeof(response);

    libspdm_zero_mem(&request, sizeof(request));
    request.header.spdm_version = SPDM_MESSAGE_VERSION_12;
    request.header.request_response_code = SPDM_CHUNK_GET;
    request.header.param1 = 0;
    request.header.param2 = 0xAB; /* correct handle */
    request.chunk_seq_no  = 0;

    status = libspdm_get_response_chunk_get(
        ctx, sizeof(request), &request, &response_size, response);

    spdm_message_header_t *hdr = (spdm_message_header_t *)response;
    int got_unexpected_request =
        (response_size >= sizeof(spdm_error_response_t)) &&
        (hdr->request_response_code == SPDM_ERROR) &&
        (hdr->param1 == SPDM_ERROR_CODE_UNEXPECTED_REQUEST);
    int got_chunk_response =
        (hdr->request_response_code == SPDM_CHUNK_RESPONSE);

    printf("Response code: 0x%02x", hdr->request_response_code);
    if (got_chunk_response)        printf(" (CHUNK_RESPONSE)");
    else if (got_unexpected_request) printf(" (ERROR:UNEXPECTED_REQUEST - expected)");
    else if (hdr->request_response_code == SPDM_ERROR)
        printf(" (ERROR param1=0x%02x)", hdr->param1);
    printf("\n");

    printf("\n=== Bug 5 (MutualExclusionAsymmetry) ===\n");
    printf("send_in_use at entry: TRUE\n");
    printf("get_in_use at entry:  TRUE\n");
    printf("Expected:  ERROR:UNEXPECTED_REQUEST\n");
    printf("Actual:    %s\n",
           got_chunk_response ? "CHUNK_RESPONSE (bug: GET accepted while SEND active)" :
           got_unexpected_request ? "UNEXPECTED_REQUEST (no bug)" :
           "other response");

    if (got_chunk_response) {
        printf("\nRESULT: BUG CONFIRMED\n");
        printf("  CHUNK_GET was accepted while send_in_use=TRUE.\n");
        printf("  Both contexts share the same scratch buffer -> data corruption.\n");
        printf("  Missing guard in libspdm_get_response_chunk_get:\n");
        printf("    if (send_info->chunk_in_use) { return UNEXPECTED_REQUEST; }\n");
        return 0;
    } else if (got_unexpected_request) {
        printf("\nRESULT: Bug absent - CHUNK_GET correctly rejected when send active\n");
        return 1;
    } else {
        printf("\nRESULT: Unexpected response (status=0x%08x)\n", status);
        return 2;
    }
}
