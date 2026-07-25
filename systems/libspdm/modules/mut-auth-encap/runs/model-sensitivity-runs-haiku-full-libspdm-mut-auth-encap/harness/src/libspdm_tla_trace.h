/**
 * SPDM TLA+ Trace Emission Library (Category A: Standard Pattern)
 *
 * Thread-safe NDJSON trace writer for libspdm mutual authentication protocol.
 * Uses mutex-protected global FILE* for trace output.
 */

#ifndef LIBSPDM_TLA_TRACE_H
#define LIBSPDM_TLA_TRACE_H

#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <pthread.h>
#include <time.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Initialize trace emission.
 *
 * @param trace_file: Path to output NDJSON file
 * @return 0 on success, -1 on failure
 */
int libspdm_tla_trace_init(const char *trace_file);

/**
 * Shutdown trace emission and flush/close file.
 */
void libspdm_tla_trace_shutdown(void);

/**
 * Emit a single trace event (NDJSON format).
 *
 * All fields are captured into a single JSON object with "tag": "trace".
 *
 * @param event_name: Action name (e.g., "responder_get_encap_request_challenge")
 * @param node: Node identifier ("requester" or "responder")
 * @param state_json: Pre-formatted JSON string for state fields (without outer braces)
 *                    Example: "\"protocol_version\": 13, \"responder_state\": \"challenge_sent\""
 * @param msg_json: Pre-formatted JSON string for message fields (without outer braces)
 *                  Pass NULL if no message fields
 * @return 0 on success, -1 on failure
 */
int libspdm_tla_trace_emit(
    const char *event_name,
    const char *node,
    const char *state_json,
    const char *msg_json
);

/**
 * Helper to format state fields as JSON (without outer braces).
 * Caller must free the returned string.
 */
char *libspdm_tla_format_state(
    uint32_t protocol_version,
    const char *requester_state,
    const char *responder_state,
    bool signature_verified,
    uint32_t response_buffer_size,
    uint32_t opaque_data_size,
    const char *buffer_reset_status
);

/**
 * Helper to format message fields as JSON (without outer braces).
 * Caller must free the returned string.
 */
char *libspdm_tla_format_msg(
    uint32_t version,
    uint32_t opaque_data_size,
    uint32_t response_buffer_size,
    bool transcript_complete,
    const char *opaque_length_str
);

#ifdef __cplusplus
}
#endif

#endif /* LIBSPDM_TLA_TRACE_H */
