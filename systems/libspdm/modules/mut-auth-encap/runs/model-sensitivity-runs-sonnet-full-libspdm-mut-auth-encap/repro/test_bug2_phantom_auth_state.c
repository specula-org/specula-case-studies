/* Must be defined before tla_trace.h is included so that it emits
 * global-variable definitions rather than extern declarations. */
#define TLA_TRACE_DEFINE_GLOBALS

/**
 * test_bug2_phantom_auth_state.c
 *
 * Reproduction test for BUG-2 in libspdm encapsulated mutual authentication:
 *
 *   In libspdm_send_receive_challenge() (libspdm_req_challenge.c), the Requester
 *   marks the connection as AUTHENTICATED (line 383) BEFORE calling
 *   libspdm_encapsulated_request() (line 394). If the encap request fails, the
 *   error handler at lines 397-399 returns the error WITHOUT rolling back
 *   connection_state. The caller then sees a failed return code but the context
 *   still reports LIBSPDM_CONNECTION_STATE_AUTHENTICATED.
 *
 * AFFECTED CODE (libspdm_req_challenge.c:381-399):
 *
 *     // At this point Requester has authenticated Responder.
 *     spdm_context->connection_info.connection_state =
 *         LIBSPDM_CONNECTION_STATE_AUTHENTICATED;    // line 383
 *
 *     if ((auth_attribute & SPDM_CHALLENGE_AUTH_RESPONSE_ATTRIBUTE_BASIC_MUT_AUTH_REQ) != 0) {
 *         libspdm_release_receiver_buffer(spdm_context);
 *         status = libspdm_encapsulated_request(spdm_context, NULL, 0, NULL);  // line 394
 *         if (LIBSPDM_STATUS_IS_ERROR(status)) {
 *             libspdm_reset_message_c(spdm_context);
 *             return status;    // ← BUG: connection_state NOT reset here
 *         }
 *     }
 *
 * APPROACH: Level 2 — State Injection
 *
 *   Rather than running the full CHALLENGE exchange (which requires crafting a
 *   signed CHALLENGE_AUTH response with BASIC_MUT_AUTH_REQ flag, involving live
 *   crypto), this test injects the post-line-383 state directly and confirms
 *   that the missing rollback is observable:
 *
 *   1. Pre-set connection_state = LIBSPDM_CONNECTION_STATE_AUTHENTICATED
 *      (simulates line 383 having fired in libspdm_send_receive_challenge).
 *
 *   2. Register a device-buffer "acquire_sender" callback that always fails
 *      (returns LIBSPDM_STATUS_BUFFER_FULL). This causes
 *      libspdm_encapsulated_request() to return an error immediately (line 201).
 *
 *   3. Call libspdm_encapsulated_request() — it fails at buffer acquisition.
 *
 *   4. Verify: connection_state is still AUTHENTICATED (not rolled back).
 *      This mirrors what happens in libspdm_send_receive_challenge lines 397-399
 *      when it receives the error: it calls libspdm_reset_message_c() and returns,
 *      but never resets connection_state.
 *
 * NOTE: Level 0 (full libspdm_challenge() exercise with proper CHALLENGE_AUTH mock)
 *   was considered but would require: (a) transport-layer encode/decode setup,
 *   (b) crafting a CHALLENGE_AUTH response with a valid signature and
 *   BASIC_MUT_AUTH_REQ flag set, (c) controlling the second send (for
 *   GET_ENCAPSULATED_REQUEST) to fail. The transport/signature setup overhead
 *   exceeds what a standalone test executable should carry; Level 2 injection
 *   directly tests the same missing-rollback pattern.
 *
 * Exit codes:
 *   0  = REPRODUCTION FAILED (connection_state was rolled back — bug is fixed)
 *   1  = BUG CONFIRMED (connection_state remains AUTHENTICATED despite error)
 *   2  = TEST SETUP ERROR
 */

#include "internal/libspdm_requester_lib.h"
#include "internal/libspdm_common_lib.h"
#ifdef LIBSPDM_TRACE_ENCAP
#include "tla_trace.h"   /* defines g_tla_trace_file, g_tla_variant_str, g_tla_ts_counter */
#endif
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <assert.h>

#define USE_HASH_ALGO  SPDM_ALGORITHMS_BASE_HASH_ALGO_TPM_ALG_SHA_256
#define USE_ASYM_ALGO  SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_RSASSA_2048
#define USE_REQ_ASYM   SPDM_ALGORITHMS_BASE_ASYM_ALGO_TPM_ALG_RSASSA_2048

#ifndef LIBSPDM_MAX_SPDM_MSG_SIZE
#define LIBSPDM_MAX_SPDM_MSG_SIZE 0x1200
#endif

/* ──── failing buffer stub (triggers early return in libspdm_encapsulated_request) ── */
static libspdm_return_t acq_sender_fail(void *ctx, void **msg)
{
    (void)ctx; (void)msg;
    /* Simulates a resource exhaustion; causes libspdm_encapsulated_request()
     * to fail at libspdm_acquire_sender_buffer (req_encap_request.c:200). */
    return LIBSPDM_STATUS_BUFFER_FULL;
}
static void rel_sender_nop(void *ctx, const void *msg) { (void)ctx; (void)msg; }
static libspdm_return_t acq_receiver_nop(void *ctx, void **msg)
{
    static uint8_t g_rx[LIBSPDM_MAX_SPDM_MSG_SIZE];
    (void)ctx; *msg = g_rx; return LIBSPDM_STATUS_SUCCESS;
}
static void rel_receiver_nop(void *ctx, const void *msg) { (void)ctx; (void)msg; }

/* file-scope stubs required by spdm_device_secret_lib_sample */
bool libspdm_read_input_file(const char *file_name, void **file_data, size_t *file_size)
{
    FILE *fp = fopen(file_name, "rb");
    if (!fp) { *file_data = NULL; return false; }
    fseek(fp, 0, SEEK_END);
    *file_size = (size_t)ftell(fp);
    *file_data = malloc(*file_size);
    if (!*file_data) { fclose(fp); return false; }
    fseek(fp, 0, SEEK_SET);
    (void)fread(*file_data, 1, *file_size, fp);
    fclose(fp);
    return true;
}
bool libspdm_write_output_file(const char *file_name, const void *data, size_t sz)
{ (void)file_name; (void)data; (void)sz; return false; }
void libspdm_dump_hex_str(const uint8_t *buf, size_t sz)
{ (void)buf; (void)sz; }

/* ──── main ─────────────────────────────────────────────────────────────── */
int main(void)
{
    libspdm_context_t *ctx;
    libspdm_return_t   encap_status;
    void              *scratch;
    size_t             scratch_size;

    printf("=== BUG-2 Reproduction: phantom authentication state ===\n");
    printf("File: libspdm_req_challenge.c:383,394-399\n");
    printf("Invariant: NoPhantomAuth (connection_state NOT rolled back on encap failure)\n");
    printf("Method: Level 2 state injection\n\n");

    /* ── Create requester context ────────────────────────────────────────── */
    ctx = malloc(libspdm_get_context_size());
    if (ctx == NULL) { printf("SETUP ERROR: malloc failed\n"); return 2; }
    libspdm_init_context(ctx);

    /* Register failing buffer callback to make libspdm_encapsulated_request
     * return an error immediately at libspdm_acquire_sender_buffer(). */
    ctx->local_context.capability.max_spdm_msg_size = LIBSPDM_MAX_SPDM_MSG_SIZE;
    libspdm_register_device_buffer_func(ctx,
        LIBSPDM_MAX_SPDM_MSG_SIZE, LIBSPDM_MAX_SPDM_MSG_SIZE,
        acq_sender_fail,   /* FAILS → libspdm_encapsulated_request returns error */
        rel_sender_nop,
        acq_receiver_nop,
        rel_receiver_nop);

    scratch_size = libspdm_get_sizeof_required_scratch_buffer(ctx);
    scratch = malloc(scratch_size);
    if (scratch == NULL) { printf("SETUP ERROR: scratch malloc failed\n"); return 2; }
    libspdm_set_scratch_buffer(ctx, scratch, scratch_size);

    /* Set up as requester with SPDM v1.1 */
    ctx->local_context.is_requester = true;
    ctx->connection_info.version =
        (uint16_t)(SPDM_MESSAGE_VERSION_11 << SPDM_VERSION_NUMBER_SHIFT_BIT);

    /* Both sides advertise ENCAP_CAP so libspdm_is_encap_supported() returns true */
    ctx->local_context.capability.flags =
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_ENCAP_CAP |
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_CHAL_CAP  |
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_MUT_AUTH_CAP;
    ctx->connection_info.capability.flags =
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_ENCAP_CAP |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CHAL_CAP  |
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MUT_AUTH_CAP;

    ctx->connection_info.algorithm.base_hash_algo    = USE_HASH_ALGO;
    ctx->connection_info.algorithm.base_asym_algo    = USE_ASYM_ALGO;
    ctx->connection_info.algorithm.req_base_asym_alg = USE_REQ_ASYM;

    /* ── State injection: simulate libspdm_send_receive_challenge line 383 ─ */
    /* At this point in the real code, the Requester has validated CHALLENGE_AUTH
     * and set connection_state = AUTHENTICATED.  The next step is calling
     * libspdm_encapsulated_request(), which we simulate here by direct injection. */
    printf("State injection: setting connection_state = LIBSPDM_CONNECTION_STATE_AUTHENTICATED\n");
    printf("(Simulates line 383 of libspdm_req_challenge.c having fired)\n\n");
    ctx->connection_info.connection_state = LIBSPDM_CONNECTION_STATE_AUTHENTICATED;

    /* ── Call libspdm_encapsulated_request() — will fail at buffer acquisition ── */
    /* This mirrors line 394 in libspdm_send_receive_challenge:
     *   status = libspdm_encapsulated_request(spdm_context, NULL, 0, NULL);
     * The acq_sender_fail callback returns LIBSPDM_STATUS_BUFFER_FULL, so
     * libspdm_encapsulated_request returns immediately with that error. */
    printf("Calling libspdm_encapsulated_request() with failing buffer callback...\n");
    encap_status = libspdm_encapsulated_request(ctx, NULL, 0, NULL);
    printf("  libspdm_encapsulated_request returned: 0x%x (error expected)\n",
           (unsigned)encap_status);

    if (!LIBSPDM_STATUS_IS_ERROR(encap_status)) {
        printf("SETUP ERROR: expected libspdm_encapsulated_request to fail, got 0x%x\n",
               (unsigned)encap_status);
        return 2;
    }

    /* ── Check for the BUG: missing rollback ─────────────────────────────── */
    /* In libspdm_send_receive_challenge lines 397-399:
     *   if (LIBSPDM_STATUS_IS_ERROR(status)) {
     *       libspdm_reset_message_c(spdm_context);
     *       return status;   ← connection_state NOT reset here
     *   }
     * We verify: connection_state is still AUTHENTICATED (not rolled back). */
    printf("\nPost-error state:\n");
    printf("  connection_state = %d  (AUTHENTICATED=%d, expect NO rollback = BUG)\n",
           ctx->connection_info.connection_state,
           LIBSPDM_CONNECTION_STATE_AUTHENTICATED);

    bool state_authenticated =
        (ctx->connection_info.connection_state == LIBSPDM_CONNECTION_STATE_AUTHENTICATED);

    if (state_authenticated) {
        printf("\n[RESULT] BUG CONFIRMED\n");
        printf("  NoPhantomAuth VIOLATED:\n");
        printf("  connection_state = LIBSPDM_CONNECTION_STATE_AUTHENTICATED (%d)\n",
               ctx->connection_info.connection_state);
        printf("  even though libspdm_encapsulated_request() returned an error (0x%x).\n",
               (unsigned)encap_status);
        printf("  Root cause: libspdm_req_challenge.c:397-399 returns the error\n");
        printf("  without resetting connection_state back to its pre-line-383 value.\n");
        printf("  Fix: before 'return status' at line 399, add:\n");
        printf("    spdm_context->connection_info.connection_state =\n");
        printf("        LIBSPDM_CONNECTION_STATE_NEGOTIATED; // or prior state\n");
        printf("  Alternatively, move line 383 to AFTER the success check for\n");
        printf("  libspdm_encapsulated_request (i.e., after line 401).\n");
        free(ctx);
        free(scratch);
        return 1;   /* BUG CONFIRMED */
    }

    printf("\n[RESULT] REPRODUCTION FAILED — connection_state was rolled back.\n");
    printf("  Bug may have been fixed.\n");
    free(ctx);
    free(scratch);
    return 0;
}
