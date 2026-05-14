/*
 * test_harness.c — Test driver for sonic-iccpd trace generation.
 *
 * Replaces iccp_main.c. Creates two CSM instances (p1=Active, p2=Standby),
 * drives the MLACP protocol through the real code, and collects NDJSON traces.
 *
 * Message routing: iccp_csm_send() is patched (via TLA_TRACE_TEST) to call
 * tla_route_message(), which enqueues the raw bytes on the other CSM.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <arpa/inet.h>

#include "../include/system.h"
#include "../include/iccp_csm.h"
#include "../include/mlacp_fsm.h"
#include "../include/mlacp_link_handler.h"
#include "../include/mlacp_sync_update.h"
#include "../include/scheduler.h"
#include "../include/app_csm.h"
#include "../include/msg_format.h"
#include "../include/mlacp_tlv.h"

#include "tla_trace.h"

/* ====== Global CSM pointers for message routing ====== */
static struct CSM *g_csm_p1 = NULL;
static struct CSM *g_csm_p2 = NULL;

/* ====== Message routing (called from patched iccp_csm_send) ====== */

void tla_route_message(struct CSM *src, char *buf, int len)
{
    struct CSM *dst;
    struct Msg *msg;

    if (!src || !buf || len <= 0)
        return;

    /* Determine destination */
    if (src == g_csm_p1)
        dst = g_csm_p2;
    else if (src == g_csm_p2)
        dst = g_csm_p1;
    else
        return;

    if (!dst)
        return;

    /* Create a Msg and enqueue on destination's mLACP message list */
    msg = (struct Msg *)calloc(1, sizeof(struct Msg));
    if (!msg)
        return;
    msg->buf = (char *)malloc(len);
    if (!msg->buf) {
        free(msg);
        return;
    }
    memcpy(msg->buf, buf, len);
    msg->len = len;

    /* Route through iccp_csm_enqueue_msg which does byte-order conversions
     * matching the real receive path: socket → scheduler → iccp_csm_enqueue_msg
     * → ntohs on LDPHdr → app_csm_enqueue_msg → ntohs on ICCParameter
     * → mlacp_enqueue_msg */
    iccp_csm_enqueue_msg(dst, msg);
}

/* ====== Setup helpers ====== */

static struct CSM *create_test_csm(const char *sender_ip,
                                   const char *peer_ip,
                                   int role, int mlag_id)
{
    struct CSM *csm = system_create_csm();
    if (!csm) {
        fprintf(stderr, "Failed to create CSM\n");
        exit(1);
    }

    csm->mlag_id = mlag_id;
    strncpy(csm->sender_ip, sender_ip, INET_ADDRSTRLEN - 1);
    strncpy(csm->peer_ip, peer_ip, INET_ADDRSTRLEN - 1);
    csm->role_type = role;
    csm->session_timeout = 15;
    csm->keepalive_time = 1;

    /* Initialize MLACP */
    mlacp_init(csm, 1);

    return csm;
}

static void simulate_tcp_connect(struct CSM *csm, int fake_fd)
{
    csm->sock_fd = fake_fd;
    time(&csm->heartbeat_update_time);
    /* Note: TcpConnect trace event emitted manually by caller because
     * the spec's TcpConnect action connects both peers atomically */
}

static void simulate_iccp_operational(struct CSM *csm)
{
    csm->app_csm.current_state = APP_OPERATIONAL;
    csm->current_state = ICCP_OPERATIONAL;
    tla_trace_emit("IccpBecomeOperational", csm);
}

/* ====== Scenario 1: Normal MLACP Handshake ====== */

static void scenario_handshake(const char *trace_file)
{
    struct CSM *p1, *p2;
    int iter;

    printf("=== Scenario: MLACP Handshake ===\n");
    tla_trace_init(trace_file);

    /* Create peers */
    p1 = create_test_csm("10.0.0.1", "10.0.0.2", STP_ROLE_ACTIVE, 1);
    p2 = create_test_csm("10.0.0.2", "10.0.0.1", STP_ROLE_STANDBY, 1);

    g_csm_p1 = p1;
    g_csm_p2 = p2;
    tla_trace_register_csm(p1, "p1");
    tla_trace_register_csm(p2, "p2");
    tla_trace_write_config();

    /* Set small node_ids to fit within MaxNodeId=10 in Trace.cfg */
    MLACP(p1).node_id = 1;
    MLACP(p2).node_id = 2;

    /* Phase 1: TCP connection + ICCP setup
     * Spec's TcpConnect connects both peers atomically, so emit once for p1 */
    simulate_tcp_connect(p1, 100);
    p2->sock_fd = 101;
    time(&p2->heartbeat_update_time);
    /* Only emit TcpConnect once — spec action sets both connected simultaneously */
    tla_trace_emit("TcpConnect", p1);
    simulate_iccp_operational(p1);
    simulate_iccp_operational(p2);

    /* Phase 2: MLACP handshake — drive FSM alternately */
    for (iter = 0; iter < 20; iter++) {
        mlacp_fsm_transit(p1);
        mlacp_fsm_transit(p2);

        if (MLACP(p1).current_state == MLACP_STATE_EXCHANGE &&
            MLACP(p2).current_state == MLACP_STATE_EXCHANGE)
        {
            printf("  Both peers reached EXCHANGE after %d iterations\n",
                   iter + 1);
            break;
        }
    }

    /* Phase 3: Send some heartbeats */
    p1->heartbeat_send_time = 0;
    mlacp_fsm_transit(p1);
    mlacp_fsm_transit(p2);

    p2->heartbeat_send_time = 0;
    mlacp_fsm_transit(p2);
    mlacp_fsm_transit(p1);

    printf("  Final states: p1=%s, p2=%s\n",
           mlacp_state(p1), mlacp_state(p2));

    tla_trace_close();
    g_csm_p1 = NULL;
    g_csm_p2 = NULL;
}

/* ====== Scenario 2: Session Disconnect ====== */

static void scenario_disconnect(const char *trace_file)
{
    struct CSM *p1, *p2;
    int iter;

    printf("=== Scenario: Session Disconnect ===\n");
    tla_trace_init(trace_file);

    p1 = create_test_csm("10.0.0.3", "10.0.0.4", STP_ROLE_ACTIVE, 2);
    p2 = create_test_csm("10.0.0.4", "10.0.0.3", STP_ROLE_STANDBY, 2);

    g_csm_p1 = p1;
    g_csm_p2 = p2;
    tla_trace_register_csm(p1, "p1");
    tla_trace_register_csm(p2, "p2");
    tla_trace_write_config();

    MLACP(p1).node_id = 1;
    MLACP(p2).node_id = 2;
    simulate_tcp_connect(p1, 200);
    p2->sock_fd = 201;
    time(&p2->heartbeat_update_time);
    tla_trace_emit("TcpConnect", p1);
    simulate_iccp_operational(p1);
    simulate_iccp_operational(p2);

    for (iter = 0; iter < 20; iter++) {
        mlacp_fsm_transit(p1);
        mlacp_fsm_transit(p2);
        if (MLACP(p1).current_state == MLACP_STATE_EXCHANGE &&
            MLACP(p2).current_state == MLACP_STATE_EXCHANGE)
            break;
    }
    printf("  Both in EXCHANGE\n");

    /* Send a heartbeat */
    p1->heartbeat_send_time = 0;
    mlacp_fsm_transit(p1);
    mlacp_fsm_transit(p2);

    /* Session disconnect on p1 */
    scheduler_session_disconnect_handler(p1);

    printf("  After disconnect: p1=%s connected=%d\n",
           mlacp_state(p1), p1->sock_fd > 0);

    tla_trace_close();
    g_csm_p1 = NULL;
    g_csm_p2 = NULL;
}

/* ====== Scenario 3: Bug Family 2 — Sync Request in EXCHANGE ====== */

static void scenario_exchange_sync_bug(const char *trace_file)
{
    struct CSM *p1, *p2;
    int iter;

    printf("=== Scenario: Exchange Sync Bug (Family 2) ===\n");
    tla_trace_init(trace_file);

    p1 = create_test_csm("10.0.0.5", "10.0.0.6", STP_ROLE_ACTIVE, 3);
    p2 = create_test_csm("10.0.0.6", "10.0.0.5", STP_ROLE_STANDBY, 3);

    g_csm_p1 = p1;
    g_csm_p2 = p2;
    tla_trace_register_csm(p1, "p1");
    tla_trace_register_csm(p2, "p2");
    tla_trace_write_config();

    MLACP(p1).node_id = 1;
    MLACP(p2).node_id = 2;
    simulate_tcp_connect(p1, 300);
    p2->sock_fd = 301;
    time(&p2->heartbeat_update_time);
    tla_trace_emit("TcpConnect", p1);
    simulate_iccp_operational(p1);
    simulate_iccp_operational(p2);

    for (iter = 0; iter < 20; iter++) {
        mlacp_fsm_transit(p1);
        mlacp_fsm_transit(p2);
        if (MLACP(p1).current_state == MLACP_STATE_EXCHANGE &&
            MLACP(p2).current_state == MLACP_STATE_EXCHANGE)
            break;
    }
    printf("  Both in EXCHANGE\n");

    /* Trigger need_to_sync on p2 → MlacpSendSyncRequestFromExchange */
    MLACP(p2).need_to_sync = 1;
    mlacp_fsm_transit(p2);

    /* p1 processes sync request → MlacpReceiveSyncRequestInExchange */
    /* This triggers current_state++ → EXCHANGE→ERROR (Bug Family 2) */
    mlacp_fsm_transit(p1);

    printf("  After exchange sync: p1=%s (expect ERROR)\n", mlacp_state(p1));

    tla_trace_close();
    g_csm_p1 = NULL;
    g_csm_p2 = NULL;
}

/* ====== Main ====== */

int main(int argc, char *argv[])
{
    const char *trace_dir = ".";
    char path[256];

    (void)argc; (void)argv;

    if (argc > 1)
        trace_dir = argv[1];

    printf("sonic-iccpd trace harness\n");
    printf("Trace output directory: %s\n\n", trace_dir);

    /* Ensure System singleton is initialized */
    struct System *sys = system_get_instance();
    if (!sys) {
        fprintf(stderr, "Failed to initialize system\n");
        return 1;
    }
    /* Set fds to -1 to prevent I/O operations */
    sys->sync_fd = -1;
    sys->sync_ctrl_fd = -1;
    sys->server_fd = -1;

    /* Run scenarios */
    snprintf(path, sizeof(path), "%s/handshake.ndjson", trace_dir);
    scenario_handshake(path);

    snprintf(path, sizeof(path), "%s/disconnect.ndjson", trace_dir);
    scenario_disconnect(path);

    snprintf(path, sizeof(path), "%s/exchange_sync_bug.ndjson", trace_dir);
    scenario_exchange_sync_bug(path);

    printf("\nAll scenarios complete.\n");
    return 0;
}
