#ifndef TLA_TRACE_H
#define TLA_TRACE_H

#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <time.h>
#include <pthread.h>

/* Initialize trace system with output file */
void tla_trace_init(const char *trace_file);

/* Close trace file */
void tla_trace_close(void);

/* Emit a trace event */
void tla_trace_emit(
    const char *event_name,
    const char *role,
    uint8_t spdm_version,
    bool session_established,
    uint32_t session_id,
    bool has_sig_cap,
    const char *request_format_version,
    const char *response_format_version,
    const char *req_message_type,
    const char *resp_message_type,
    const char *message_m_state,
    uint32_t transcript_appended_count,
    bool computed_signature,
    bool opaque_data_enabled,
    bool opaque_data_validated,
    uint64_t requester_context_sent,
    uint64_t requester_context_received,
    bool requester_context_validated,
    uint8_t slot_id_used,
    bool slot_id_validated,
    bool pubkey_available,
    const bool *cert_available,
    int cert_available_count,
    bool signature_requested
);

/* Get current timestamp in nanoseconds */
uint64_t tla_trace_now_ns(void);

#endif /* TLA_TRACE_H */
