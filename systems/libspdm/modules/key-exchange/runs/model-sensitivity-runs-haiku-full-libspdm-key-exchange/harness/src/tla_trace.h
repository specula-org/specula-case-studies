/**
 * TLA+ Trace Emission Library for SPDM KEY_EXCHANGE/FINISH Protocol
 *
 * This module provides NDJSON trace event emission for trace validation.
 * Thread-safe via mutex serialization (Category A: message-passing system).
 */

#ifndef TLA_TRACE_H
#define TLA_TRACE_H

#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <time.h>
#include <pthread.h>

typedef struct {
    FILE *trace_file;
    pthread_mutex_t lock;
    int event_count;
    char node_id[32];  /* "requester" or "responder" */
    uint64_t start_time_ns;
} tla_trace_context_t;

/**
 * Initialize trace emission context.
 * Must be called once before any emit calls.
 */
bool tla_trace_init(tla_trace_context_t *ctx, const char *trace_file_path, const char *node_id);

/**
 * Emit a trace event as NDJSON.
 *
 * Includes: event name, node ID, session_id, real timestamp,
 * state snapshot fields, and message-specific fields.
 */
bool tla_trace_emit_event(
    tla_trace_context_t *ctx,
    const char *event_name,
    uint32_t session_id,
    const char *state_json,   /* Pre-formatted JSON object for state_snapshot */
    const char *message_json  /* Pre-formatted JSON object for message_fields, NULL if no message */
);

/**
 * Emit error event.
 */
bool tla_trace_emit_error(
    tla_trace_context_t *ctx,
    const char *event_name,
    uint32_t session_id,
    const char *error_reason,
    bool session_id_freed
);

/**
 * Shutdown trace context (flush and close).
 */
void tla_trace_shutdown(tla_trace_context_t *ctx);

/**
 * Get real timestamp in nanoseconds since epoch.
 */
uint64_t tla_trace_get_timestamp_ns(void);

#endif /* TLA_TRACE_H */
