#include "tla_trace.h"
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <time.h>
#include <string.h>

static FILE *g_trace_file = NULL;
static pthread_mutex_t g_trace_mutex = PTHREAD_MUTEX_INITIALIZER;

void tla_trace_init(const char *trace_file) {
    pthread_mutex_lock(&g_trace_mutex);
    g_trace_file = fopen(trace_file, "w");
    pthread_mutex_unlock(&g_trace_mutex);
}

void tla_trace_shutdown(void) {
    pthread_mutex_lock(&g_trace_mutex);
    if (g_trace_file) {
        fflush(g_trace_file);
        fclose(g_trace_file);
        g_trace_file = NULL;
    }
    pthread_mutex_unlock(&g_trace_mutex);
}

static uint64_t get_timestamp_nanos(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

void tla_trace_emit(
    const char *event_type,
    const char *node_id,
    const trace_state_snapshot_t *state,
    const trace_message_fields_t *msg_fields
) {
    if (!g_trace_file) {
        return;
    }

    uint64_t ts = get_timestamp_nanos();

    pthread_mutex_lock(&g_trace_mutex);

    fprintf(g_trace_file, "{\"tag\":\"trace\",\"ts\":%llu,\"event\":{\"name\":\"%s\",\"nid\":\"%s\"",
            (unsigned long long)ts, event_type, node_id);

    // Emit state snapshot
    if (state) {
        fprintf(g_trace_file, ",\"state\":{");
        bool first = true;

        if (state->pc) {
            fprintf(g_trace_file, "\"pc\":\"%s\"", state->pc);
            first = false;
        }

        if (state->session_state) {
            if (!first) fprintf(g_trace_file, ",");
            fprintf(g_trace_file, "\"session_state\":\"%s\"", state->session_state);
            first = false;
        }

        if (state->num_allocated_ids > 0) {
            if (!first) fprintf(g_trace_file, ",");
            fprintf(g_trace_file, "\"allocated_ids\":[");
            for (size_t i = 0; i < state->num_allocated_ids; i++) {
                if (i > 0) fprintf(g_trace_file, ",");
                fprintf(g_trace_file, "%u", state->allocated_ids[i]);
            }
            fprintf(g_trace_file, "]");
            first = false;
        }

        if (state->version_negotiated) {
            if (!first) fprintf(g_trace_file, ",");
            fprintf(g_trace_file, "\"version_negotiated\":true");
            first = false;
        }

        if (state->opaque_length_checked) {
            if (!first) fprintf(g_trace_file, ",");
            fprintf(g_trace_file, "\"opaque_length_checked\":true");
            first = false;
        }

        if (state->context_length_checked) {
            if (!first) fprintf(g_trace_file, ",");
            fprintf(g_trace_file, "\"context_length_checked\":true");
            first = false;
        }

        fprintf(g_trace_file, "}");
    }

    // Emit message fields
    if (msg_fields) {
        fprintf(g_trace_file, ",\"msg\":{");
        bool first = true;

        if (msg_fields->req_session_id != 0 || msg_fields->rsp_session_id != 0) {
            if (msg_fields->req_session_id != 0) {
                fprintf(g_trace_file, "\"req_session_id\":%u", msg_fields->req_session_id);
                first = false;
            }
            if (msg_fields->rsp_session_id != 0) {
                if (!first) fprintf(g_trace_file, ",");
                fprintf(g_trace_file, "\"rsp_session_id\":%u", msg_fields->rsp_session_id);
                first = false;
            }
        }

        if (msg_fields->opaque_length != 0) {
            if (!first) fprintf(g_trace_file, ",");
            fprintf(g_trace_file, "\"opaque_length\":%u", msg_fields->opaque_length);
            first = false;
        }

        if (msg_fields->context_length != 0) {
            if (!first) fprintf(g_trace_file, ",");
            fprintf(g_trace_file, "\"context_length\":%u", msg_fields->context_length);
            first = false;
        }

        if (msg_fields->psk_hint_length != 0) {
            if (!first) fprintf(g_trace_file, ",");
            fprintf(g_trace_file, "\"psk_hint_length\":%u", msg_fields->psk_hint_length);
            first = false;
        }

        if (msg_fields->opaque_data) {
            if (!first) fprintf(g_trace_file, ",");
            fprintf(g_trace_file, "\"opaque_data\":true");
            first = false;
        }

        if (msg_fields->context_data) {
            if (!first) fprintf(g_trace_file, ",");
            fprintf(g_trace_file, "\"context_data\":true");
            first = false;
        }

        if (msg_fields->version_negotiated) {
            if (!first) fprintf(g_trace_file, ",");
            fprintf(g_trace_file, "\"version_negotiated\":true");
            first = false;
        }

        if (msg_fields->use_default_opaque) {
            if (!first) fprintf(g_trace_file, ",");
            fprintf(g_trace_file, "\"use_default_opaque\":true");
            first = false;
        }

        if (msg_fields->opaque_data_valid) {
            if (!first) fprintf(g_trace_file, ",");
            fprintf(g_trace_file, "\"opaque_data_valid\":true");
            first = false;
        }

        if (msg_fields->session_id != 0) {
            if (!first) fprintf(g_trace_file, ",");
            fprintf(g_trace_file, "\"session_id\":%u", msg_fields->session_id);
            first = false;
        }

        fprintf(g_trace_file, "}");
    }

    fprintf(g_trace_file, "}}\n");
    fflush(g_trace_file);

    pthread_mutex_unlock(&g_trace_mutex);
}
