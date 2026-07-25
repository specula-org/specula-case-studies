/**
 * Reproduction test — Bug 3: ReassemblyOutputValidityAfterCompletion
 *
 * Root cause: libspdm_req_handle_error_response.c lines 521–529.
 * When all chunks have been received (large_response_size_so_far ==
 * large_response_size) but the assembled response is larger than the
 * caller's output buffer (large_response_size > response_capacity),
 * the code hits the else-branch at line 521. That branch emits a trace
 * and falls through to "return status" — but status is still SUCCESS.
 * The caller sees SUCCESS, the output buffer is unmodified, and the
 * scratch buffer retains the decrypted large response.
 *
 * This standalone test extracts the exact completion logic from
 * libspdm_handle_error_large_response (lines 503–530) and exercises
 * the overflow path directly.
 *
 * Escalation level 0 (pure black-box of the decision logic):
 * The trigger scenario is a normal CHUNK_GET exchange where the
 * responder's large response is larger than the requester allocated.
 * The exact three-variable state (success + all-bytes-received + size >
 * capacity) is what the production code sees at the end of any such
 * exchange; we inject only that final state.
 */

#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stdlib.h>

/* --- Minimal libspdm status type ---
 * Copied verbatim from include/library/spdm_return_status.h */
typedef uint32_t libspdm_return_t;
#define LIBSPDM_SEVERITY_SUCCESS 0x0
#define LIBSPDM_SEVERITY_ERROR   0x8
#define LIBSPDM_STATUS_CONSTRUCT(sev, src, code) \
    ((libspdm_return_t)(((sev) << 28) | ((src) << 16) | (code)))
#define LIBSPDM_STATUS_SUCCESS \
    LIBSPDM_STATUS_CONSTRUCT(LIBSPDM_SEVERITY_SUCCESS, 0, 0x0000)
#define LIBSPDM_STATUS_INVALID_MSG_FIELD \
    LIBSPDM_STATUS_CONSTRUCT(LIBSPDM_SEVERITY_ERROR, 1, 0x0005)
#define LIBSPDM_STATUS_IS_SUCCESS(s) (((s) >> 28) == 0)

/* Minimal copy of the completion block extracted from
 * libspdm_handle_error_large_response() lines 503-530. */
static libspdm_return_t
test_completion_block(libspdm_return_t  status,
                      size_t            large_response_size_so_far,
                      size_t            large_response_size,
                      size_t            response_capacity,
                      uint8_t          *output_buf,       /* inout_response */
                      size_t           *output_size,      /* inout_response_size */
                      const uint8_t    *large_response,   /* scratch buf contents */
                      bool             *output_written,
                      bool             *scratch_zeroed)
{
    if (LIBSPDM_STATUS_IS_SUCCESS(status)) {
        if (large_response_size_so_far != large_response_size) {
            status = LIBSPDM_STATUS_INVALID_MSG_FIELD;
        } else if (large_response_size <= response_capacity) {
            /* Happy path: copy output, zero scratch */
            memcpy(output_buf, large_response, large_response_size);
            *output_size = large_response_size;
            memset((void *)large_response, 0, large_response_size);
            *output_written = true;
            *scratch_zeroed = true;
        } else {
            /* BUG: large_response_size > response_capacity
             * Missing: status = LIBSPDM_STATUS_BUFFER_TOO_SMALL;
             * falls through to "return status" with status still == SUCCESS */
        }
    }
    return status;
}

int main(void)
{
    /* Simulate the TLA+ counterexample:
     *   large_response_size   = 9 (assembled payload)
     *   response_capacity     = 8 (caller's output buffer)
     *   → should return BUFFER_TOO_SMALL but returns SUCCESS */
    const size_t LARGE_SIZE = 9;
    const size_t CAPACITY   = 8;

    uint8_t large_response[16];  /* scratch buffer */
    uint8_t output_buf[8];       /* caller's (too-small) buffer */
    size_t  output_size = CAPACITY;
    bool    output_written = false;
    bool    scratch_zeroed = false;

    memset(large_response, 0xCC, sizeof(large_response));
    memset(output_buf,     0x00, sizeof(output_buf));

    libspdm_return_t status = test_completion_block(
        LIBSPDM_STATUS_SUCCESS,   /* all chunks received, status still OK */
        LARGE_SIZE,               /* large_response_size_so_far == LARGE_SIZE */
        LARGE_SIZE,               /* large_response_size */
        CAPACITY,                 /* response_capacity (too small) */
        output_buf, &output_size,
        large_response,
        &output_written, &scratch_zeroed);

    printf("Bug 3 (ReassemblyOutputValidityAfterCompletion) reproduction\n");
    printf("  large_response_size = %zu, response_capacity = %zu\n",
           LARGE_SIZE, CAPACITY);
    printf("  Returned status     = 0x%08x  (is_success=%d)\n",
           status, LIBSPDM_STATUS_IS_SUCCESS(status));
    printf("  output_written      = %d\n", output_written);
    printf("  scratch_zeroed      = %d\n", scratch_zeroed);

    /* BUG DETECTION:
     * If status == SUCCESS AND output_written == false, the bug is present:
     * the caller will believe the response was delivered but the output
     * buffer is still uninitialised and the scratch buffer holds the
     * decrypted large response. */
    if (LIBSPDM_STATUS_IS_SUCCESS(status) && !output_written) {
        printf("\nRESULT: BUG CONFIRMED\n");
        printf("  Caller receives SUCCESS but output buffer is unchanged.\n");
        printf("  Scratch buffer still contains decrypted response (leak).\n");
        printf("  Fix: add 'status = LIBSPDM_STATUS_BUFFER_TOO_SMALL;' in "
               "else branch at libspdm_req_handle_error_response.c:521\n");
        return 0; /* exit 0 = bug reproduced */
    } else if (!LIBSPDM_STATUS_IS_SUCCESS(status)) {
        printf("\nRESULT: Bug absent — returned error status 0x%08x\n", status);
        return 1;
    } else {
        /* output_written = true: this shouldn't happen (would need copy to work
         * despite capacity check), but handle it anyway */
        printf("\nRESULT: Unexpected — output was written despite overflow\n");
        return 2;
    }
}
