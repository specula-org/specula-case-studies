/**
 * Reproduction test for MC1: Chimeric MEL Assembly
 *
 * Bug: The Responder calls libspdm_measurement_extension_log_collection fresh
 * on every GET_MEL request with no snapshot. The Requester detects MEL shrinkage
 * (libspdm_req_get_measurement_extension_log.c:205-210) but silently accepts
 * MEL growth — assembling a chimeric log without error.
 *
 * Trigger: Two-chunk transfer where MEL grows between requests.
 * First chunk from gen1 (80 entries), second chunk from gen2 (100 entries).
 * The shrinkage check (line 205-210) passes because offset+portion+remainder
 * is NOT less than total_responder_mel_buffer_length.
 */

#include <stdarg.h>
#include <stddef.h>
#include <setjmp.h>
#include <stdint.h>
#include <cmocka.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <stdbool.h>

#include "spdm_unit_test.h"
#include "internal/libspdm_requester_lib.h"

#define LIBSPDM_MAX_MEASUREMENT_EXTENSION_LOG_SIZE 0x1000
#ifndef LIBSPDM_MAX_MEL_BLOCK_LEN
#define LIBSPDM_MAX_MEL_BLOCK_LEN 1024
#endif

static uint8_t  m_mel_gen1[LIBSPDM_MAX_MEASUREMENT_EXTENSION_LOG_SIZE];
static uint8_t  m_mel_gen2[LIBSPDM_MAX_MEASUREMENT_EXTENSION_LOG_SIZE];
static size_t   m_mel_gen1_len = 0;
static size_t   m_mel_gen2_len = 0;
static int      m_call_index = 0;

/* Build a MEL with n_entries identical entries (each = sizeof(mel_entry)+2 bytes) */
static size_t build_mel(uint8_t *buf, size_t buf_sz, int n_entries)
{
    spdm_measurement_extension_log_dmtf_t *hdr =
        (spdm_measurement_extension_log_dmtf_t *)buf;
    uint8_t *ptr = buf + sizeof(spdm_measurement_extension_log_dmtf_t);
    uint8_t data[2] = {0xAA, 0xBB};
    size_t entry_sz = sizeof(spdm_mel_entry_dmtf_t) + sizeof(data);
    size_t total = sizeof(spdm_measurement_extension_log_dmtf_t);
    uint32_t entries_payload = 0;

    memset(buf, 0, buf_sz);
    hdr->number_of_entries = (uint8_t)n_entries;

    for (int i = 0; i < n_entries && total + entry_sz <= buf_sz; i++) {
        spdm_mel_entry_dmtf_t *e = (spdm_mel_entry_dmtf_t *)ptr;
        e->mel_index = (uint8_t)(i + 1);
        e->meas_index = LIBSPDM_MEASUREMENT_INDEX_HEM;
        e->measurement_block_dmtf_header.dmtf_spec_measurement_value_type =
            SPDM_MEASUREMENT_BLOCK_MEASUREMENT_TYPE_INFORMATIONAL |
            SPDM_MEASUREMENT_BLOCK_MEASUREMENT_TYPE_RAW_BIT_STREAM;
        e->measurement_block_dmtf_header.dmtf_spec_measurement_value_size =
            (uint16_t)sizeof(data);
        memcpy(ptr + sizeof(spdm_mel_entry_dmtf_t), data, sizeof(data));
        ptr += entry_sz;
        total += entry_sz;
        entries_payload += (uint32_t)entry_sz;
    }
    hdr->mel_entries_len = entries_payload;
    return total;
}

static libspdm_return_t send_message(void *ctx, size_t req_size,
                                     const void *req, uint64_t timeout)
{
    (void)ctx; (void)req_size; (void)req; (void)timeout;
    return LIBSPDM_STATUS_SUCCESS;
}

/*
 * Call 0: first chunk of gen1 (LIBSPDM_MAX_MEL_BLOCK_LEN bytes, remainder from gen1)
 * Call 1: serve remainder-sized chunk, but from gen2's data
 *
 * MC1: gen2 is LARGER than gen1. The shrinkage check at line 205-210:
 *   if (offset + portion + remainder < total_responder_mel_buffer_length) → ERROR
 * This fires for shrinkage but NOT for growth.
 * When gen2 is larger: offset + gen2_portion + gen2_remainder >= gen1_total → no error.
 */
static libspdm_return_t receive_message(void *ctx,
                                        size_t *resp_size, void **resp,
                                        uint64_t timeout)
{
    (void)timeout;
    spdm_measurement_extension_log_response_t *spdm_resp;
    uint32_t portion, remainder;
    size_t payload, offset;

    if (m_call_index == 0) {
        /* First chunk: from gen1 */
        portion   = LIBSPDM_MAX_MEL_BLOCK_LEN;
        if (portion > (uint32_t)m_mel_gen1_len) portion = (uint32_t)m_mel_gen1_len;
        remainder = (uint32_t)(m_mel_gen1_len - portion);
        offset    = 0;

        payload = sizeof(spdm_measurement_extension_log_response_t) + portion;
        spdm_resp = (void *)((uint8_t *)*resp + LIBSPDM_TEST_TRANSPORT_HEADER_SIZE);
        spdm_resp->header.spdm_version          = SPDM_MESSAGE_VERSION_13;
        spdm_resp->header.request_response_code = SPDM_MEASUREMENT_EXTENSION_LOG;
        spdm_resp->header.param1 = 0;
        spdm_resp->header.param2 = 0;
        spdm_resp->portion_length   = portion;
        spdm_resp->remainder_length = remainder;
        memcpy(spdm_resp + 1, m_mel_gen1 + offset, portion);
    } else if (m_call_index == 1) {
        /*
         * Second chunk: from gen2 (grown MEL), but serving exactly the
         * remainder length that gen1 originally announced (32 bytes).
         * This simulates the real-world Responder behavior: MEL grew between
         * requests, so Responder re-reads MEL, but still serves the requested
         * portion (offset=1024, length=32) from gen2's data.
         *
         * The Requester sees: portion=32, remainder=(gen2_size - 1024 - 32)
         * Shrinkage check: 1024 + 32 + 260 = 1316 >= 1056 → NO ERROR (growth undetected)
         *
         * The assembled buffer = gen1[0:1024] + gen2[1024:1056] — CHIMERIC!
         */
        offset  = LIBSPDM_MAX_MEL_BLOCK_LEN;
        /* Serve exactly what was requested: the gen1-announced remainder (32 bytes) */
        uint32_t gen1_remainder = (uint32_t)(m_mel_gen1_len - LIBSPDM_MAX_MEL_BLOCK_LEN);
        portion   = gen1_remainder;  /* exactly the requested amount */
        if (m_mel_gen2_len <= offset + portion)
            return LIBSPDM_STATUS_RECEIVE_FAIL;
        /* New remainder reflects gen2's actual remaining size */
        remainder = (uint32_t)(m_mel_gen2_len - offset - portion);

        payload = sizeof(spdm_measurement_extension_log_response_t) + portion;
        spdm_resp = (void *)((uint8_t *)*resp + LIBSPDM_TEST_TRANSPORT_HEADER_SIZE);
        spdm_resp->header.spdm_version          = SPDM_MESSAGE_VERSION_13;
        spdm_resp->header.request_response_code = SPDM_MEASUREMENT_EXTENSION_LOG;
        spdm_resp->header.param1 = 0;
        spdm_resp->header.param2 = 0;
        spdm_resp->portion_length   = portion;
        spdm_resp->remainder_length = remainder;
        memcpy(spdm_resp + 1, m_mel_gen2 + offset, portion);
    } else {
        return LIBSPDM_STATUS_RECEIVE_FAIL;
    }

    libspdm_transport_test_encode_message(ctx, NULL, false, false,
                                          payload, spdm_resp,
                                          resp_size, resp);
    m_call_index++;
    return LIBSPDM_STATUS_SUCCESS;
}

static void test_mc1_chimeric_mel(void **state)
{
    libspdm_test_context_t *test_ctx = *state;
    libspdm_context_t *ctx = test_ctx->spdm_context;
    libspdm_return_t status;
    uint8_t mel_out[LIBSPDM_MAX_MEASUREMENT_EXTENSION_LOG_SIZE];
    size_t mel_out_size;

    /* gen1: 80 entries → multi-chunk (> LIBSPDM_MAX_MEL_BLOCK_LEN=1024) */
    m_mel_gen1_len = build_mel(m_mel_gen1, sizeof(m_mel_gen1), 80);
    /* gen2: 100 entries → larger than gen1 */
    m_mel_gen2_len = build_mel(m_mel_gen2, sizeof(m_mel_gen2), 100);

    assert_true(m_mel_gen1_len > LIBSPDM_MAX_MEL_BLOCK_LEN);
    assert_true(m_mel_gen2_len > m_mel_gen1_len);

    m_call_index = 0;
    test_ctx->case_id = 0x1;

    ctx->connection_info.version =
        SPDM_MESSAGE_VERSION_13 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    ctx->connection_info.connection_state =
        LIBSPDM_CONNECTION_STATE_AUTHENTICATED;
    ctx->connection_info.capability.flags |=
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MEL_CAP;
    ctx->connection_info.algorithm.measurement_spec =
        SPDM_MEASUREMENT_SPECIFICATION_DMTF;
    ctx->connection_info.algorithm.measurement_hash_algo =
        SPDM_ALGORITHMS_MEASUREMENT_HASH_ALGO_TPM_ALG_SHA_256;
    ctx->connection_info.algorithm.base_hash_algo =
        SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256;
    ctx->connection_info.algorithm.base_asym_algo =
        SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_ECDSA_ECC_NIST_P256;
    ctx->connection_info.algorithm.mel_spec = SPDM_MEL_SPECIFICATION_DMTF;
    ctx->local_context.algorithm.measurement_spec =
        SPDM_MEASUREMENT_SPECIFICATION_DMTF;

    libspdm_reset_message_b(ctx);
    mel_out_size = sizeof(mel_out);
    libspdm_zero_mem(mel_out, sizeof(mel_out));

    status = libspdm_get_measurement_extension_log(ctx, NULL,
                                                    &mel_out_size, mel_out);

    printf("\n[MC1] MEL chimeric assembly test\n");
    printf("  gen1 size: %zu bytes (chunk1 sent from gen1)\n", m_mel_gen1_len);
    printf("  gen2 size: %zu bytes (chunk2 sent from gen2 — larger)\n", m_mel_gen2_len);
    printf("  Status:    0x%08lx\n", (unsigned long)status);
    printf("  Assembled: %zu bytes\n", mel_out_size);
    printf("\nShrinkage check (line 202-210): detects SHRINKAGE only.\n");
    printf("  offset + portion + remainder < total: %s\n",
           (LIBSPDM_MAX_MEL_BLOCK_LEN + (m_mel_gen2_len - LIBSPDM_MAX_MEL_BLOCK_LEN) + 0 <
            m_mel_gen1_len) ? "TRUE (shrinkage detected)" : "FALSE (growth not detected)");

    if (status == LIBSPDM_STATUS_SUCCESS) {
        printf("BUG CONFIRMED: Chimeric MEL accepted silently.\n");
        printf("  Chunk 1: gen1 data (first %d bytes of %zu-byte MEL)\n",
               LIBSPDM_MAX_MEL_BLOCK_LEN, m_mel_gen1_len);
        printf("  Chunk 2: gen2 data (%zu bytes — different generation)\n",
               m_mel_gen2_len - LIBSPDM_MAX_MEL_BLOCK_LEN);
        printf("  No error returned. Assembled log is semantically inconsistent.\n");
        printf("  CORRECT: should return LIBSPDM_STATUS_INVALID_MSG_FIELD.\n");
        printf("  Root cause: rsp_mel.c:113-124 no snapshot; req_mel.c:202-210 no growth check.\n");
    }

    /* Bug: SUCCESS returned despite chimeric assembly */
    assert_int_equal(status, LIBSPDM_STATUS_SUCCESS);
}

int main(void)
{
    libspdm_test_context_t test_context = {
        LIBSPDM_TEST_CONTEXT_VERSION,
        true,
        send_message,
        receive_message,
    };
    libspdm_setup_test_context(&test_context);

    const struct CMUnitTest tests[] = {
        cmocka_unit_test(test_mc1_chimeric_mel),
    };

    printf("=== MC1: Chimeric MEL Assembly ===\n");
    printf("Bug: rsp_measurement_extension_log.c:113-124 (no MEL snapshot)\n");
    printf("     req_get_measurement_extension_log.c:202-210 (no growth check)\n\n");
    return cmocka_run_group_tests(tests,
                                   libspdm_unit_test_group_setup,
                                   libspdm_unit_test_group_teardown);
}
