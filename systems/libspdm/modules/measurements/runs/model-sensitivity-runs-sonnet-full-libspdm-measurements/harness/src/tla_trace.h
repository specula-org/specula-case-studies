/**
 * tla_trace.h — TLA+ trace emission for libspdm GET_MEASUREMENTS instrumentation.
 *
 * Each instrumented source file #includes this header.
 * tla_trace.c (compiled into the test binary) implements the functions.
 */

#ifndef TLA_TRACE_H
#define TLA_TRACE_H

#include <stddef.h>
#include <stdio.h>

/* Initialize: open trace NDJSON file at `path`. Resets all counters. */
void tla_trace_init(const char *path);

/* Emit one NDJSON event line:
 *   {"tag":"trace","ts":"<ns>","event":"<event>","data":<data_json>,"post":<post_json>}
 * event, data_json, post_json must be valid JSON strings/objects. */
void tla_trace_emit(const char *event, const char *data_json, const char *post_json);

/* Finalize: flush and close the trace file. */
void tla_trace_fini(void);

/* Pair counter for message_m tracking.
 * Incremented at each responder_append_request (new {req, resp} pair started).
 * Reset to 0 at tla_trace_init. */
void tla_trace_incr_pairs(void);
void tla_trace_reset_pairs(void);
int  tla_trace_get_pairs(void);

#endif /* TLA_TRACE_H */
