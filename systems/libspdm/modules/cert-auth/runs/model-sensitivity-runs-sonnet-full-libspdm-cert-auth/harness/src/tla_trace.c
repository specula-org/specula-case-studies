/* TLA+ trace emission implementation for libspdm CHALLENGE auth. */
#define _POSIX_C_SOURCE 199309L
#include "tla_trace.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* libspdm connection_state enum ordinal values (matches spdm_common_lib.h) */
#define CONN_NOT_STARTED        0
#define CONN_AFTER_VERSION      1
#define CONN_AFTER_CAPABILITIES 2
#define CONN_NEGOTIATED         3
#define CONN_AFTER_DIGESTS      4
#define CONN_AFTER_CERTIFICATE  5
#define CONN_AUTHENTICATED      6

static FILE *g_trace_file = NULL;

void tla_trace_init(const char *path) {
    g_trace_file = fopen(path, "w");
    if (!g_trace_file) {
        fprintf(stderr, "[tla_trace] ERROR: cannot open %s\n", path);
    }
}

void tla_trace_close(void) {
    if (g_trace_file) {
        fflush(g_trace_file);
        fclose(g_trace_file);
        g_trace_file = NULL;
    }
}

const char *tla_conn_state_str(uint32_t state) {
    switch ((int)state) {
    case CONN_NOT_STARTED:        return "NOT_STARTED";
    case CONN_AFTER_VERSION:      return "AFTER_VERSION";
    case CONN_AFTER_CAPABILITIES: return "AFTER_CAPABILITIES";
    case CONN_NEGOTIATED:         return "NEGOTIATED";
    case CONN_AFTER_DIGESTS:      return "AFTER_DIGESTS";
    case CONN_AFTER_CERTIFICATE:  return "AFTER_CERTIFICATE";
    case CONN_AUTHENTICATED:      return "AUTHENTICATED";
    default:                      return "UNKNOWN";
    }
}

static unsigned long long now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (unsigned long long)ts.tv_sec * 1000000000ULL +
           (unsigned long long)ts.tv_nsec;
}

void tla_trace_emit(const char *event, const char *node, uint32_t conn_state) {
    if (!g_trace_file) return;
    fprintf(g_trace_file,
            "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"%s\","
            "\"node\":\"%s\",\"connection_state\":\"%s\"}\n",
            now_ns(), event, node, tla_conn_state_str(conn_state));
    fflush(g_trace_file);
}

void tla_trace_emit_slot(const char *event, const char *node,
                         uint32_t conn_state, unsigned int slot) {
    if (!g_trace_file) return;
    fprintf(g_trace_file,
            "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"%s\","
            "\"node\":\"%s\",\"connection_state\":\"%s\",\"slot\":%u}\n",
            now_ns(), event, node, tla_conn_state_str(conn_state), slot);
    fflush(g_trace_file);
}

void tla_trace_emit_cert_rsp(const char *event, const char *node,
                              uint32_t conn_state, unsigned int slot,
                              int in_session) {
    if (!g_trace_file) return;
    fprintf(g_trace_file,
            "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"%s\","
            "\"node\":\"%s\",\"connection_state\":\"%s\","
            "\"slot\":%u,\"in_session\":%s}\n",
            now_ns(), event, node, tla_conn_state_str(conn_state),
            slot, in_session ? "true" : "false");
    fflush(g_trace_file);
}

void tla_trace_emit_cert_recv(const char *event, const char *node,
                               uint32_t conn_state, unsigned int slot,
                               int cert_fetched, int cert_hash_valid) {
    if (!g_trace_file) return;
    fprintf(g_trace_file,
            "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"%s\","
            "\"node\":\"%s\",\"connection_state\":\"%s\","
            "\"slot\":%u,\"cert_fetched\":%s,\"cert_hash_valid\":%s}\n",
            now_ns(), event, node, tla_conn_state_str(conn_state),
            slot,
            cert_fetched ? "true" : "false",
            cert_hash_valid ? "true" : "false");
    fflush(g_trace_file);
}

void tla_trace_emit_verify(const char *event, const char *node,
                            uint32_t conn_state, unsigned int slot,
                            const char *verify_result) {
    if (!g_trace_file) return;
    fprintf(g_trace_file,
            "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"%s\","
            "\"node\":\"%s\",\"connection_state\":\"%s\","
            "\"slot\":%u,\"verify_result\":\"%s\"}\n",
            now_ns(), event, node, tla_conn_state_str(conn_state),
            slot, verify_result);
    fflush(g_trace_file);
}

void tla_trace_emit_status(const char *event, const char *node,
                            uint32_t conn_state, uint32_t status_code) {
    if (!g_trace_file) return;
    fprintf(g_trace_file,
            "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"%s\","
            "\"node\":\"%s\",\"connection_state\":\"%s\","
            "\"status\":\"0x%08x\"}\n",
            now_ns(), event, node, tla_conn_state_str(conn_state),
            (unsigned int)status_code);
    fflush(g_trace_file);
}

void tla_trace_emit_slot_status(const char *event, const char *node,
                                 uint32_t conn_state, unsigned int slot,
                                 uint32_t status_code) {
    if (!g_trace_file) return;
    fprintf(g_trace_file,
            "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"%s\","
            "\"node\":\"%s\",\"connection_state\":\"%s\","
            "\"slot\":%u,\"status\":\"0x%08x\"}\n",
            now_ns(), event, node, tla_conn_state_str(conn_state),
            slot, (unsigned int)status_code);
    fflush(g_trace_file);
}
