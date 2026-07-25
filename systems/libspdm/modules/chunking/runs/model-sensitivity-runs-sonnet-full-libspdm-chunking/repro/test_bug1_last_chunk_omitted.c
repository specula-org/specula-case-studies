/**
 * Reproduction test — Bug 1: TransferTerminationConditionIncompleteness
 *
 * Root cause: libspdm_req_handle_error_response.c:500-502.
 * The CHUNK_GET receive loop exits on ANY of three conditions:
 *   1. status failure
 *   2. byte count satisfied  (large_response_size_so_far >= large_response_size)
 *   3. LAST_CHUNK attribute set in the received response header
 *
 * Conditions 2 and 3 are OR-ed: the loop exits if ALL bytes are received even
 * when the responder never sets LAST_CHUNK.  After the loop, there is no check
 * that LAST_CHUNK was set — the function returns SUCCESS regardless.
 *
 * A non-compliant (or buggy) responder can thus complete a CHUNK_GET exchange
 * without ever setting LAST_CHUNK; the requester accepts it as a success.
 *
 * The TLA+ spec could not trigger this because it models a compliant responder
 * that always sets is_last=TRUE on the final chunk.  0 violations were found.
 *
 * This test extracts the loop-exit logic and demonstrates the condition directly.
 * Escalation Level 0 — pure logic extraction (no SPDM stack needed).
 */

#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stdlib.h>

/* Simulated chunk receive loop, extracted from
 * libspdm_handle_error_large_response (lines 457-534). */
static bool simulate_chunk_get_loop(
    size_t large_response_size,  /* responder-declared total size */
    bool   last_chunk_set,       /* whether responder sets LAST_CHUNK on final chunk */
    bool  *last_chunk_received_out)
{
    size_t chunk_size = 4;       /* small chunks to exercise multiple iterations */
    size_t large_response_size_so_far = 0;
    bool   last_chunk_received = false;
    bool   status_ok = true;

    /* Mirror of the actual do…while loop condition:
     *   do { ... } while (status_ok
     *                     && large_response_size_so_far < large_response_size
     *                     && !(param1 & LAST_CHUNK));
     */
    do {
        /* Each iteration: receive one chunk of `chunk_size` bytes. */
        size_t remaining = large_response_size - large_response_size_so_far;
        size_t this_chunk = (remaining < chunk_size) ? remaining : chunk_size;
        large_response_size_so_far += this_chunk;

        /* Determine if responder set LAST_CHUNK on this response.
         * Conformant responders set it only on the final chunk.
         * The 'last_chunk_set' parameter controls what happens on the last chunk. */
        bool is_last = (large_response_size_so_far == large_response_size) && last_chunk_set;
        last_chunk_received |= is_last;

        /* Mimic: while condition uses spdm_response->header.param1 from the message */
        bool while_last_chunk = is_last; /* param1 & LAST_CHUNK for this response */

        if (!status_ok ||
            large_response_size_so_far >= large_response_size ||
            while_last_chunk) {
            break;
        }

    } while (true);

    *last_chunk_received_out = last_chunk_received;
    /* Mirrors: after loop, function returns SUCCESS if status_ok */
    return status_ok;
}

int main(void)
{
    bool last_chunk_received;
    bool status_success;
    const size_t LARGE_SIZE = 16;

    printf("Bug 1 (TransferTerminationConditionIncompleteness)\n");
    printf("  large_response_size = %zu bytes\n\n", LARGE_SIZE);

    /* --- Scenario A: conformant responder — sets LAST_CHUNK on final chunk --- */
    last_chunk_received = false;
    status_success = simulate_chunk_get_loop(LARGE_SIZE, true, &last_chunk_received);
    printf("Scenario A (compliant responder, LAST_CHUNK=TRUE on final):\n");
    printf("  return status=SUCCESS: %d\n", status_success);
    printf("  last_chunk_received:   %d (expected: 1)\n\n", last_chunk_received);

    /* --- Scenario B: non-conformant responder — never sets LAST_CHUNK --- */
    last_chunk_received = false;
    status_success = simulate_chunk_get_loop(LARGE_SIZE, false, &last_chunk_received);
    printf("Scenario B (non-conformant responder, LAST_CHUNK never set):\n");
    printf("  return status=SUCCESS: %d\n", status_success);
    printf("  last_chunk_received:   %d (expected: 1, but is: %d)\n\n",
           1, last_chunk_received);

    printf("=== Bug 1 (TransferTerminationConditionIncompleteness) ===\n");
    printf("Loop exit condition (from libspdm_req_handle_error_response.c:500-502):\n");
    printf("  } while (status_ok\n");
    printf("           && large_response_size_so_far < large_response_size  <- OR condition\n");
    printf("           && !(param1 & LAST_CHUNK));                           <- OR condition\n\n");

    if (status_success && !last_chunk_received) {
        printf("RESULT: BUG DEMONSTRATED\n");
        printf("  SUCCESS returned but last_chunk_received=FALSE.\n");
        printf("  Requester accepts response from non-conformant responder\n");
        printf("  that never sets LAST_CHUNK on the final chunk.\n");
        printf("  After loop exit, no check enforces that LAST_CHUNK was seen.\n");
        printf("  Fix: after loop, check if LAST_CHUNK was received; if not, return error.\n");
        return 0;
    } else if (last_chunk_received) {
        printf("RESULT: Bug not triggered (conformant responder simulated)\n");
        return 1;
    } else {
        printf("RESULT: Unexpected state\n");
        return 2;
    }
}
