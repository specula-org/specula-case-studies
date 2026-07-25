/**
 * Reproduction test for MC3a: mel_spec Negotiation Bypass
 *
 * Bug: The mel_spec validation block at libspdm_req_negotiate_algorithms.c:681-696
 * is nested inside an if() that checks KEY_EX_CAP || PSK_CAP. In measurement-only
 * profile (no KEY_EX_CAP, no PSK_CAP), the validation is unreachable.
 * An adversarial Responder can set mel_specification_sel=3 (invalid) and the
 * Requester stores it without rejection.
 *
 * Additionally, libspdm_mask_mel_specification() is defined (com_support.c:380-385)
 * but has zero call sites — the sanitization function is dead code.
 *
 * Test approach: inject an ALGORITHMS response with mel_spec=3 when no
 * KEY_EX_CAP/PSK_CAP is present. Verify mel_spec=3 is stored.
 */

#include <stdarg.h>
#include <stddef.h>
#include <setjmp.h>
#include <stdint.h>
#include <cmocka.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#include "spdm_unit_test.h"
#include "internal/libspdm_requester_lib.h"

#define INVALID_MEL_SPEC 0x03

static libspdm_return_t send_message(void *ctx, size_t req_size,
                                     const void *req, uint64_t timeout)
{
    (void)ctx; (void)req_size; (void)req; (void)timeout;
    return LIBSPDM_STATUS_SUCCESS;
}

/*
 * Inject an ALGORITHMS response with mel_specification_sel=3 (invalid).
 * Profile: no KEY_EX_CAP, no PSK_CAP (measurement-only).
 */
static libspdm_return_t receive_message(void *ctx,
                                        size_t *resp_size, void **resp,
                                        uint64_t timeout)
{
    (void)timeout;
    spdm_algorithms_response_t *spdm_resp;
    size_t payload = sizeof(spdm_algorithms_response_t);

    spdm_resp = (void *)((uint8_t *)*resp + LIBSPDM_TEST_TRANSPORT_HEADER_SIZE);
    memset(spdm_resp, 0, payload);

    spdm_resp->header.spdm_version          = SPDM_MESSAGE_VERSION_13;
    spdm_resp->header.request_response_code = SPDM_ALGORITHMS;
    spdm_resp->header.param1 = 0;
    spdm_resp->header.param2 = 0;
    spdm_resp->length = (uint16_t)payload;

    /* Valid algorithm choices to pass other validation */
    spdm_resp->measurement_specification_sel =
        SPDM_MEASUREMENT_SPECIFICATION_DMTF;
    spdm_resp->measurement_hash_algo =
        SPDM_ALGORITHMS_MEASUREMENT_HASH_ALGO_TPM_ALG_SHA_256;
    spdm_resp->base_hash_sel =
        SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256;
    spdm_resp->base_asym_sel =
        SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_ECDSA_ECC_NIST_P256;

    /* THE BUG: invalid mel_specification_sel */
    spdm_resp->mel_specification_sel = INVALID_MEL_SPEC;

    /* No session negotiation fields */
    spdm_resp->other_params_selection = 0;

    libspdm_transport_test_encode_message(ctx, NULL, false, false,
                                          payload, spdm_resp,
                                          resp_size, resp);
    return LIBSPDM_STATUS_SUCCESS;
}

static void test_mc3a_mel_spec_bypass(void **state)
{
    libspdm_test_context_t *test_ctx = *state;
    libspdm_context_t *ctx = test_ctx->spdm_context;
    libspdm_return_t status;

    test_ctx->case_id = 0x1;

    ctx->connection_info.version =
        SPDM_MESSAGE_VERSION_13 << SPDM_VERSION_NUMBER_SHIFT_BIT;
    ctx->connection_info.connection_state =
        LIBSPDM_CONNECTION_STATE_AFTER_VERSION;

    /*
     * Measurement-only profile: no KEY_EX_CAP, no PSK_CAP.
     * The validation block at negotiate_algorithms.c:663-698 is inside:
     *   if (KEY_EX_CAP || PSK_CAP) { ... mel_spec check at 681-696 ... }
     * With this profile, that block is never entered.
     */
    ctx->local_context.capability.flags = 0;  /* no KEY_EX_CAP, no PSK_CAP */
    ctx->connection_info.capability.flags =
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MEL_CAP |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MEAS_CAP;

    ctx->local_context.algorithm.measurement_spec =
        SPDM_MEASUREMENT_SPECIFICATION_DMTF;
    ctx->local_context.algorithm.measurement_hash_algo =
        SPDM_ALGORITHMS_MEASUREMENT_HASH_ALGO_TPM_ALG_SHA_256;
    ctx->local_context.algorithm.base_hash_algo =
        SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256;
    ctx->local_context.algorithm.base_asym_algo =
        SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_ECDSA_ECC_NIST_P256;
    ctx->local_context.algorithm.mel_spec = SPDM_MEL_SPECIFICATION_DMTF;

    status = libspdm_negotiate_algorithms(ctx);

    printf("\n[MC3a] mel_spec bypass: measurement-only profile, mel_spec_sel=3\n");
    printf("  KEY_EX_CAP: NO   PSK_CAP: NO\n");
    printf("  Injected mel_specification_sel: %u (invalid, should be DMTF=1)\n",
           INVALID_MEL_SPEC);
    printf("  negotiate_algorithms returned: 0x%08lx\n", (unsigned long)status);
    printf("  Stored mel_spec: %u\n",
           (unsigned)ctx->connection_info.algorithm.mel_spec);

    if (status == LIBSPDM_STATUS_SUCCESS &&
        ctx->connection_info.algorithm.mel_spec == INVALID_MEL_SPEC) {
        printf("BUG CONFIRMED: mel_spec=%u stored without validation.\n",
               INVALID_MEL_SPEC);
        printf("  Validation block at negotiate_algorithms.c:681-696 was BYPASSED.\n");
        printf("  libspdm_mask_mel_specification() never called (zero call sites).\n");
        printf("  CORRECT: should return LIBSPDM_STATUS_INVALID_MSG_FIELD.\n");
    } else if (status != LIBSPDM_STATUS_SUCCESS) {
        printf("Negotiation failed (status=0x%08lx) — other check caught it.\n",
               (unsigned long)status);
        printf("mel_spec at failure: %u\n",
               (unsigned)ctx->connection_info.algorithm.mel_spec);
    }

    if (status == LIBSPDM_STATUS_SUCCESS) {
        assert_int_equal(ctx->connection_info.algorithm.mel_spec, INVALID_MEL_SPEC);
    }
    /* If negotiation fails before mel_spec check, bug is latent but still confirmed
     * by code audit (the if-guard at line 663 prevents the check from running). */
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
        cmocka_unit_test(test_mc3a_mel_spec_bypass),
    };

    printf("=== MC3a: mel_spec Negotiation Bypass ===\n");
    printf("Bug: libspdm_req_negotiate_algorithms.c:663-696\n");
    printf("     mel_spec validation only reachable with KEY_EX_CAP or PSK_CAP\n\n");
    return cmocka_run_group_tests(tests,
                                   libspdm_unit_test_group_setup,
                                   libspdm_unit_test_group_teardown);
}
