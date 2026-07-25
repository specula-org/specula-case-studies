#include "tla_trace.h"
#include <time.h>
#include <pthread.h>
#include <string.h>

static FILE *trace_file = NULL;
static pthread_mutex_t trace_mutex = PTHREAD_MUTEX_INITIALIZER;

static int64_t get_current_timestamp_ns(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0) {
        return 0;
    }
    return (int64_t)ts.tv_sec * 1000000000LL + (int64_t)ts.tv_nsec;
}

void tla_trace_init(const char *trace_file_path) {
    pthread_mutex_lock(&trace_mutex);
    if (trace_file != NULL) {
        fclose(trace_file);
    }
    trace_file = fopen(trace_file_path, "w");
    if (trace_file == NULL) {
        fprintf(stderr, "Failed to open trace file: %s\n", trace_file_path);
    }
    pthread_mutex_unlock(&trace_mutex);
}

void tla_trace_emit(const tla_trace_event_t *event) {
    if (event == NULL || trace_file == NULL) {
        return;
    }

    pthread_mutex_lock(&trace_mutex);

    int64_t ts = event->timestamp > 0 ? event->timestamp : get_current_timestamp_ns();

    fprintf(trace_file, "{\"tag\":\"trace\",\"ts\":%lld,\"event\":{\"name\":\"%s\",\"nid\":\"%s\",\"state\":%s",
            (long long)ts, event->event, event->node_id,
            event->state_json ? event->state_json : "{}");

    if (event->msg_json != NULL && strlen(event->msg_json) > 0) {
        fprintf(trace_file, ",\"msg\":%s", event->msg_json);
    }

    fprintf(trace_file, "}}\n");
    fflush(trace_file);

    pthread_mutex_unlock(&trace_mutex);
}

void tla_trace_shutdown(void) {
    pthread_mutex_lock(&trace_mutex);
    if (trace_file != NULL) {
        fclose(trace_file);
        trace_file = NULL;
    }
    pthread_mutex_unlock(&trace_mutex);
}
