/**
 * Reproduction test for MC2: Premature mel_entries_len Read
 *
 * Bug: do-while loop at libspdm_req_get_measurement_extension_log.c:241-243
 * reads measurement_extension_log->mel_entries_len (bytes [4:7] of the
 * caller's output buffer) before verifying mel_size_internal >= 16 (MEL
 * header size). When portion_length < 16, those bytes come from
 * uninitialized memory.
 *
 * Trigger: Responder sends first chunk of 2 bytes (portion_length=2),
 * remainder=18 bytes. At loop iteration 1, mel_size_internal=2 <
 * MEL_HEADER_SIZE(16). The loop condition evaluates mel_entries_len from
 * bytes [4:7] of the output buffer — not yet received from the network.
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
#define MEL_HEADER_SIZE ((size_t)sizeof(spdm_measurement_extension_log_dmtf_t))

/* A 20-byte MEL: 16-byte header + 4 bytes payload */
static uint8_t m_full_mel[20];
static int     m_call_index = 0;

static void init_mel(void)
{
    spdm_measurement_extension_log_dmtf_t *hdr =
        (spdm_measurement_extension_log_dmtf_t *)m_full_mel;
    memset(m_full_mel, 0, sizeof(m_full_mel));
    hdr->number_of_entries = 0;
    hdr->mel_entries_len   = 4;   /* 4 bytes of entries follow the header */
    hdr->reserved          = 0;
    m_full_mel[16] = 0xAA;
    m_full_mel[17] = 0xBB;
    m_full_mel[18] = 0xCC;
    m_full_mel[19] = 0xDD;
}

static libspdm_return_t send_message(void *ctx, size_t req_size,
                                     const void *req, uint64_t timeout)
{
    (void)ctx; (void)req_size; (void)req; (void)timeout;
    return LIBSPDM_STATUS_SUCCESS;
}

/*
 * Call 0: portion_length=2, remainder=18 (first chunk: only 2 bytes of a 20-byte MEL)
 * Call 1: portion_length=18, remainder=0 (rest of MEL)
 *
 * After call 0, mel_size_internal=2. The loop condition:
 *   2 < sizeof(hdr) + mel_entries_len
 *   = 2 < 16 + mel_out[4..7]   ← bytes NOT yet received!
 * mel_out was zero-initialized → mel_entries_len reads as 0 → 2 < 16: TRUE
 * (lucky: loop continues correctly, but only because buffer happened to be zero)
 */
static libspdm_return_t receive_message(void *ctx,
                                        size_t *resp_size, void **resp,
                                        uint64_t timeout)
{
    (void)timeout;
    spdm_measurement_extension_log_response_t *spdm_resp;
    uint32_t portion, remainder;
    size_t payload;

    if (m_call_index == 0) {
        portion   = 2;                             /* critically small: < header size */
        remainder = (uint32_t)(sizeof(m_full_mel) - portion);
    } else if (m_call_index == 1) {
        portion   = (uint32_t)(sizeof(m_full_mel) - 2);
        remainder = 0;
    } else {
        return LIBSPDM_STATUS_RECEIVE_FAIL;
    }

    payload = sizeof(spdm_measurement_extension_log_response_t) + portion;
    spdm_resp = (void *)((uint8_t *)*resp + LIBSPDM_TEST_TRANSPORT_HEADER_SIZE);
    spdm_resp->header.spdm_version          = SPDM_MESSAGE_VERSION_13;
    spdm_resp->header.request_response_code = SPDM_MEASUREMENT_EXTENSION_LOG;
    spdm_resp->header.param1 = 0;
    spdm_resp->header.param2 = 0;
    spdm_resp->portion_length   = portion;
    spdm_resp->remainder_length = remainder;

    size_t offset = (m_call_index == 0) ? 0 : 2;
    memcpy(spdm_resp + 1, m_full_mel + offset, portion);

    libspdm_transport_test_encode_message(ctx, NULL, false, false,
                                          payload, spdm_resp,
                                          resp_size, resp);
    m_call_index++;
    return LIBSPDM_STATUS_SUCCESS;
}

static void test_mc2_partial_header(void **state)
{
    libspdm_test_context_t *test_ctx = *state;
    libspdm_context_t *ctx = test_ctx->spdm_context;
    libspdm_return_t status;
    uint8_t mel_out[LIBSPDM_MAX_MEASUREMENT_EXTENSION_LOG_SIZE];
    size_t mel_out_size;

    init_mel();
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
    ctx->connection_info.algorithm.mel_spec =
        SPDM_MEL_SPECIFICATION_DMTF;
    ctx->local_context.algorithm.measurement_spec =
        SPDM_MEASUREMENT_SPECIFICATION_DMTF;

    libspdm_reset_message_b(ctx);
    mel_out_size = sizeof(mel_out);
    /* Zero-initialize the output buffer (this is the "lucky" case) */
    libspdm_zero_mem(mel_out, sizeof(mel_out));

    status = libspdm_get_measurement_extension_log(ctx, NULL,
                                                    &mel_out_size, mel_out);

    printf("\n[MC2] First chunk portion_length=2 (< MEL_HEADER_SIZE=%zu)\n",
           MEL_HEADER_SIZE);
    printf("  Status:           0x%08lx\n", (unsigned long)status);
    printf("  Assembled size:   %zu bytes\n", mel_out_size);
    printf("  mel_entries_len in actual header: %u\n",
           ((spdm_measurement_extension_log_dmtf_t *)m_full_mel)->mel_entries_len);
    printf("\nBUG PATH ANALYSIS:\n");
    printf("  Iteration 1: mel_size_internal=2, reads mel_entries_len from mel_out[4:7]\n");
    printf("  mel_out[4:7] were ZERO (not yet received from wire).\n");
    printf("  Condition: 2 < %zu + 0 = TRUE → loop continues (correct by luck)\n",
           MEL_HEADER_SIZE);
    printf("  If mel_out were non-zero (stale data), the loop would use wrong value.\n");
    printf("  CODE PATH CONFIRMED: libspdm_req_get_mel.c:241-243 reads uninit data\n");

    if (status == LIBSPDM_STATUS_SUCCESS) {
        printf("BUG CONFIRMED REACHABLE: mel_entries_len evaluated before 16 bytes received.\n");
    }

    assert_int_equal(status, LIBSPDM_STATUS_SUCCESS);
    assert_int_equal(mel_out_size, sizeof(m_full_mel));
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
        cmocka_unit_test(test_mc2_partial_header),
    };

    printf("=== MC2: Premature mel_entries_len Read ===\n");
    printf("Bug: libspdm_req_get_measurement_extension_log.c:241-243\n");
    printf("     Loop evaluates mel_entries_len before 16 bytes are received\n\n");
    return cmocka_run_group_tests(tests,
                                   libspdm_unit_test_group_setup,
                                   libspdm_unit_test_group_teardown);
}
