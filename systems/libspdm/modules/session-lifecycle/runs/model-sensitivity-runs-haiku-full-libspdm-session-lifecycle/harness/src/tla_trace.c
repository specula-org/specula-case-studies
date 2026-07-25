#include "tla_trace.h"
#include <time.h>
#include <pthread.h>

static FILE *g_trace_file = NULL;
static pthread_mutex_t g_trace_lock = PTHREAD_MUTEX_INITIALIZER;

void tla_trace_init(const char *trace_file)
{
    pthread_mutex_lock(&g_trace_lock);
    if (g_trace_file == NULL) {
        g_trace_file = fopen(trace_file, "w");
        if (g_trace_file == NULL) {
            perror("Failed to open trace file");
        }
    }
    pthread_mutex_unlock(&g_trace_lock);
}

void tla_trace_close(void)
{
    pthread_mutex_lock(&g_trace_lock);
    if (g_trace_file != NULL) {
        fclose(g_trace_file);
        g_trace_file = NULL;
    }
    pthread_mutex_unlock(&g_trace_lock);
}

static uint64_t get_timestamp_nanos(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + ts.tv_nsec;
}

void tla_trace_emit(const tla_trace_event_t *event)
{
    uint64_t ts = get_timestamp_nanos();

    pthread_mutex_lock(&g_trace_lock);
    if (g_trace_file == NULL) {
        pthread_mutex_unlock(&g_trace_lock);
        return;
    }

    fprintf(g_trace_file, "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"%s\",\"sender\":\"%s\",\"session_id\":%u",
            (unsigned long long)ts, event->event, event->sender, event->session_id);

    fprintf(g_trace_file, ",\"state\":{");
    fprintf(g_trace_file, "\"session_state\":\"%s\",",
            event->session_state ? event->session_state : "unknown");
    fprintf(g_trace_file, "\"prev_key_update_operation\":\"%s\",",
            event->prev_key_update_operation ? event->prev_key_update_operation : "none");
    fprintf(g_trace_file, "\"requester_key_created\":%s,",
            event->requester_key_created ? "true" : "false");
    fprintf(g_trace_file, "\"responder_key_created\":%s,",
            event->responder_key_created ? "true" : "false");
    fprintf(g_trace_file, "\"requester_key_active\":%s,",
            event->requester_key_active ? "true" : "false");
    fprintf(g_trace_file, "\"responder_key_active\":%s,",
            event->responder_key_active ? "true" : "false");
    fprintf(g_trace_file, "\"heartbeat_enabled\":%s,",
            event->heartbeat_enabled ? "true" : "false");
    fprintf(g_trace_file, "\"session_freed_by_requester\":%s,",
            event->session_freed_by_requester ? "true" : "false");
    fprintf(g_trace_file, "\"session_freed_by_responder\":%s",
            event->session_freed_by_responder ? "true" : "false");
    fprintf(g_trace_file, "}");

    if (event->msg_type != NULL) {
        fprintf(g_trace_file, ",\"message\":{\"type\":\"%s\"", event->msg_type);
        if (event->msg_operation != NULL) {
            fprintf(g_trace_file, ",\"operation\":\"%s\"", event->msg_operation);
        }
        fprintf(g_trace_file, "}");
    }

    fprintf(g_trace_file, "}\n");
    fflush(g_trace_file);
    pthread_mutex_unlock(&g_trace_lock);
}
