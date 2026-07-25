/**
 * TLA+ Trace Emission Library Implementation
 */

#include "tla_trace.h"
#include <string.h>
#include <stdlib.h>

#ifdef __unix__
#include <sys/time.h>
#endif

static tla_trace_context_t *g_trace_ctx = NULL;

uint64_t tla_trace_get_timestamp_ns(void) {
#ifdef __unix__
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
#else
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (uint64_t)tv.tv_sec * 1000000000ULL + (uint64_t)tv.tv_usec * 1000ULL;
#endif
}

bool tla_trace_init(tla_trace_context_t *ctx, const char *trace_file_path, const char *node_id) {
    if (!ctx || !trace_file_path || !node_id) {
        return false;
    }

    ctx->trace_file = fopen(trace_file_path, "w");
    if (!ctx->trace_file) {
        return false;
    }

    if (pthread_mutex_init(&ctx->lock, NULL) != 0) {
        fclose(ctx->trace_file);
        return false;
    }

    ctx->event_count = 0;
    strncpy(ctx->node_id, node_id, sizeof(ctx->node_id) - 1);
    ctx->node_id[sizeof(ctx->node_id) - 1] = '\0';
    ctx->start_time_ns = tla_trace_get_timestamp_ns();

    g_trace_ctx = ctx;
    return true;
}

bool tla_trace_emit_event(
    tla_trace_context_t *ctx,
    const char *event_name,
    uint32_t session_id,
    const char *state_json,
    const char *message_json)
{
    if (!ctx || !ctx->trace_file || !event_name || !state_json) {
        return false;
    }

    pthread_mutex_lock(&ctx->lock);

    uint64_t ts = tla_trace_get_timestamp_ns();

    fprintf(ctx->trace_file,
        "{\"tag\":\"trace\",\"ts\":%llu,\"event\":{\"name\":\"%s\",\"nid\":\"%s\",\"session_id\":%u,\"state\":%s",
        (unsigned long long)ts,
        event_name,
        ctx->node_id,
        session_id,
        state_json);

    if (message_json) {
        fprintf(ctx->trace_file, ",\"msg\":%s", message_json);
    }

    fprintf(ctx->trace_file, "}}\n");
    fflush(ctx->trace_file);

    ctx->event_count++;

    pthread_mutex_unlock(&ctx->lock);
    return true;
}

bool tla_trace_emit_error(
    tla_trace_context_t *ctx,
    const char *event_name,
    uint32_t session_id,
    const char *error_reason,
    bool session_id_freed)
{
    if (!ctx || !ctx->trace_file || !event_name || !error_reason) {
        return false;
    }

    pthread_mutex_lock(&ctx->lock);

    uint64_t ts = tla_trace_get_timestamp_ns();

    fprintf(ctx->trace_file,
        "{\"tag\":\"trace\",\"ts\":%llu,\"event\":{\"name\":\"%s\",\"nid\":\"%s\",\"session_id\":%u,\"state\":{},\"error_reason\":\"%s\",\"session_id_freed\":%s}}\n",
        (unsigned long long)ts,
        event_name,
        ctx->node_id,
        session_id,
        error_reason,
        session_id_freed ? "true" : "false");

    fflush(ctx->trace_file);
    ctx->event_count++;

    pthread_mutex_unlock(&ctx->lock);
    return true;
}

void tla_trace_shutdown(tla_trace_context_t *ctx) {
    if (!ctx) {
        return;
    }

    pthread_mutex_lock(&ctx->lock);
    if (ctx->trace_file) {
        fflush(ctx->trace_file);
        fclose(ctx->trace_file);
        ctx->trace_file = NULL;
    }
    pthread_mutex_unlock(&ctx->lock);

    pthread_mutex_destroy(&ctx->lock);
    g_trace_ctx = NULL;
}
