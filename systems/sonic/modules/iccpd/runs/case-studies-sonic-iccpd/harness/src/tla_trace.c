/*
 * tla_trace.c — NDJSON trace emission for sonic-iccpd
 *
 * Single-threaded: no mutex needed (instrumentation spec 3.1).
 * Uses CLOCK_MONOTONIC for real timestamps.
 */
#include "tla_trace.h"

#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* Include iccpd headers for struct access */
#include "../include/iccp_csm.h"
#include "../include/mlacp_fsm.h"
#include "../include/app_csm.h"

/* ====== Globals ====== */

static FILE *g_trace_file = NULL;

/* CSM → peer-id mapping (max 2 peers) */
#define MAX_PEERS 2
static struct {
    struct CSM *csm;
    char nid[8];
} g_peer_map[MAX_PEERS];
static int g_peer_count = 0;

/* ====== Init/Close ====== */

void tla_trace_init(const char *filename)
{
    if (g_trace_file)
        fclose(g_trace_file);
    g_trace_file = fopen(filename, "w");
    g_peer_count = 0;
}

void tla_trace_close(void)
{
    if (g_trace_file) {
        fflush(g_trace_file);
        fclose(g_trace_file);
        g_trace_file = NULL;
    }
}

void tla_trace_register_csm(struct CSM *csm, const char *peer_id)
{
    if (g_peer_count >= MAX_PEERS)
        return;
    g_peer_map[g_peer_count].csm = csm;
    strncpy(g_peer_map[g_peer_count].nid, peer_id, 7);
    g_peer_map[g_peer_count].nid[7] = '\0';
    g_peer_count++;
}

const char *tla_trace_nid(struct CSM *csm)
{
    for (int i = 0; i < g_peer_count; i++) {
        if (g_peer_map[i].csm == csm)
            return g_peer_map[i].nid;
    }
    return "unknown";
}

/* ====== Helpers ====== */

static long long monotonic_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static const char *mlacp_state_name(int state)
{
    switch (state) {
    case MLACP_STATE_INIT:     return "INIT";
    case MLACP_STATE_STAGE1:   return "STAGE1";
    case MLACP_STATE_STAGE2:   return "STAGE2";
    case MLACP_STATE_EXCHANGE: return "EXCHANGE";
    case MLACP_STATE_ERROR:    return "ERROR";
    default:                   return "UNKNOWN";
    }
}

/* ====== Config line ====== */

void tla_trace_write_config(void)
{
    if (!g_trace_file)
        return;
    fprintf(g_trace_file,
        "{\"tag\":\"config\",\"ts\":\"%lld\","
        "\"config\":{\"servers\":[\"p1\",\"p2\"]}}\n",
        monotonic_ns());
    fflush(g_trace_file);
}

/* ====== Core emit: protocol state event ====== */

void tla_trace_emit(const char *event_name, struct CSM *csm)
{
    if (!g_trace_file || !csm)
        return;

    const char *nid = tla_trace_nid(csm);

    fprintf(g_trace_file,
        "{\"tag\":\"trace\",\"ts\":\"%lld\","
        "\"event\":{\"name\":\"%s\",\"nid\":\"%s\","
        "\"state\":{"
        "\"mlacpState\":\"%s\","
        "\"connected\":%s,"
        "\"iccpOperational\":%s,"
        "\"nodeId\":%u,"
        "\"waitForSyncData\":%s,"
        "\"needToSync\":%s"
        "}}}\n",
        monotonic_ns(),
        event_name, nid,
        mlacp_state_name(MLACP(csm).current_state),
        csm->sock_fd > 0 ? "true" : "false",
        csm->app_csm.current_state == APP_OPERATIONAL ? "true" : "false",
        (unsigned)MLACP(csm).node_id,
        MLACP(csm).wait_for_sync_data ? "true" : "false",
        MLACP(csm).need_to_sync ? "true" : "false");
    fflush(g_trace_file);
}

/* ====== MAC event ====== */

void tla_trace_emit_mac(const char *event_name, struct CSM *csm,
                        const char *mac_str, int age_flag,
                        int pending_local_del, int port_up)
{
    if (!g_trace_file || !csm)
        return;

    const char *nid = tla_trace_nid(csm);

    fprintf(g_trace_file,
        "{\"tag\":\"trace\",\"ts\":\"%lld\","
        "\"event\":{\"name\":\"%s\",\"nid\":\"%s\","
        "\"mac\":\"%s\","
        "\"state\":{"
        "\"mlacpState\":\"%s\","
        "\"connected\":%s,"
        "\"iccpOperational\":%s,"
        "\"nodeId\":%u,"
        "\"waitForSyncData\":%s,"
        "\"needToSync\":%s,"
        "\"ageFlag\":%d,"
        "\"pendingLocalDel\":%s,"
        "\"portState\":\"%s\""
        "}}}\n",
        monotonic_ns(),
        event_name, nid,
        mac_str ? mac_str : "00:00:00:00:00:00",
        mlacp_state_name(MLACP(csm).current_state),
        csm->sock_fd > 0 ? "true" : "false",
        csm->app_csm.current_state == APP_OPERATIONAL ? "true" : "false",
        (unsigned)MLACP(csm).node_id,
        MLACP(csm).wait_for_sync_data ? "true" : "false",
        MLACP(csm).need_to_sync ? "true" : "false",
        age_flag,
        pending_local_del ? "true" : "false",
        port_up ? "UP" : "DOWN");
    fflush(g_trace_file);
}

/* ====== MAC update event (wrong-variable bug, Finding M1) ====== */

void tla_trace_emit_mac_update(const char *event_name, struct CSM *csm,
                               const char *mac_str, int stored_age_flag,
                               int incoming_age_flag)
{
    if (!g_trace_file || !csm)
        return;

    const char *nid = tla_trace_nid(csm);

    fprintf(g_trace_file,
        "{\"tag\":\"trace\",\"ts\":\"%lld\","
        "\"event\":{\"name\":\"%s\",\"nid\":\"%s\","
        "\"mac\":\"%s\","
        "\"state\":{"
        "\"mlacpState\":\"%s\","
        "\"connected\":%s,"
        "\"iccpOperational\":%s,"
        "\"nodeId\":%u,"
        "\"waitForSyncData\":%s,"
        "\"needToSync\":%s,"
        "\"ageFlag\":%d,"
        "\"storedAgeFlag\":%d,"
        "\"incomingAgeFlag\":%d"
        "}}}\n",
        monotonic_ns(),
        event_name, nid,
        mac_str ? mac_str : "00:00:00:00:00:00",
        mlacp_state_name(MLACP(csm).current_state),
        csm->sock_fd > 0 ? "true" : "false",
        csm->app_csm.current_state == APP_OPERATIONAL ? "true" : "false",
        (unsigned)MLACP(csm).node_id,
        MLACP(csm).wait_for_sync_data ? "true" : "false",
        MLACP(csm).need_to_sync ? "true" : "false",
        stored_age_flag,
        stored_age_flag,
        incoming_age_flag);
    fflush(g_trace_file);
}

/* ====== NAK event ====== */

void tla_trace_emit_nak(const char *event_name, struct CSM *csm,
                        const char *nak_type)
{
    if (!g_trace_file || !csm)
        return;

    const char *nid = tla_trace_nid(csm);

    fprintf(g_trace_file,
        "{\"tag\":\"trace\",\"ts\":\"%lld\","
        "\"event\":{\"name\":\"%s\",\"nid\":\"%s\","
        "\"state\":{"
        "\"mlacpState\":\"%s\","
        "\"connected\":%s,"
        "\"iccpOperational\":%s,"
        "\"nodeId\":%u,"
        "\"waitForSyncData\":%s,"
        "\"needToSync\":%s"
        "},"
        "\"msg\":{\"nakType\":\"%s\"}"
        "}}\n",
        monotonic_ns(),
        event_name, nid,
        mlacp_state_name(MLACP(csm).current_state),
        csm->sock_fd > 0 ? "true" : "false",
        csm->app_csm.current_state == APP_OPERATIONAL ? "true" : "false",
        (unsigned)MLACP(csm).node_id,
        MLACP(csm).wait_for_sync_data ? "true" : "false",
        MLACP(csm).need_to_sync ? "true" : "false",
        nak_type ? nak_type : "Other");
    fflush(g_trace_file);
}

/* ====== SysConfig event ====== */

void tla_trace_emit_sysconfig(const char *event_name, struct CSM *csm,
                              int remote_node_id)
{
    if (!g_trace_file || !csm)
        return;

    const char *nid = tla_trace_nid(csm);

    fprintf(g_trace_file,
        "{\"tag\":\"trace\",\"ts\":\"%lld\","
        "\"event\":{\"name\":\"%s\",\"nid\":\"%s\","
        "\"state\":{"
        "\"mlacpState\":\"%s\","
        "\"connected\":%s,"
        "\"iccpOperational\":%s,"
        "\"nodeId\":%u,"
        "\"waitForSyncData\":%s,"
        "\"needToSync\":%s"
        "},"
        "\"msg\":{\"remoteNodeId\":%d}"
        "}}\n",
        monotonic_ns(),
        event_name, nid,
        mlacp_state_name(MLACP(csm).current_state),
        csm->sock_fd > 0 ? "true" : "false",
        csm->app_csm.current_state == APP_OPERATIONAL ? "true" : "false",
        (unsigned)MLACP(csm).node_id,
        MLACP(csm).wait_for_sync_data ? "true" : "false",
        MLACP(csm).need_to_sync ? "true" : "false",
        remote_node_id);
    fflush(g_trace_file);
}
