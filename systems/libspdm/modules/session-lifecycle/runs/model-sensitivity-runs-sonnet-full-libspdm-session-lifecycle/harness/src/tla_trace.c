/*
 * TLA+ trace emission implementation for libspdm session lifecycle.
 */

#include "tla_trace.h"
#include <inttypes.h>
#include <string.h>

tla_state_t g_tla = {
    .req_tx_gen = 0,
    .rsp_rx_gen = 0,
    .req_ku_state = "idle",
    .rsp_last_key_op = "none",
    .req_session_state = "ESTABLISHED",
    .rsp_session_state = "ESTABLISHED",
    .rsp_rx_backup_valid = false,
    .end_session_sent = false,
    .end_session_ack_encoded = false,
    .watchdog_active = true,
};

FILE *g_tla_file = NULL;

void tla_init(const char *path) {
    g_tla_file = fopen(path, "w");
}

void tla_finish(void) {
    if (g_tla_file) {
        fflush(g_tla_file);
        fclose(g_tla_file);
        g_tla_file = NULL;
    }
}

static uint64_t g_tla_seq = 0;

static uint64_t tla_now_ns(void) {
    return g_tla_seq++;
}

void tla_emit(const char *event, const char *mtype, int param1, int param2) {
    if (!g_tla_file) return;
    uint64_t ts = tla_now_ns();
    fprintf(g_tla_file,
        "{\"tag\":\"trace\",\"ts\":\"%" PRIu64 "\","
        "\"event\":\"%s\","
        "\"state\":{"
            "\"req_session_state\":\"%s\","
            "\"rsp_session_state\":\"%s\","
            "\"req_ku_state\":\"%s\","
            "\"rsp_last_key_op\":\"%s\","
            "\"req_tx_gen\":%d,"
            "\"rsp_rx_gen\":%d,"
            "\"rsp_rx_backup_valid\":%s,"
            "\"end_session_sent\":%s,"
            "\"end_session_ack_encoded\":%s,"
            "\"watchdog_active\":%s"
        "}",
        ts, event,
        g_tla.req_session_state,
        g_tla.rsp_session_state,
        g_tla.req_ku_state,
        g_tla.rsp_last_key_op,
        g_tla.req_tx_gen,
        g_tla.rsp_rx_gen,
        g_tla.rsp_rx_backup_valid ? "true" : "false",
        g_tla.end_session_sent ? "true" : "false",
        g_tla.end_session_ack_encoded ? "true" : "false",
        g_tla.watchdog_active ? "true" : "false");
    if (mtype) {
        fprintf(g_tla_file,
            ",\"msg\":{\"mtype\":\"%s\",\"param1\":%d,\"param2\":%d}",
            mtype, param1, param2);
    }
    fprintf(g_tla_file, "}\n");
    fflush(g_tla_file);
}
