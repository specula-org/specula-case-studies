/**
 * Reproduction test for MC3b: Missing Pre-Send mel_spec Guard
 *
 * Bug: libspdm_try_get_measurement_extension_log performs pre-send checks at
 * libspdm_req_get_measurement_extension_log.c:52-77 but does NOT check
 * connection_info.algorithm.mel_spec != 0 before issuing GET_MEL.
 *
 * BUG: Should return LIBSPDM_STATUS_UNSUPPORTED_CAP before sending any request.
 * ACTUAL: Sends GET_MEL, receives UNEXPECTED_REQUEST error from Responder.
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

static bool m_request_was_sent = false;

static libspdm_return_t send_message(void *ctx, size_t req_size,
                                     const void *req, uint64_t timeout)
{
    (void)ctx; (void)req_size; (void)req; (void)timeout;
    /* Any call to send_message means the pre-send check was bypassed.
     * With a correct pre-send guard, send_message is never called (UNSUPPORTED_CAP
     * returned before reaching the send point). */
    m_request_was_sent = true;
    printf("  [OBSERVED] send_message called — GET_MEL was sent despite mel_spec=0!\n");
    return LIBSPDM_STATUS_SUCCESS;
}

static libspdm_return_t receive_message(void *ctx,
                                        size_t *resp_size, void **resp,
                                        uint64_t timeout)
{
    (void)timeout;
    /* Simulate Responder's UNEXPECTED_REQUEST when mel_spec=0 */
    spdm_error_response_t *err;
    size_t payload = sizeof(spdm_error_response_t);
    err = (void *)((uint8_t *)*resp + LIBSPDM_TEST_TRANSPORT_HEADER_SIZE);
    err->header.spdm_version             = SPDM_MESSAGE_VERSION_13;
    err->header.request_response_code    = SPDM_ERROR;
    err->header.param1                   = SPDM_ERROR_CODE_UNEXPECTED_REQUEST;
    err->header.param2                   = 0;
    libspdm_transport_test_encode_message(ctx, NULL, false, false,
                                          payload, err, resp_size, resp);
    return LIBSPDM_STATUS_SUCCESS;
}

static void test_mc3b_no_presend_check(void **state)
{
    libspdm_test_context_t *test_ctx = *state;
    libspdm_context_t *ctx = test_ctx->spdm_context;
    libspdm_return_t status;
    uint8_t mel_out[LIBSPDM_MAX_MEASUREMENT_EXTENSION_LOG_SIZE];
    size_t mel_out_size;

    m_request_was_sent = false;
    test_ctx->case_id = 0x1;

    ctx->connection_info.version =
        SPDM_MESSAGE_VERSION_13 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    ctx->connection_info.connection_state =
        LIBSPDM_CONNECTION_STATE_NEGOTIATED;
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
    ctx->local_context.algorithm.measurement_spec =
        SPDM_MEASUREMENT_SPECIFICATION_DMTF;

    /* THE KEY CONDITION: mel_spec = 0 (MEL not negotiated) */
    ctx->connection_info.algorithm.mel_spec = 0;

    libspdm_reset_message_b(ctx);
    mel_out_size = sizeof(mel_out);
    libspdm_zero_mem(mel_out, sizeof(mel_out));

    status = libspdm_get_measurement_extension_log(ctx, NULL,
                                                    &mel_out_size, mel_out);

    printf("\n[MC3b] mel_spec=0, called libspdm_get_measurement_extension_log\n");
    printf("  Returned status:   0x%08lx\n", (unsigned long)status);
    printf("  Request sent wire: %s\n",
           m_request_was_sent ? "YES (BUG)" : "NO");
    printf("  Expected (fixed):  LIBSPDM_STATUS_UNSUPPORTED_CAP, no request sent\n");

    if (m_request_was_sent) {
        printf("BUG CONFIRMED: GET_MEL was sent despite mel_spec=0.\n");
        printf("  Missing pre-send check: libspdm_req_get_mel.c:52-77\n");
        printf("  Responder guard (exists): rsp_measurement_extension_log.c:86-91\n");
    }

    /* Bug demonstrated: the request IS sent (pre-send check is missing) */
    assert_true(m_request_was_sent);
}

static libspdm_return_t send_message_noop(void *ctx, size_t req_size,
                                           const void *req, uint64_t timeout)
{
    (void)ctx; (void)req_size; (void)req; (void)timeout;
    return LIBSPDM_STATUS_SUCCESS;
}

static libspdm_return_t receive_message_noop(void *ctx,
                                              size_t *resp_size, void **resp,
                                              uint64_t timeout)
{
    (void)ctx; (void)resp_size; (void)resp; (void)timeout;
    return LIBSPDM_STATUS_RECEIVE_FAIL;
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
        cmocka_unit_test(test_mc3b_no_presend_check),
    };

    printf("=== MC3b: Missing Pre-Send mel_spec Guard ===\n");
    printf("Bug: libspdm_req_get_measurement_extension_log.c:52-77\n");
    printf("     No check for mel_spec != 0 before sending GET_MEL\n\n");
    return cmocka_run_group_tests(tests,
                                   libspdm_unit_test_group_setup,
                                   libspdm_unit_test_group_teardown);
}
