/**
 * Reproduction test — Bug 2: ControlFlowOrderingSeqNoMismatch
 *
 * Root cause: libspdm_rsp_chunk_send_ack.c lines 176–214.
 * The seq_no mismatch check at line 176 sets status=INVALID but does NOT
 * return/break. The subsequent handle/size if-else chain at 181–214 is
 * independent; when handle and sizes are valid, the else-block executes,
 * copying chunk data and advancing chunk_seq_no / chunk_bytes_transferred.
 *
 * Expected: error response returned, send_info state UNCHANGED.
 * Actual:   error response returned AND send_info state CORRUPTED.
 *
 * Escalation Level 0 — black-box via public API:
 *   1. First valid chunk (seq_no=0) establishes send context.
 *   2. Continuation with seq_no=2 (expected 1), valid handle/sizes.
 *   3. bytes_transferred must not advance after step 2.
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

/* Buffer large enough for test transport overhead + max msg size */
#define BUF_SIZE (0x1200 + 32)

static uint8_t m_sender_buf[BUF_SIZE];
static uint8_t m_receiver_buf[BUF_SIZE];

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

#define DATA_TRANSFER_SIZE 42
#define PAYLOAD_SIZE 84

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
    ctx->local_context.capability.data_transfer_size = DATA_TRANSFER_SIZE;
    ctx->local_context.capability.max_spdm_msg_size  = LIBSPDM_MAX_SPDM_MSG_SIZE;
    return ctx;
}

int main(void)
{
    libspdm_return_t status;
    libspdm_context_t *ctx = alloc_context();
    libspdm_chunk_info_t *send_info = &ctx->chunk_context.send;
    int i;

    uint8_t payload[PAYLOAD_SIZE];
    for (i = 0; i < PAYLOAD_SIZE; i++) payload[i] = (uint8_t)i;

    /* chunk_size for first chunk = data_transfer_size - header - 4-byte large_size field */
    uint32_t FIRST_DATA = DATA_TRANSFER_SIZE - (uint32_t)sizeof(spdm_chunk_send_request_t) - 4;
    /* continuation chunk_size = data_transfer_size - header */
    uint32_t CONT_DATA  = DATA_TRANSFER_SIZE - (uint32_t)sizeof(spdm_chunk_send_request_t);

    uint8_t req_buf[512], rsp_buf[512];
    size_t req_sz, rsp_sz;
    spdm_chunk_send_request_t *req;

    /* ---- Step 1: first chunk (seq_no = 0) ---- */
    libspdm_zero_mem(req_buf, sizeof(req_buf));
    req = (spdm_chunk_send_request_t *)req_buf;
    req->header.spdm_version = SPDM_MESSAGE_VERSION_12;
    req->header.request_response_code = SPDM_CHUNK_SEND;
    req->header.param1 = 0;      /* not LAST_CHUNK */
    req->header.param2 = 0x07;  /* handle */
    req->chunk_seq_no  = 0;
    *((uint32_t *)(req + 1)) = (uint32_t)sizeof(payload);
    req->chunk_size = FIRST_DATA;
    libspdm_copy_mem((uint8_t *)(req + 1) + 4, FIRST_DATA, payload, FIRST_DATA);
    req_sz = sizeof(spdm_chunk_send_request_t) + 4 + FIRST_DATA;
    rsp_sz = sizeof(rsp_buf);

    status = libspdm_get_response_chunk_send(ctx, req_sz, req_buf, &rsp_sz, rsp_buf);
    if (!LIBSPDM_STATUS_IS_SUCCESS(status) || !send_info->chunk_in_use) {
        fprintf(stderr, "FAIL: First chunk not accepted (status=0x%08x, in_use=%d)\n",
                status, send_info->chunk_in_use);
        return 2;
    }
    if (send_info->chunk_bytes_transferred != FIRST_DATA) {
        fprintf(stderr, "FAIL: unexpected bytes_transferred after first chunk: %zu vs %u\n",
                send_info->chunk_bytes_transferred, FIRST_DATA);
        return 2;
    }

    size_t bytes_before = send_info->chunk_bytes_transferred;
    uint32_t seq_before = send_info->chunk_seq_no;
    printf("After first chunk: bytes_transferred=%zu, seq_no=%u\n", bytes_before, seq_before);

    /* ---- Step 2: continuation with seq_no = 2 (expected: 1) ---- */
    libspdm_zero_mem(req_buf, sizeof(req_buf));
    req = (spdm_chunk_send_request_t *)req_buf;
    req->header.spdm_version = SPDM_MESSAGE_VERSION_12;
    req->header.request_response_code = SPDM_CHUNK_SEND;
    req->header.param1 = 0;
    req->header.param2 = 0x07; /* same handle */
    req->chunk_seq_no  = 2;    /* WRONG: expected 1 */
    req->chunk_size = CONT_DATA;
    libspdm_copy_mem((uint8_t *)(req + 1), CONT_DATA, payload + FIRST_DATA, CONT_DATA);
    req_sz = sizeof(spdm_chunk_send_request_t) + CONT_DATA;
    rsp_sz = sizeof(rsp_buf);

    status = libspdm_get_response_chunk_send(ctx, req_sz, req_buf, &rsp_sz, rsp_buf);
    printf("After bad seq_no=2: bytes_transferred=%zu, seq_no=%u\n",
           send_info->chunk_bytes_transferred, send_info->chunk_seq_no);

    int state_corrupted =
        (send_info->chunk_bytes_transferred != bytes_before) ||
        (send_info->chunk_seq_no != seq_before);

    printf("\n=== Bug 2 (ControlFlowOrderingSeqNoMismatch) ===\n");
    printf("Expected bytes_transferred: %zu (unchanged)\n", bytes_before);
    printf("Actual bytes_transferred:   %zu\n", send_info->chunk_bytes_transferred);
    printf("Expected seq_no:            %u (unchanged)\n", seq_before);
    printf("Actual seq_no:              %u\n", send_info->chunk_seq_no);

    if (state_corrupted) {
        printf("\nRESULT: BUG CONFIRMED\n");
        printf("  State was advanced despite invalid seq_no.\n");
        printf("  bytes delta: %zu (should be 0)\n",
               send_info->chunk_bytes_transferred - bytes_before);
        printf("  seq_no delta: %d (should be 0)\n",
               (int)send_info->chunk_seq_no - (int)seq_before);
        return 0;
    } else {
        printf("\nRESULT: Bug absent - state unchanged after seq_no mismatch\n");
        return 1;
    }
}
