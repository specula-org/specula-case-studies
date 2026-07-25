#ifndef TLA_TRACE_H
#define TLA_TRACE_H

#include <stdint.h>
#include <stdbool.h>
#include <time.h>

typedef struct {
    const char *pc;
    const char *session_state;
    uint16_t *allocated_ids;
    size_t num_allocated_ids;
    bool version_negotiated;
    bool opaque_length_checked;
    bool context_length_checked;
} trace_state_snapshot_t;

typedef struct {
    uint16_t req_session_id;
    uint16_t rsp_session_id;
    uint16_t opaque_length;
    uint16_t context_length;
    uint16_t psk_hint_length;
    bool opaque_data;
    bool context_data;
    bool version_negotiated;
    bool use_default_opaque;
    bool opaque_data_valid;
    uint32_t session_id;
} trace_message_fields_t;

void tla_trace_init(const char *trace_file);
void tla_trace_shutdown(void);

void tla_trace_emit(
    const char *event_type,
    const char *node_id,
    const trace_state_snapshot_t *state,
    const trace_message_fields_t *msg_fields
);

#endif // TLA_TRACE_H
