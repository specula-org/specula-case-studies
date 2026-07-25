/**
 * SPDM TLA+ Trace Emission Library (Category A: Standard Pattern)
 */

#include "libspdm_tla_trace.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <time.h>
#include <pthread.h>

static FILE *g_trace_file = NULL;
static pthread_mutex_t g_trace_mutex = PTHREAD_MUTEX_INITIALIZER;

/**
 * Get current timestamp in milliseconds as a string (ISO 8601 format).
 */
static char *get_timestamp(void) {
    static char ts_buf[64];
    time_t now = time(NULL);
    struct tm *tm_info = gmtime(&now);
    strftime(ts_buf, sizeof(ts_buf), "%Y-%m-%dT%H:%M:%SZ", tm_info);
    return ts_buf;
}

int libspdm_tla_trace_init(const char *trace_file) {
    pthread_mutex_lock(&g_trace_mutex);

    if (g_trace_file != NULL) {
        fclose(g_trace_file);
    }

    g_trace_file = fopen(trace_file, "w");
    if (g_trace_file == NULL) {
        pthread_mutex_unlock(&g_trace_mutex);
        return -1;
    }

    pthread_mutex_unlock(&g_trace_mutex);
    return 0;
}

void libspdm_tla_trace_shutdown(void) {
    pthread_mutex_lock(&g_trace_mutex);

    if (g_trace_file != NULL) {
        fflush(g_trace_file);
        fclose(g_trace_file);
        g_trace_file = NULL;
    }

    pthread_mutex_unlock(&g_trace_mutex);
}

int libspdm_tla_trace_emit(
    const char *event_name,
    const char *node,
    const char *state_json,
    const char *msg_json
) {
    char *timestamp = get_timestamp();
    int result = 0;

    pthread_mutex_lock(&g_trace_mutex);

    if (g_trace_file == NULL) {
        pthread_mutex_unlock(&g_trace_mutex);
        return -1;
    }

    /* Write NDJSON line with tag="trace" (mandatory for Trace.tla) */
    fprintf(g_trace_file, "{\"tag\": \"trace\", \"ts\": \"%s\", \"event\": \"%s\", \"node\": \"%s\", \"state\": {%s}",
            timestamp, event_name, node, state_json);

    if (msg_json != NULL) {
        fprintf(g_trace_file, ", \"message\": {%s}", msg_json);
    }

    fprintf(g_trace_file, "}\n");

    if (fflush(g_trace_file) != 0) {
        result = -1;
    }

    pthread_mutex_unlock(&g_trace_mutex);
    return result;
}

char *libspdm_tla_format_state(
    uint32_t protocol_version,
    const char *requester_state,
    const char *responder_state,
    bool signature_verified,
    uint32_t response_buffer_size,
    uint32_t opaque_data_size,
    const char *buffer_reset_status
) {
    char *buf = malloc(1024);
    if (buf == NULL) return NULL;

    snprintf(buf, 1024,
             "\"protocol_version\": %u, "
             "\"requester_state\": \"%s\", "
             "\"responder_state\": \"%s\", "
             "\"signature_verified\": %s, "
             "\"response_buffer_size\": %u, "
             "\"opaque_data_size\": %u, "
             "\"buffer_reset_status\": \"%s\"",
             protocol_version,
             requester_state ? requester_state : "uninitialized",
             responder_state ? responder_state : "uninitialized",
             signature_verified ? "true" : "false",
             response_buffer_size,
             opaque_data_size,
             buffer_reset_status ? buffer_reset_status : "pending");

    return buf;
}

char *libspdm_tla_format_msg(
    uint32_t version,
    uint32_t opaque_data_size,
    uint32_t response_buffer_size,
    bool transcript_complete,
    const char *opaque_length_str
) {
    char *buf = malloc(512);
    if (buf == NULL) return NULL;

    snprintf(buf, 512,
             "\"version\": %u, "
             "\"opaque_data_size\": %u, "
             "\"response_buffer_size\": %u, "
             "\"transcript_complete\": %s%s%s",
             version,
             opaque_data_size,
             response_buffer_size,
             transcript_complete ? "true" : "false",
             opaque_length_str ? ", " : "",
             opaque_length_str ? opaque_length_str : "");

    return buf;
}
