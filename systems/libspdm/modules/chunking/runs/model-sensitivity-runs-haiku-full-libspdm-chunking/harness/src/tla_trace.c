#include "tla_trace.h"
#include <stdio.h>
#include <string.h>
#include <pthread.h>
#include <time.h>
#include <stdlib.h>

static FILE *trace_file = NULL;
static pthread_mutex_t trace_mutex = PTHREAD_MUTEX_INITIALIZER;
static int trace_initialized = 0;

void tla_trace_init(const char *trace_file_path)
{
    pthread_mutex_lock(&trace_mutex);
    if (trace_file_path == NULL) {
        trace_file = NULL;
        trace_initialized = 1;
        pthread_mutex_unlock(&trace_mutex);
        return;
    }

    trace_file = fopen(trace_file_path, "w");
    if (trace_file != NULL) {
        setvbuf(trace_file, NULL, _IOLBF, 0);
        trace_initialized = 1;
    }
    pthread_mutex_unlock(&trace_mutex);
}

void tla_trace_get_timestamp(char *buf, size_t buflen)
{
    struct timespec ts;
    struct tm tm_info;

    clock_gettime(CLOCK_REALTIME, &ts);
    gmtime_r(&ts.tv_sec, &tm_info);

    snprintf(buf, buflen, "%04d-%02d-%02dT%02d:%02d:%02d.%03ldZ",
             tm_info.tm_year + 1900,
             tm_info.tm_mon + 1,
             tm_info.tm_mday,
             tm_info.tm_hour,
             tm_info.tm_min,
             tm_info.tm_sec,
             ts.tv_nsec / 1000000);
}

static void emit_event(const char *event_json)
{
    pthread_mutex_lock(&trace_mutex);
    if (trace_file != NULL && trace_initialized) {
        fprintf(trace_file, "%s\n", event_json);
        fflush(trace_file);
    }
    pthread_mutex_unlock(&trace_mutex);
}

void tla_trace_chunk_send_init(
    uint32_t large_message_size,
    uint32_t large_message_capacity,
    uint32_t chunk_size,
    bool send_active,
    bool get_active,
    bool large_message_valid,
    bool seq_no_wrap_error
)
{
    char timestamp[64];
    char event_json[1024];

    if (!trace_initialized) return;

    tla_trace_get_timestamp(timestamp, sizeof(timestamp));

    snprintf(event_json, sizeof(event_json),
        "{\"eventName\":\"ChunkSendInit\",\"timestamp\":\"%s\",\"nodeId\":\"responder\","
        "\"state\":{"
        "\"chunk_context\":{\"send\":%s,\"get\":%s,\"seq_no\":0,\"bytes_transferred\":0},"
        "\"large_message_size\":%u,"
        "\"large_message_capacity\":%u,"
        "\"large_message_valid\":%s,"
        "\"chunk_phase\":\"INIT\","
        "\"seq_no_wrap_error\":%s"
        "},"
        "\"message\":{"
        "\"chunk_size\":%u"
        "}"
        "}",
        timestamp,
        send_active ? "true" : "false",
        get_active ? "true" : "false",
        large_message_size,
        large_message_capacity,
        large_message_valid ? "true" : "false",
        seq_no_wrap_error ? "true" : "false",
        chunk_size
    );

    emit_event(event_json);
}

void tla_trace_chunk_send_continuation(
    uint32_t seq_no,
    uint32_t bytes_transferred,
    uint32_t chunk_size,
    uint32_t large_message_size,
    uint32_t large_message_capacity,
    bool send_active,
    bool get_active,
    bool large_message_valid,
    bool seq_no_wrap_error
)
{
    char timestamp[64];
    char event_json[1024];

    if (!trace_initialized) return;

    tla_trace_get_timestamp(timestamp, sizeof(timestamp));

    snprintf(event_json, sizeof(event_json),
        "{\"eventName\":\"ChunkSendContinuation\",\"timestamp\":\"%s\",\"nodeId\":\"responder\","
        "\"state\":{"
        "\"chunk_context\":{\"send\":%s,\"get\":%s,\"seq_no\":%u,\"bytes_transferred\":%u},"
        "\"large_message_size\":%u,"
        "\"large_message_capacity\":%u,"
        "\"large_message_valid\":%s,"
        "\"chunk_phase\":\"CONTINUATION\","
        "\"seq_no_wrap_error\":%s"
        "},"
        "\"message\":{"
        "\"chunk_size\":%u"
        "}"
        "}",
        timestamp,
        send_active ? "true" : "false",
        get_active ? "true" : "false",
        seq_no,
        bytes_transferred,
        large_message_size,
        large_message_capacity,
        large_message_valid ? "true" : "false",
        seq_no_wrap_error ? "true" : "false",
        chunk_size
    );

    emit_event(event_json);
}

void tla_trace_receive_interruption(
    const char *cmd_type,
    bool send_active,
    bool get_active,
    uint32_t seq_no,
    uint32_t bytes_transferred,
    uint32_t large_message_size,
    bool large_message_valid,
    bool seq_no_wrap_error
)
{
    char timestamp[64];
    char event_json[1024];

    if (!trace_initialized) return;

    tla_trace_get_timestamp(timestamp, sizeof(timestamp));

    snprintf(event_json, sizeof(event_json),
        "{\"eventName\":\"ReceiveInterruption\",\"timestamp\":\"%s\",\"nodeId\":\"responder\","
        "\"state\":{"
        "\"chunk_context\":{\"send\":%s,\"get\":%s,\"seq_no\":%u,\"bytes_transferred\":%u},"
        "\"large_message_size\":%u,"
        "\"large_message_valid\":%s,"
        "\"chunk_phase\":\"INIT\","
        "\"seq_no_wrap_error\":%s"
        "},"
        "\"message\":{"
        "\"cmd_type\":\"%s\""
        "}"
        "}",
        timestamp,
        send_active ? "true" : "false",
        get_active ? "true" : "false",
        seq_no,
        bytes_transferred,
        large_message_size,
        large_message_valid ? "true" : "false",
        seq_no_wrap_error ? "true" : "false",
        cmd_type
    );

    emit_event(event_json);
}

void tla_trace_error_during_reassembly(
    bool send_active,
    bool get_active,
    uint32_t large_message_size,
    bool large_message_valid,
    bool seq_no_wrap_error
)
{
    char timestamp[64];
    char event_json[512];

    if (!trace_initialized) return;

    tla_trace_get_timestamp(timestamp, sizeof(timestamp));

    snprintf(event_json, sizeof(event_json),
        "{\"eventName\":\"ErrorDuringReassembly\",\"timestamp\":\"%s\",\"nodeId\":\"responder\","
        "\"state\":{"
        "\"chunk_context\":{\"send\":%s,\"get\":%s,\"seq_no\":0,\"bytes_transferred\":0},"
        "\"large_message_size\":%u,"
        "\"large_message_valid\":%s,"
        "\"chunk_phase\":\"INIT\","
        "\"seq_no_wrap_error\":%s"
        "},"
        "\"message\":{}"
        "}",
        timestamp,
        send_active ? "true" : "false",
        get_active ? "true" : "false",
        large_message_size,
        large_message_valid ? "true" : "false",
        seq_no_wrap_error ? "true" : "false"
    );

    emit_event(event_json);
}

void tla_trace_shutdown(void)
{
    pthread_mutex_lock(&trace_mutex);
    if (trace_file != NULL) {
        fclose(trace_file);
        trace_file = NULL;
    }
    trace_initialized = 0;
    pthread_mutex_unlock(&trace_mutex);
}
