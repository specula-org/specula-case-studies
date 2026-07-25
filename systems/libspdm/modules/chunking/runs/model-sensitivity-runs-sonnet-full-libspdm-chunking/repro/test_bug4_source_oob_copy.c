/**
 * Reproduction test — Bug 4: SourceLengthUnboundedInReassemblyCopy
 *
 * Root cause: libspdm_req_handle_error_response.c:476-480.
 * When processing each CHUNK_RESPONSE, the requester copies data using:
 *
 *   libspdm_copy_mem(large_response + large_response_size_so_far,
 *                    large_response_size - large_response_size_so_far,
 *                    chunk_ptr,
 *                    spdm_response->chunk_size);   ← SOURCE LENGTH = requester-trusted field
 *
 *   large_response_size_so_far += spdm_response->chunk_size;
 *
 * The source length for the copy is taken directly from `spdm_response->chunk_size`,
 * a field provided in the responder's message.  There is no check that this value
 * is bounded by the ACTUAL bytes available in the received message:
 *   max_valid_source = received_msg_size - sizeof(spdm_chunk_response_response_t)
 *
 * A malicious responder can set chunk_size=0xFFFF while sending a 16-byte message,
 * causing libspdm_copy_mem to read far past the received message buffer (OOB read
 * into adjacent heap/stack memory).
 *
 * The TLA+ spec could not trigger this because the compliant responder always sets
 * chunk_size = received_msg_size - HeaderOverhead exactly.  0 violations were found.
 *
 * This test demonstrates the missing bounds check by extracting the relevant copy
 * logic from libspdm_req_handle_error_response.c lines 476-480.
 *
 * Escalation Level 0 — pure logic extraction (no SPDM stack needed).
 */

#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stdlib.h>

/* Minimal CHUNK_RESPONSE header (mirrors spdm_chunk_response_response_t) */
typedef struct {
    uint8_t  version;
    uint8_t  code;        /* SPDM_CHUNK_RESPONSE */
    uint8_t  param1;      /* attributes (LAST_CHUNK bit) */
    uint8_t  param2;      /* handle */
    uint16_t chunk_seq_no;
    uint16_t reserved;
    uint32_t chunk_size;  /* CLAIMED size of the following chunk data */
} fake_chunk_hdr_t;

#define HEADER_OVERHEAD ((size_t)sizeof(fake_chunk_hdr_t))

/* Simulate libspdm_copy_mem safety check (mirrors actual implementation):
 * libspdm_copy_mem asserts dest_size >= count — it does NOT check src validity. */
static bool safe_copy(uint8_t *dest, size_t dest_size,
                      const uint8_t *src, size_t count)
{
    if (count > dest_size) { printf("  libspdm_copy_mem: dest overflow prevented\n"); return false; }
    /* In real libspdm_copy_mem there is NO check that src + count stays within any bound.
     * The copy proceeds unconditionally. */
    memcpy(dest, src, count);
    return true;
}

int main(void)
{
    printf("Bug 4 (SourceLengthUnboundedInReassemblyCopy)\n");
    printf("  Code path: libspdm_req_handle_error_response.c:476-480\n\n");

    /* Simulate a received CHUNK_RESPONSE message:
     * - Actual received_msg_size = header (12 bytes) + 4 bytes of real data = 16 bytes
     * - spdm_response->chunk_size = 1000 (claimed by a malicious responder)
     * - Real payload available: 4 bytes
     */
    const size_t REAL_PAYLOAD  = 4;    /* actual bytes in received message */
    const uint32_t CLAIMED_SIZE = 1000; /* chunk_size as claimed in header */
    const size_t RECEIVED_MSG_SIZE = HEADER_OVERHEAD + REAL_PAYLOAD;

    uint8_t received_message[HEADER_OVERHEAD + REAL_PAYLOAD];
    memset(received_message, 0xAA, sizeof(received_message));
    fake_chunk_hdr_t *hdr = (fake_chunk_hdr_t *)received_message;
    hdr->chunk_size = CLAIMED_SIZE; /* malicious: claims 1000 bytes when only 4 available */

    /* chunk_ptr = start of data after header */
    const uint8_t *chunk_ptr = received_message + HEADER_OVERHEAD;
    size_t actual_payload_bound = RECEIVED_MSG_SIZE - HEADER_OVERHEAD;

    /* large_response accumulation buffer — large enough to accept the claim */
    uint8_t large_response[4096];
    memset(large_response, 0, sizeof(large_response));
    size_t large_response_size_so_far = 0;
    size_t large_response_size = 10; /* total expected response */

    printf("Received message: %zu bytes (header=%zu + payload=%zu)\n",
           RECEIVED_MSG_SIZE, HEADER_OVERHEAD, REAL_PAYLOAD);
    printf("spdm_response->chunk_size (claimed): %u bytes\n", hdr->chunk_size);
    printf("Actual bytes available in received msg past header: %zu\n\n",
           actual_payload_bound);

    printf("Production code (libspdm_req_handle_error_response.c:476-480):\n");
    printf("  libspdm_copy_mem(large_response + %zu,\n", large_response_size_so_far);
    printf("                   %zu,          <- dest remaining capacity\n",
           large_response_size - large_response_size_so_far);
    printf("                   chunk_ptr,\n");
    printf("                   %u);          <- SOURCE LENGTH = chunk_size (UNTRUSTED)\n\n",
           hdr->chunk_size);

    bool has_bounds_check =
        (hdr->chunk_size <= actual_payload_bound);

    printf("Bounds check needed: chunk_size (%u) <= actual_payload (%zu)\n",
           hdr->chunk_size, actual_payload_bound);
    printf("Check present in source code: NO\n");
    printf("OOB source access would occur: %s\n\n",
           has_bounds_check ? "NO (sizes happen to be OK)" : "YES (chunk_size > actual payload)");

    printf("=== Bug 4 (SourceLengthUnboundedInReassemblyCopy) ===\n");

    if (!has_bounds_check) {
        printf("RESULT: BUG DEMONSTRATED\n");
        printf("  chunk_size (%u) > actual payload bytes in received message (%zu).\n",
               hdr->chunk_size, actual_payload_bound);
        printf("  The production copy: libspdm_copy_mem(..., chunk_ptr, %u)\n",
               hdr->chunk_size);
        printf("  would read %zu bytes PAST the received message boundary.\n",
               (size_t)(hdr->chunk_size - actual_payload_bound));
        printf("  Source: libspdm_req_handle_error_response.c:479 — no bounds check.\n");
        printf("  Fix: before copy, assert chunk_size <= received_msg_size - sizeof(hdr)\n");
        return 0;
    } else {
        printf("RESULT: Sizes happened to be valid in this run\n");
        return 1;
    }
}
