#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include "tla_trace.h"

int main(int argc, char *argv[]) {
    const char *trace_file = "trace.ndjson";

    if (argc > 1) {
        trace_file = argv[1];
    }

    tla_trace_init(trace_file);

    uint32_t session_id = 1;

    TLA_EMIT_EVENT_INIT(session_id);

    uint16_t event_types[] = {1, 2, 3};
    TLA_EMIT_EVENT_SUBSCRIBE_EVENT_TYPES(session_id, event_types, 3);

    TLA_EMIT_EVENT_SUBSCRIBE_EVENT_TYPES_ACK(session_id);

    TLA_EMIT_EVENT_SEND_EVENT_ACK(session_id, 1, 100, 2);

    TLA_EMIT_EVENT_SEND_EVENT_ACK(session_id, 0, 150, 3);

    TLA_EMIT_EVENT_HANDLE_EVENT_ACK(session_id, 3);

    tla_trace_close();

    printf("Test completed, trace written to %s\n", trace_file);

    return 0;
}
