#ifndef TLA_TRACE_H
#define TLA_TRACE_H

#include <stdint.h>
#include <stdbool.h>
#include <time.h>

/* Initialize trace module - must be called before any emit calls */
void tla_trace_init(const char *trace_file);

/* Emit trace events */
void tla_trace_chunk_send_init(
    uint32_t large_message_size,
    uint32_t large_message_capacity,
    uint32_t chunk_size,
    bool send_active,
    bool get_active,
    bool large_message_valid,
    bool seq_no_wrap_error
);

void tla_trace_chunk_send_continuation(
    uint32_t seq_no,
    uint32_t bytes_transferred,
    uint32_t chunk_size,
    uint32_t large_message_size,
    uint32_t large_message_capacity,
    bool send_active,
    bool get_active,
    bool large_message_valid,
    bool seq_no_wrap_error
);

void tla_trace_receive_interruption(
    const char *cmd_type,
    bool send_active,
    bool get_active,
    uint32_t seq_no,
    uint32_t bytes_transferred,
    uint32_t large_message_size,
    bool large_message_valid,
    bool seq_no_wrap_error
);

void tla_trace_error_during_reassembly(
    bool send_active,
    bool get_active,
    uint32_t large_message_size,
    bool large_message_valid,
    bool seq_no_wrap_error
);

void tla_trace_shutdown(void);

/* Utility: get ISO 8601 timestamp */
void tla_trace_get_timestamp(char *buf, size_t buflen);

#endif /* TLA_TRACE_H */
