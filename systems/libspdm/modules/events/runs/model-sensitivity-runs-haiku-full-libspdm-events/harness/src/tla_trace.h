#ifndef TLA_TRACE_H
#define TLA_TRACE_H

#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <pthread.h>
#include <time.h>
#include <string.h>

typedef struct {
    FILE *trace_file;
    pthread_mutex_t mutex;
    bool initialized;
} tla_trace_ctx_t;

static tla_trace_ctx_t g_trace_ctx = {0};

static inline uint64_t tla_get_timestamp_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static inline void tla_trace_init(const char *trace_file_path) {
    pthread_mutex_init(&g_trace_ctx.mutex, NULL);
    g_trace_ctx.trace_file = fopen(trace_file_path, "w");
    if (g_trace_ctx.trace_file) {
        g_trace_ctx.initialized = true;
    }
}

static inline void tla_trace_close(void) {
    pthread_mutex_lock(&g_trace_ctx.mutex);
    if (g_trace_ctx.trace_file) {
        fflush(g_trace_ctx.trace_file);
        fclose(g_trace_ctx.trace_file);
        g_trace_ctx.trace_file = NULL;
    }
    pthread_mutex_unlock(&g_trace_ctx.mutex);
    pthread_mutex_destroy(&g_trace_ctx.mutex);
}

static inline void tla_emit_raw_json(const char *json_line) {
    if (!g_trace_ctx.initialized) {
        return;
    }
    pthread_mutex_lock(&g_trace_ctx.mutex);
    if (g_trace_ctx.trace_file) {
        fprintf(g_trace_ctx.trace_file, "%s\n", json_line);
        fflush(g_trace_ctx.trace_file);
    }
    pthread_mutex_unlock(&g_trace_ctx.mutex);
}

#define TLA_EMIT_EVENT_INIT(sid) \
    do { \
        uint64_t ts = tla_get_timestamp_ns(); \
        char json_buf[512]; \
        snprintf(json_buf, sizeof(json_buf), \
            "{\"tag\":\"trace\",\"event\":\"INIT_SESSION\",\"timestamp\":%llu,\"sid\":%u,\"state\":{\"session_state\":\"ESTABLISHED\"},\"body\":{}}", \
            (unsigned long long)ts, (unsigned int)(sid)); \
        tla_emit_raw_json(json_buf); \
    } while(0)

#define TLA_EMIT_EVENT_SUBSCRIBE_EVENT_TYPES(sid, types_list, types_count) \
    do { \
        uint64_t ts = tla_get_timestamp_ns(); \
        char json_buf[1024]; \
        char types_str[256] = ""; \
        for (unsigned int i = 0; i < (types_count) && i < 10; i++) { \
            char type_part[32]; \
            snprintf(type_part, sizeof(type_part), "%s%u", i > 0 ? "," : "", (types_list)[i]); \
            strncat(types_str, type_part, sizeof(types_str) - strlen(types_str) - 1); \
        } \
        snprintf(json_buf, sizeof(json_buf), \
            "{\"tag\":\"trace\",\"event\":\"SUBSCRIBE_EVENT_TYPES\",\"timestamp\":%llu,\"sid\":%u,\"state\":{\"session_state\":\"ESTABLISHED\"},\"body\":{\"event_types\":[%s]}}", \
            (unsigned long long)ts, (unsigned int)(sid), types_str); \
        tla_emit_raw_json(json_buf); \
    } while(0)

#define TLA_EMIT_EVENT_SUBSCRIBE_EVENT_TYPES_ACK(sid) \
    do { \
        uint64_t ts = tla_get_timestamp_ns(); \
        char json_buf[512]; \
        snprintf(json_buf, sizeof(json_buf), \
            "{\"tag\":\"trace\",\"event\":\"SUBSCRIBE_EVENT_TYPES_ACK\",\"timestamp\":%llu,\"sid\":%u,\"state\":{\"session_state\":\"ESTABLISHED\"},\"body\":{}}", \
            (unsigned long long)ts, (unsigned int)(sid)); \
        tla_emit_raw_json(json_buf); \
    } while(0)

#define TLA_EMIT_EVENT_SEND_EVENT_ACK(sid, is_seq, msg_size, event_count) \
    do { \
        uint64_t ts = tla_get_timestamp_ns(); \
        char json_buf[512]; \
        snprintf(json_buf, sizeof(json_buf), \
            "{\"tag\":\"trace\",\"event\":\"SEND_EVENT_ACK\",\"timestamp\":%llu,\"sid\":%u,\"state\":{\"session_state\":\"ESTABLISHED\",\"events_sequential\":%s,\"msg_size_accum\":%u,\"event_validated_count\":%u},\"body\":{\"is_sequential\":%s}}", \
            (unsigned long long)ts, (unsigned int)(sid), (is_seq) ? "true" : "false", (msg_size), (event_count), (is_seq) ? "true" : "false"); \
        tla_emit_raw_json(json_buf); \
    } while(0)

#define TLA_EMIT_EVENT_HANDLE_EVENT_ACK(sid, event_count) \
    do { \
        uint64_t ts = tla_get_timestamp_ns(); \
        char json_buf[512]; \
        snprintf(json_buf, sizeof(json_buf), \
            "{\"tag\":\"trace\",\"event\":\"HANDLE_EVENT_ACK\",\"timestamp\":%llu,\"sid\":%u,\"state\":{\"session_state\":\"ESTABLISHED\"},\"body\":{\"event_count\":%u}}", \
            (unsigned long long)ts, (unsigned int)(sid), (event_count)); \
        tla_emit_raw_json(json_buf); \
    } while(0)

#endif /* TLA_TRACE_H */
