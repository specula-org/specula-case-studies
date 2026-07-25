#ifndef TLA_TRACE_H
#define TLA_TRACE_H

#include <stdio.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    const char *event;
    const char *node_id;
    int64_t timestamp;
    const char *state_json;
    const char *msg_json;
} tla_trace_event_t;

void tla_trace_init(const char *trace_file);
void tla_trace_emit(const tla_trace_event_t *event);
void tla_trace_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif
