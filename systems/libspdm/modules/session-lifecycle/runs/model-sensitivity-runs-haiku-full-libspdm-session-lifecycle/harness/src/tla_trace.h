#ifndef TLA_TRACE_H
#define TLA_TRACE_H

#include <stdint.h>
#include <stdio.h>
#include <stdbool.h>

typedef struct {
    const char *event;
    const char *sender;
    uint32_t session_id;
    const char *session_state;
    const char *prev_key_update_operation;
    bool requester_key_created;
    bool responder_key_created;
    bool requester_key_active;
    bool responder_key_active;
    bool heartbeat_enabled;
    bool session_freed_by_requester;
    bool session_freed_by_responder;
    const char *msg_type;
    const char *msg_operation;
} tla_trace_event_t;

void tla_trace_init(const char *trace_file);
void tla_trace_close(void);
void tla_trace_emit(const tla_trace_event_t *event);

#endif
