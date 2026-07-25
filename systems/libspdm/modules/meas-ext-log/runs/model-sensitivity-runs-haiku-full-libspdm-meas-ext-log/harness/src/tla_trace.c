#include "tla_trace.h"
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <time.h>
#include <string.h>

static FILE *g_trace_file = NULL;
static pthread_mutex_t g_trace_mutex = PTHREAD_MUTEX_INITIALIZER;

/* Get current timestamp in nanoseconds */
static uint64_t get_timestamp_ns(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0) {
        return 0;
    }
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

void tla_trace_init(const char *trace_file) {
    pthread_mutex_lock(&g_trace_mutex);
    if (g_trace_file != NULL) {
        fclose(g_trace_file);
    }
    g_trace_file = fopen(trace_file, "w");
    if (g_trace_file == NULL) {
        fprintf(stderr, "Failed to open trace file: %s\n", trace_file);
    }
    pthread_mutex_unlock(&g_trace_mutex);
}

void tla_trace_shutdown(void) {
    pthread_mutex_lock(&g_trace_mutex);
    if (g_trace_file != NULL) {
        fclose(g_trace_file);
        g_trace_file = NULL;
    }
    pthread_mutex_unlock(&g_trace_mutex);
}

/* Helper macro to emit NDJSON event */
#define EMIT_EVENT(fmt, ...) do { \
    if (g_trace_file != NULL) { \
        fprintf(g_trace_file, fmt, ##__VA_ARGS__); \
        fflush(g_trace_file); \
    } \
} while (0)

void tla_trace_init_event(
    uint32_t responder_mel_size,
    uint32_t responder_mel_entries_len,
    uint32_t req_offset,
    uint32_t req_mel_size,
    uint32_t req_remainder,
    uint32_t req_total_mel_size,
    const char *req_pc,
    const char *responder_pc) {

    pthread_mutex_lock(&g_trace_mutex);
    EMIT_EVENT("{\"tag\":\"trace\",\"ts\":%llu,\"event_name\":\"init\","
        "\"responder_mel_size\":%u,\"responder_mel_entries_len\":%u,"
        "\"req_offset\":%u,\"req_mel_size\":%u,\"req_remainder\":%u,"
        "\"req_total_mel_size\":%u,\"req_pc\":\"%s\",\"responder_pc\":\"%s\"}\n",
        (unsigned long long)get_timestamp_ns(),
        responder_mel_size, responder_mel_entries_len,
        req_offset, req_mel_size, req_remainder,
        req_total_mel_size, req_pc, responder_pc);
    pthread_mutex_unlock(&g_trace_mutex);
}

void tla_trace_req_send_get_mel(
    uint32_t msg_offset,
    uint32_t msg_length,
    uint32_t req_offset,
    uint32_t req_mel_size,
    uint32_t req_remainder,
    uint32_t req_total_mel_size,
    const char *req_pc) {

    pthread_mutex_lock(&g_trace_mutex);
    EMIT_EVENT("{\"tag\":\"trace\",\"ts\":%llu,\"event_name\":\"req_send_get_mel\","
        "\"node\":\"req\",\"msg_type\":\"GetMelRequest\","
        "\"msg_offset\":%u,\"msg_length\":%u,"
        "\"req_offset\":%u,\"req_mel_size\":%u,\"req_remainder\":%u,"
        "\"req_total_mel_size\":%u,\"req_pc\":\"%s\"}\n",
        (unsigned long long)get_timestamp_ns(),
        msg_offset, msg_length,
        req_offset, req_mel_size, req_remainder,
        req_total_mel_size, req_pc);
    pthread_mutex_unlock(&g_trace_mutex);
}

void tla_trace_resp_receive_and_send_mel(
    uint32_t msg_portion_length,
    uint32_t msg_remainder_length,
    uint32_t msg_data_len,
    uint32_t responder_mel_size,
    uint32_t responder_mel_entries_len) {

    pthread_mutex_lock(&g_trace_mutex);
    EMIT_EVENT("{\"tag\":\"trace\",\"ts\":%llu,\"event_name\":\"resp_receive_and_send_mel\","
        "\"node\":\"resp\",\"msg_type\":\"MelResponse\","
        "\"msg_portion_length\":%u,\"msg_remainder_length\":%u,\"msg_data_len\":%u,"
        "\"responder_mel_size\":%u,\"responder_mel_entries_len\":%u}\n",
        (unsigned long long)get_timestamp_ns(),
        msg_portion_length, msg_remainder_length, msg_data_len,
        responder_mel_size, responder_mel_entries_len);
    pthread_mutex_unlock(&g_trace_mutex);
}

void tla_trace_req_receive_mel_response(
    uint32_t recv_portion_length,
    uint32_t recv_remainder_length,
    uint32_t req_mel_size,
    uint32_t req_offset,
    uint32_t req_remainder,
    uint32_t req_total_mel_size,
    const char *req_pc) {

    pthread_mutex_lock(&g_trace_mutex);
    EMIT_EVENT("{\"tag\":\"trace\",\"ts\":%llu,\"event_name\":\"req_receive_mel_response\","
        "\"node\":\"req\",\"msg_type\":\"MelResponse\","
        "\"recv_portion_length\":%u,\"recv_remainder_length\":%u,"
        "\"req_mel_size\":%u,\"req_offset\":%u,\"req_remainder\":%u,"
        "\"req_total_mel_size\":%u,\"req_pc\":\"%s\"}\n",
        (unsigned long long)get_timestamp_ns(),
        recv_portion_length, recv_remainder_length,
        req_mel_size, req_offset, req_remainder,
        req_total_mel_size, req_pc);
    pthread_mutex_unlock(&g_trace_mutex);
}

void tla_trace_req_check_termination(
    uint32_t req_mel_size,
    uint32_t req_offset,
    const char *req_pc) {

    pthread_mutex_lock(&g_trace_mutex);
    EMIT_EVENT("{\"tag\":\"trace\",\"ts\":%llu,\"event_name\":\"req_check_termination\","
        "\"node\":\"req\","
        "\"req_mel_size\":%u,\"req_offset\":%u,\"req_pc\":\"%s\"}\n",
        (unsigned long long)get_timestamp_ns(),
        req_mel_size, req_offset, req_pc);
    pthread_mutex_unlock(&g_trace_mutex);
}

void tla_trace_error(const char *event_name, const char *error_code) {
    pthread_mutex_lock(&g_trace_mutex);
    EMIT_EVENT("{\"tag\":\"trace\",\"ts\":%llu,\"event_name\":\"resp_error\","
        "\"error_code\":\"%s\"}\n",
        (unsigned long long)get_timestamp_ns(),
        error_code);
    pthread_mutex_unlock(&g_trace_mutex);
}
