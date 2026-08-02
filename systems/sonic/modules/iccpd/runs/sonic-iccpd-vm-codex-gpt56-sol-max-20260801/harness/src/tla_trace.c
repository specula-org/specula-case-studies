/* SPDX-License-Identifier: GPL-2.0-or-later */
#define _POSIX_C_SOURCE 200809L

#include "tla_trace.h"

#ifdef ICCPD_TLA_TRACE

#include <errno.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "app_csm.h"
#include "iccp_csm.h"
#include "mlacp_fsm.h"
#include "port.h"
#include "system.h"

#define TLA_NODE_COUNT 2
#define TLA_QUEUE_CAP 256
#define TLA_MAX_PROGRESS 64

struct tla_frame {
    char kind[20];
    int epoch;
    int version;
    int generation;
    bool up;
    bool valid;
};

struct tla_queue {
    struct tla_frame item[TLA_QUEUE_CAP];
    unsigned int head;
    unsigned int len;
};

struct tla_node_state {
    struct CSM *csm;
    struct LocalInterface *lif;
    struct PeerInterface *pif;
    bool lag_registered;
    char nid[3];

    bool session_up;
    bool crashed;
    char disconnect_pc[16];
    bool warm_announced;
    bool grace_armed;
    int grace_age;
    bool cleanup_done;
    bool recovery_pending;
    char startup_pc[24];
    int kernel_truth;
    int observed_state;
    bool snapshot_ready;
    int advertised_state;
    bool resync_pending;

    int sync_epoch;
    char sync_phase[12];
    int outstanding_req;
    int responder_epoch;
    char sync_send_step[16];
    int active_envelope;
    int config_epoch;
    int agg_config_epoch;
    int state_epoch;
    int sync_complete;
    int dirty_version;
    int peer_version;
    bool envelope_violation;
    bool config_order_violation;
    bool legal_resync_active;
    char error_reason[24];

    bool scheduler_enabled;
    char stream_state[20];
    int session_activity;
    int protocol_progress;
    int heartbeat_age;
    bool non_progress_traffic;
    int ignored_app_frames;
    bool syncd_connected;
    bool syncd_fd_positive;

    int lag_gen;
    bool local_lag_up;
    bool lag_dirty;
    int peer_known_gen;
    bool peer_lag_up;
    bool peer_interface_known;
    bool isolation_desired;
    int isolation_pending_gen;
    bool isolation_applied_enabled;
    int isolation_applied_gen;
    bool traffic_enabled;
    char traffic_apply_pending[12];
    int ack_pending;
    int ack_gen;

    char tx_context[16];
    char tx_kind[20];
    char send_outcome[12];
    struct tla_frame tx_frame;
    bool tx_pending;
    ssize_t recorded_rc;
    size_t recorded_expected;
    bool send_recorded;
    enum tla_trace_write_mode write_mode;
    bool disconnect_prelogged;
};

static FILE *trace_fp;
static pthread_mutex_t trace_mu = PTHREAD_MUTEX_INITIALIZER;
static struct tla_node_state nodes[TLA_NODE_COUNT];
static struct tla_queue wire[TLA_NODE_COUNT];
static struct tla_queue inbox[TLA_NODE_COUNT];

static const char *json_bool(bool value)
{
    return value ? "true" : "false";
}

static void copy_text(char *dst, size_t size, const char *src)
{
    if (size == 0)
        return;
    snprintf(dst, size, "%s", src ? src : "");
}

static int bounded_inc(int value)
{
    return value < TLA_MAX_PROGRESS ? value + 1 : value;
}

static const char *phase_name(MLACP_APP_STATE_E phase)
{
    switch (phase) {
    case MLACP_STATE_INIT: return "Init";
    case MLACP_STATE_STAGE1: return "Stage1";
    case MLACP_STATE_STAGE2: return "Stage2";
    case MLACP_STATE_EXCHANGE: return "Exchange";
    case MLACP_STATE_ERROR: return "Error";
    default: return "Error";
    }
}

static const char *next_phase(const char *phase)
{
    if (strcmp(phase, "Init") == 0) return "Stage1";
    if (strcmp(phase, "Stage1") == 0) return "Stage2";
    if (strcmp(phase, "Stage2") == 0) return "Exchange";
    return "Error";
}

static const char *next_send_step(const char *step)
{
    if (strcmp(step, "Start") == 0) return "SysConfig";
    if (strcmp(step, "SysConfig") == 0) return "AggConfig";
    if (strcmp(step, "AggConfig") == 0) return "AggState";
    if (strcmp(step, "AggState") == 0) return "Object";
    if (strcmp(step, "Object") == 0) return "End";
    return "Idle";
}

static void queue_clear(struct tla_queue *q)
{
    memset(q, 0, sizeof(*q));
}

static bool queue_push(struct tla_queue *q, const struct tla_frame *frame)
{
    unsigned int pos;

    if (q->len >= TLA_QUEUE_CAP)
        return false;
    pos = (q->head + q->len) % TLA_QUEUE_CAP;
    q->item[pos] = *frame;
    q->len++;
    return true;
}

static bool queue_peek(const struct tla_queue *q, struct tla_frame *frame)
{
    if (q->len == 0)
        return false;
    *frame = q->item[q->head];
    return true;
}

static bool queue_pop(struct tla_queue *q, struct tla_frame *frame)
{
    if (!queue_peek(q, frame))
        return false;
    q->head = (q->head + 1) % TLA_QUEUE_CAP;
    q->len--;
    return true;
}

static void init_node(struct tla_node_state *s, struct CSM *csm,
                      const char *nid)
{
    memset(s, 0, sizeof(*s));
    s->csm = csm;
    copy_text(s->nid, sizeof(s->nid), nid);

    s->session_up = true;
    copy_text(s->disconnect_pc, sizeof(s->disconnect_pc), "Idle");
    s->cleanup_done = true;
    copy_text(s->startup_pc, sizeof(s->startup_pc), "Running");
    s->kernel_truth = 1;
    s->observed_state = 1;
    s->snapshot_ready = true;
    s->advertised_state = 1;

    copy_text(s->sync_phase, sizeof(s->sync_phase), "Exchange");
    s->outstanding_req = -1;
    s->responder_epoch = -1;
    copy_text(s->sync_send_step, sizeof(s->sync_send_step), "Idle");
    s->active_envelope = -1;
    s->config_epoch = -1;
    s->agg_config_epoch = -1;
    s->state_epoch = -1;
    s->sync_complete = 0;
    s->dirty_version = -1;
    s->peer_version = 1;
    copy_text(s->error_reason, sizeof(s->error_reason), "None");

    s->scheduler_enabled = true;
    copy_text(s->stream_state, sizeof(s->stream_state), "Idle");
    s->syncd_connected = true;
    s->syncd_fd_positive = true;

    s->local_lag_up = true;
    s->peer_known_gen = 0;
    s->peer_lag_up = true;
    s->peer_interface_known = true;
    s->isolation_desired = true;
    s->isolation_pending_gen = -1;
    s->isolation_applied_enabled = true;
    s->isolation_applied_gen = 0;
    s->traffic_enabled = true;
    copy_text(s->traffic_apply_pending,
              sizeof(s->traffic_apply_pending), "None");
    s->ack_pending = -1;
    s->ack_gen = 0;

    copy_text(s->tx_context, sizeof(s->tx_context), "None");
    copy_text(s->tx_kind, sizeof(s->tx_kind), "None");
    copy_text(s->send_outcome, sizeof(s->send_outcome), "None");
}

static int node_index(const struct CSM *csm)
{
    int i;

    for (i = 0; i < TLA_NODE_COUNT; i++) {
        if (nodes[i].csm == csm)
            return i;
    }
    return -1;
}

static void refresh_actual(struct tla_node_state *s)
{
    struct System *sys;

    if (!s->csm)
        return;

    s->session_up = s->csm->sock_fd > 0 &&
        s->csm->app_csm.current_state == APP_OPERATIONAL;
    s->warm_announced = s->csm->peer_warm_reboot_time != 0;
    s->grace_armed = s->csm->warm_reboot_disconn_time != 0;
    copy_text(s->sync_phase, sizeof(s->sync_phase),
              phase_name(MLACP(s->csm).current_state));

    sys = system_get_instance();
    if (sys) {
        s->resync_pending = sys->need_sync_netlink_again != 0;
        s->syncd_fd_positive = sys->sync_fd > 0;
    }

    if (s->lag_registered && s->lif) {
        s->local_lag_up = s->lif->po_active != 0;
        s->lag_dirty = s->lif->changed != 0;
        s->isolation_desired = s->lif->isolate_to_peer_link != 0;
        s->traffic_enabled = !s->lif->is_traffic_disable;
        s->peer_interface_known = s->pif != NULL;
        if (s->pif)
            s->peer_lag_up = s->pif->po_active != 0;
    }
}

static uint64_t monotonic_ns(void)
{
    struct timespec ts;

    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * UINT64_C(1000000000) +
           (uint64_t)ts.tv_nsec;
}

static void emit_event(int i, const char *event, bool arg_up, int arg_version)
{
    struct tla_node_state *s = &nodes[i];
    int peer = 1 - i;

    if (!trace_fp)
        return;

    fprintf(trace_fp,
        "{\"tag\":\"trace\",\"timestamp\":\"%" PRIu64 "\","
        "\"event\":{\"name\":\"%s\",\"nid\":\"%s\","
        "\"args\":{\"up\":%s,\"version\":%d},\"state\":{"
        "\"sessionUp\":%s,\"crashed\":%s,"
        "\"disconnectPC\":\"%s\",\"warmAnnounced\":%s,"
        "\"graceArmed\":%s,\"graceAge\":%d,"
        "\"cleanupDone\":%s,\"recoveryPending\":%s,"
        "\"startupPC\":\"%s\",\"kernelTruth\":%d,"
        "\"observedState\":%d,\"snapshotReady\":%s,"
        "\"advertisedState\":%d,\"resyncPending\":%s,"
        "\"syncEpoch\":%d,\"syncPhase\":\"%s\","
        "\"outstandingReq\":%d,\"responderEpoch\":%d,"
        "\"syncSendStep\":\"%s\",\"activeEnvelope\":%d,"
        "\"configEpoch\":%d,\"aggConfigEpoch\":%d,"
        "\"stateEpoch\":%d,\"syncComplete\":%d,"
        "\"dirtyVersion\":%d,\"peerVersion\":%d,"
        "\"envelopeViolation\":%s,\"configOrderViolation\":%s,"
        "\"legalResyncActive\":%s,\"errorReason\":\"%s\","
        "\"schedulerEnabled\":%s,\"streamState\":\"%s\","
        "\"sessionActivity\":%d,\"protocolProgress\":%d,"
        "\"heartbeatAge\":%d,\"nonProgressTraffic\":%s,"
        "\"ignoredAppFrames\":%d,\"syncdConnected\":%s,"
        "\"syncdFdPositive\":%s,\"lagGen\":%d,"
        "\"localLagUp\":%s,\"lagDirty\":%s,"
        "\"peerKnownGen\":%d,\"peerLagUp\":%s,"
        "\"peerInterfaceKnown\":%s,\"isolationDesired\":%s,"
        "\"isolationPendingGen\":%d,"
        "\"isolationAppliedEnabled\":%s,"
        "\"isolationAppliedGen\":%d,\"trafficEnabled\":%s,"
        "\"trafficApplyPending\":\"%s\",\"ackPending\":%d,"
        "\"ackGen\":%d,\"outWireDepth\":%u,"
        "\"inWireDepth\":%u,\"inboxDepth\":%u,"
        "\"peerInboxDepth\":%u,\"txContext\":\"%s\","
        "\"txKind\":\"%s\",\"sendOutcome\":\"%s\"}}}\n",
        monotonic_ns(), event, s->nid, json_bool(arg_up), arg_version,
        json_bool(s->session_up), json_bool(s->crashed), s->disconnect_pc,
        json_bool(s->warm_announced), json_bool(s->grace_armed),
        s->grace_age, json_bool(s->cleanup_done),
        json_bool(s->recovery_pending), s->startup_pc, s->kernel_truth,
        s->observed_state, json_bool(s->snapshot_ready),
        s->advertised_state, json_bool(s->resync_pending), s->sync_epoch,
        s->sync_phase, s->outstanding_req, s->responder_epoch,
        s->sync_send_step, s->active_envelope, s->config_epoch,
        s->agg_config_epoch, s->state_epoch, s->sync_complete,
        s->dirty_version, s->peer_version, json_bool(s->envelope_violation),
        json_bool(s->config_order_violation),
        json_bool(s->legal_resync_active), s->error_reason,
        json_bool(s->scheduler_enabled), s->stream_state,
        s->session_activity, s->protocol_progress, s->heartbeat_age,
        json_bool(s->non_progress_traffic), s->ignored_app_frames,
        json_bool(s->syncd_connected), json_bool(s->syncd_fd_positive),
        s->lag_gen, json_bool(s->local_lag_up), json_bool(s->lag_dirty),
        s->peer_known_gen, json_bool(s->peer_lag_up),
        json_bool(s->peer_interface_known), json_bool(s->isolation_desired),
        s->isolation_pending_gen, json_bool(s->isolation_applied_enabled),
        s->isolation_applied_gen, json_bool(s->traffic_enabled),
        s->traffic_apply_pending, s->ack_pending, s->ack_gen,
        wire[i].len, wire[peer].len, inbox[i].len, inbox[peer].len,
        s->tx_context, s->tx_kind, s->send_outcome);
    fflush(trace_fp);
}

static void begin_disconnect(struct tla_node_state *s)
{
    s->session_up = false;
    copy_text(s->disconnect_pc, sizeof(s->disconnect_pc), "Detected");
    s->cleanup_done = false;
    s->recovery_pending = true;
    s->scheduler_enabled = true;
    copy_text(s->stream_state, sizeof(s->stream_state), "Idle");
}

static bool consume_inbox(int i, struct tla_frame *frame)
{
    return queue_pop(&inbox[i], frame);
}

static void apply_event(int i, const char *event, bool bool_arg,
                        int int_arg)
{
    struct tla_node_state *s = &nodes[i];
    struct tla_frame f;
    int peer = 1 - i;

    if (strcmp(event, "mlacp_fsm_update_warmboot") == 0) {
        consume_inbox(i, &f);
        s->warm_announced = true;
        s->protocol_progress = bounded_inc(s->protocol_progress);
    } else if (strcmp(event, "scheduler_session_disconnect_handler") == 0) {
        begin_disconnect(s);
    } else if (strcmp(event, "mlacp_peer_disconn_handler_Grace") == 0) {
        s->warm_announced = false;
        s->grace_armed = true;
        s->grace_age = 0;
        copy_text(s->disconnect_pc, sizeof(s->disconnect_pc), "Handled");
    } else if (strcmp(event, "mlacp_peer_disconn_handler_Cleanup") == 0) {
        s->cleanup_done = true;
        s->recovery_pending = false;
        copy_text(s->disconnect_pc, sizeof(s->disconnect_pc), "Handled");
        s->advertised_state = -1;
        s->isolation_desired = false;
        s->isolation_pending_gen = -1;
        s->traffic_enabled = true;
        copy_text(s->traffic_apply_pending,
                  sizeof(s->traffic_apply_pending), "None");
    } else if (strcmp(event, "iccp_csm_status_reset") == 0) {
        int n;
        copy_text(s->disconnect_pc, sizeof(s->disconnect_pc), "Idle");
        s->warm_announced = false;
        s->grace_armed = false;
        s->grace_age = 0;
        copy_text(s->sync_phase, sizeof(s->sync_phase), "Init");
        s->outstanding_req = -1;
        s->responder_epoch = -1;
        copy_text(s->sync_send_step, sizeof(s->sync_send_step), "Idle");
        s->active_envelope = -1;
        s->legal_resync_active = false;
        for (n = 0; n < TLA_NODE_COUNT; n++) {
            queue_clear(&wire[n]);
            queue_clear(&inbox[n]);
        }
        s->tx_pending = false;
        copy_text(s->tx_context, sizeof(s->tx_context), "None");
        copy_text(s->tx_kind, sizeof(s->tx_kind), "None");
        copy_text(s->send_outcome, sizeof(s->send_outcome), "None");
        s->disconnect_prelogged = false;
    } else if (strcmp(event, "mlacp_fsm_transit_WarmTimeout") == 0) {
        s->grace_armed = false;
        s->grace_age = 0;
        s->cleanup_done = true;
        s->recovery_pending = false;
    } else if (strcmp(event, "system_finalize_Crash") == 0) {
        int n;
        s->crashed = true;
        s->session_up = false;
        s->warm_announced = false;
        s->grace_armed = false;
        s->grace_age = 0;
        copy_text(s->disconnect_pc, sizeof(s->disconnect_pc), "Idle");
        copy_text(s->startup_pc, sizeof(s->startup_pc), "NeedNeighborDump");
        s->snapshot_ready = false;
        s->advertised_state = -1;
        copy_text(s->sync_phase, sizeof(s->sync_phase), "Init");
        s->outstanding_req = -1;
        s->responder_epoch = -1;
        copy_text(s->sync_send_step, sizeof(s->sync_send_step), "Idle");
        s->active_envelope = -1;
        s->dirty_version = -1;
        s->scheduler_enabled = false;
        copy_text(s->stream_state, sizeof(s->stream_state), "Idle");
        s->syncd_connected = false;
        s->syncd_fd_positive = false;
        for (n = 0; n < TLA_NODE_COUNT; n++) {
            queue_clear(&wire[n]);
            queue_clear(&inbox[n]);
        }
        s->tx_pending = false;
        copy_text(s->tx_context, sizeof(s->tx_context), "None");
        copy_text(s->tx_kind, sizeof(s->tx_kind), "None");
        copy_text(s->send_outcome, sizeof(s->send_outcome), "None");
    } else if (strcmp(event, "scheduler_init_Restart") == 0) {
        s->crashed = false;
        s->session_up = false;
        copy_text(s->startup_pc, sizeof(s->startup_pc), "NeedNeighborDump");
        s->observed_state = 0;
        s->snapshot_ready = false;
        s->advertised_state = -1;
        s->cleanup_done = false;
        s->scheduler_enabled = true;
        copy_text(s->stream_state, sizeof(s->stream_state), "Idle");
        s->heartbeat_age = 0;
    } else if (strcmp(event, "iccp_neigh_get_init") == 0) {
        s->observed_state = s->snapshot_ready ? s->kernel_truth : 0;
        copy_text(s->startup_pc, sizeof(s->startup_pc), "NeighborDumped");
    } else if (strcmp(event,
                      "iccp_mclagsyncd_vlan_mbr_update_handler") == 0) {
        s->snapshot_ready = true;
        copy_text(s->startup_pc, sizeof(s->startup_pc), "Running");
    } else if (strcmp(event, "do_arp_learn_from_kernel") == 0) {
        s->observed_state = s->kernel_truth;
        s->dirty_version = s->kernel_truth;
    } else if (strcmp(event, "iccp_netlink_ObjectUpdate") == 0) {
        s->kernel_truth = int_arg;
        s->observed_state = int_arg;
        s->dirty_version = int_arg;
    } else if (strcmp(event,
                      "iccp_netlink_route_sock_event_handler_Error") == 0) {
        s->resync_pending = true;
    } else if (strcmp(event, "iccp_netlink_sync_again") == 0) {
        s->resync_pending = false;
    } else if (strcmp(event, "iccp_csm_transit_Reconnect") == 0) {
        s->session_up = true;
        s->recovery_pending = false;
        copy_text(s->sync_phase, sizeof(s->sync_phase), "Stage1");
        s->outstanding_req = -1;
        s->responder_epoch = -1;
        copy_text(s->sync_send_step, sizeof(s->sync_send_step), "Idle");
        s->active_envelope = -1;
        s->dirty_version = s->observed_state;
        copy_text(s->error_reason, sizeof(s->error_reason), "None");
        s->heartbeat_age = 0;
    } else if (strcmp(event, "mlacp_sync_recv_syncReq") == 0) {
        if (consume_inbox(i, &f)) {
            s->responder_epoch = f.epoch;
            copy_text(s->sync_send_step, sizeof(s->sync_send_step), "Start");
            s->legal_resync_active = strcmp(s->sync_phase, "Exchange") == 0;
        }
        s->protocol_progress = bounded_inc(s->protocol_progress);
    } else if (strcmp(event, "mlacp_sync_sender_handler_SkipObject") == 0) {
        copy_text(s->sync_send_step, sizeof(s->sync_send_step), "End");
    } else if (strcmp(event, "mlacp_sync_recv_syncData_Start") == 0) {
        if (consume_inbox(i, &f)) {
            s->active_envelope = f.epoch;
            s->config_epoch = -1;
            s->agg_config_epoch = -1;
            s->state_epoch = -1;
            s->envelope_violation = s->envelope_violation ||
                s->outstanding_req < 0 || s->outstanding_req != f.epoch;
        }
        s->protocol_progress = bounded_inc(s->protocol_progress);
    } else if (strcmp(event, "mlacp_sync_recv_sysConf") == 0) {
        if (consume_inbox(i, &f)) {
            s->config_epoch = f.epoch;
            s->envelope_violation = s->envelope_violation ||
                s->active_envelope != f.epoch;
        }
        s->protocol_progress = bounded_inc(s->protocol_progress);
    } else if (strcmp(event, "mlacp_sync_recv_aggConf") == 0) {
        if (consume_inbox(i, &f)) {
            s->agg_config_epoch = f.epoch;
            s->envelope_violation = s->envelope_violation ||
                s->active_envelope != f.epoch;
        }
        s->protocol_progress = bounded_inc(s->protocol_progress);
    } else if (strcmp(event, "mlacp_sync_recv_aggState") == 0) {
        if (consume_inbox(i, &f)) {
            s->state_epoch = f.epoch;
            s->envelope_violation = s->envelope_violation ||
                s->active_envelope != f.epoch;
            s->config_order_violation = s->config_order_violation ||
                s->config_epoch != f.epoch ||
                s->agg_config_epoch != f.epoch;
        }
        s->protocol_progress = bounded_inc(s->protocol_progress);
    } else if (strcmp(event, "mlacp_sync_recv_ObjectData") == 0) {
        if (consume_inbox(i, &f)) {
            s->peer_version = f.version;
            s->envelope_violation = s->envelope_violation ||
                s->active_envelope != f.epoch;
        }
        s->protocol_progress = bounded_inc(s->protocol_progress);
    } else if (strcmp(event, "mlacp_sync_recv_syncData_End") == 0) {
        if (consume_inbox(i, &f)) {
            int old_outstanding = s->outstanding_req;
            s->sync_complete = old_outstanding >= 0 ? old_outstanding : f.epoch;
            s->outstanding_req = -1;
            s->envelope_violation = s->envelope_violation ||
                old_outstanding < 0 || s->active_envelope != f.epoch ||
                old_outstanding != f.epoch;
            s->active_envelope = -1;
            if (strcmp(s->sync_phase, "Stage1") == 0 ||
                strcmp(s->sync_phase, "Stage2") == 0)
                copy_text(s->sync_phase, sizeof(s->sync_phase),
                          next_phase(s->sync_phase));
        }
        s->protocol_progress = bounded_inc(s->protocol_progress);
    } else if (strcmp(event, "mlacp_portchannel_state_handler") == 0) {
        s->lag_gen++;
        s->local_lag_up = bool_arg;
        s->lag_dirty = true;
        if (bool_arg) {
            s->isolation_desired = s->peer_lag_up;
            if (s->peer_lag_up)
                s->isolation_pending_gen = s->lag_gen;
        } else {
            copy_text(s->traffic_apply_pending,
                      sizeof(s->traffic_apply_pending), "Disable");
            s->ack_gen = -1;
        }
    } else if (strcmp(event, "mlacp_fsm_update_Aggport_state") == 0) {
        if (consume_inbox(i, &f)) {
            if (s->peer_interface_known) {
                s->peer_known_gen = f.generation;
                s->peer_lag_up = f.up;
                if (s->local_lag_up) {
                    s->isolation_desired = f.up;
                    s->isolation_pending_gen = f.generation;
                }
            }
            if (f.up)
                s->ack_pending = f.generation;
        }
        s->protocol_progress = bounded_inc(s->protocol_progress);
    } else if (strcmp(event,
                      "update_peerlink_isolate_from_all_csm_lif_Apply") == 0) {
        s->isolation_applied_enabled = s->isolation_desired;
        s->isolation_applied_gen = s->isolation_pending_gen;
        s->isolation_pending_gen = -1;
    } else if (strcmp(event,
                      "update_peerlink_isolate_from_all_csm_lif_Fail") == 0) {
        s->isolation_pending_gen = -1;
    } else if (strcmp(event, "mlacp_fsm_recv_if_up_ack") == 0) {
        if (consume_inbox(i, &f)) {
            s->ack_gen = f.generation;
            if (s->local_lag_up)
                copy_text(s->traffic_apply_pending,
                          sizeof(s->traffic_apply_pending), "Enable");
        }
        s->protocol_progress = bounded_inc(s->protocol_progress);
    } else if (strcmp(event,
                      "mlacp_link_disable_traffic_distribution_Success") == 0) {
        s->traffic_enabled = false;
        copy_text(s->traffic_apply_pending,
                  sizeof(s->traffic_apply_pending), "None");
    } else if (strcmp(event,
                      "mlacp_link_disable_traffic_distribution_Fail") == 0 ||
               strcmp(event,
                      "mlacp_link_enable_traffic_distribution_Fail") == 0) {
        copy_text(s->traffic_apply_pending,
                  sizeof(s->traffic_apply_pending), "None");
    } else if (strcmp(event,
                      "mlacp_link_enable_traffic_distribution_Success") == 0) {
        s->traffic_enabled = true;
        copy_text(s->traffic_apply_pending,
                  sizeof(s->traffic_apply_pending), "None");
    } else if (strcmp(event, "mlacp_peer_mlag_intf_delete_handler") == 0) {
        s->peer_interface_known = false;
    } else if (strcmp(event, "mlacp_fsm_update_Agg_conf") == 0) {
        s->peer_interface_known = true;
    } else if (strcmp(event,
                      "scheduler_csm_read_callback_Complete") == 0) {
        if (queue_pop(&wire[peer], &f))
            queue_push(&inbox[i], &f);
        s->session_activity = bounded_inc(s->session_activity);
        s->heartbeat_age = 0;
        copy_text(s->stream_state, sizeof(s->stream_state), "Idle");
    } else if (strcmp(event,
                      "scheduler_csm_read_callback_Corrupt") == 0) {
        queue_pop(&wire[peer], &f);
        s->scheduler_enabled = false;
        copy_text(s->stream_state, sizeof(s->stream_state), "BodyRetry");
    } else if (strcmp(event,
                      "scheduler_csm_read_callback_PartialHeader") == 0) {
        s->scheduler_enabled = false;
        copy_text(s->stream_state, sizeof(s->stream_state), "PartialHeader");
    } else if (strcmp(event,
                      "scheduler_csm_read_callback_ReadError") == 0) {
        begin_disconnect(s);
        s->disconnect_prelogged = true;
    } else if (strcmp(event,
                      "app_csm_EnableNonProgressTraffic") == 0) {
        s->non_progress_traffic = true;
    } else if (strcmp(event, "iccp_csm_send_NonProgress") == 0) {
        memset(&f, 0, sizeof(f));
        copy_text(f.kind, sizeof(f.kind), "NonProgress");
        f.epoch = f.version = f.generation = -1;
        f.valid = true;
        queue_push(&wire[i], &f);
    } else if (strcmp(event, "app_csm_enqueue_msg_NonProgress") == 0) {
        consume_inbox(i, &f);
        s->ignored_app_frames = bounded_inc(s->ignored_app_frames);
    } else if (strcmp(event, "scheduler_transit_fsm_Tick") == 0) {
        if (s->heartbeat_age < 4)
            s->heartbeat_age++;
        if (s->grace_armed && s->grace_age < 4)
            s->grace_age++;
    } else if (strcmp(event, "heartbeat_check") == 0) {
        begin_disconnect(s);
        s->disconnect_prelogged = true;
    } else if (strcmp(event, "iccp_mclagsyncd_msg_handler_EOF") == 0) {
        s->syncd_connected = false;
        s->syncd_fd_positive = true;
    } else if (strcmp(event, "scheduler_loop_ReconnectSyncd") == 0) {
        s->syncd_connected = true;
        s->syncd_fd_positive = true;
    }
}

static void prepare_locked(int i, const char *event, const char *context,
                           const char *kind, int version, int generation,
                           bool up)
{
    struct tla_node_state *s = &nodes[i];

    refresh_actual(s);
    memset(&s->tx_frame, 0, sizeof(s->tx_frame));
    copy_text(s->tx_frame.kind, sizeof(s->tx_frame.kind), kind);
    s->tx_frame.epoch = -1;
    s->tx_frame.version = version;
    s->tx_frame.generation = generation;
    s->tx_frame.up = up;
    s->tx_frame.valid = true;

    if (strcmp(event, "mlacp_stage_sync_request_handler") == 0 ||
        strcmp(event, "mlacp_exchange_handler_PrepareResync") == 0) {
        s->sync_epoch++;
        s->outstanding_req = s->sync_epoch;
        s->tx_frame.epoch = s->sync_epoch;
        s->resync_pending = false;
    } else if (strcmp(event,
                      "mlacp_sync_send_all_info_handler_Prepare") == 0) {
        s->tx_frame.epoch = s->responder_epoch;
        if (strcmp(kind, "ObjectData") == 0) {
            s->tx_frame.version = s->dirty_version;
            s->dirty_version = -1;
        }
    } else if (strcmp(event,
                      "mlacp_exchange_handler_PreparePortState") == 0) {
        s->tx_frame.generation = s->lag_gen;
        s->tx_frame.up = s->local_lag_up;
    } else if (strcmp(event, "mlacp_fsm_send_if_up_ack") == 0) {
        s->tx_frame.generation = s->ack_pending;
        s->tx_frame.up = true;
        s->ack_pending = -1;
    }

    s->tx_pending = true;
    copy_text(s->tx_context, sizeof(s->tx_context), context);
    copy_text(s->tx_kind, sizeof(s->tx_kind), kind);
    copy_text(s->send_outcome, sizeof(s->send_outcome), "None");
    emit_event(i, event, false, -1);
}

static void finish_send_locked(int i, ssize_t rc, size_t expected)
{
    struct tla_node_state *s = &nodes[i];
    const char *outcome;
    bool positive;

    if (!s->tx_pending || expected == 0)
        return;
    refresh_actual(s);

    if (rc == (ssize_t)expected)
        outcome = "Full";
    else if (rc > 0)
        outcome = "Partial";
    else
        outcome = "Failed";
    positive = rc > 0;

    if (strcmp(outcome, "Full") == 0) {
        s->tx_frame.valid = true;
        queue_push(&wire[i], &s->tx_frame);
    } else if (strcmp(outcome, "Partial") == 0) {
        s->tx_frame.valid = false;
        queue_push(&wire[i], &s->tx_frame);
    }

    if (strcmp(s->tx_context, "SyncResponse") == 0) {
        bool is_end = strcmp(s->tx_frame.kind, "SyncEnd") == 0;
        const char *old_phase = s->sync_phase;
        copy_text(s->sync_send_step, sizeof(s->sync_send_step),
                  next_send_step(s->sync_send_step));
        if (is_end) {
            s->sync_complete = s->responder_epoch;
            if (strcmp(old_phase, "Exchange") == 0) {
                copy_text(s->sync_phase, sizeof(s->sync_phase), "Error");
                copy_text(s->error_reason, sizeof(s->error_reason),
                          "LegalResyncAdvance");
            } else {
                copy_text(s->sync_phase, sizeof(s->sync_phase),
                          next_phase(old_phase));
                s->legal_resync_active = false;
            }
        }
        if (strcmp(s->tx_frame.kind, "ObjectData") == 0 && positive)
            s->advertised_state = s->tx_frame.version;
    }
    if (strcmp(s->tx_context, "PortState") == 0 && positive)
        s->lag_dirty = false;

    copy_text(s->send_outcome, sizeof(s->send_outcome), outcome);
    s->tx_pending = false;
    copy_text(s->tx_context, sizeof(s->tx_context), "None");
    copy_text(s->tx_kind, sizeof(s->tx_kind), "None");

    if (strcmp(outcome, "Full") == 0)
        emit_event(i, "iccp_csm_send_Full", false, -1);
    else if (strcmp(outcome, "Partial") == 0)
        emit_event(i, "iccp_csm_send_Partial", false, -1);
    else
        emit_event(i, "iccp_csm_send_Failed", false, -1);
}

int tla_trace_open(const char *path, struct CSM *n1, struct CSM *n2)
{
    int rc = 0;

    pthread_mutex_lock(&trace_mu);
    if (trace_fp) {
        fflush(trace_fp);
        fclose(trace_fp);
        trace_fp = NULL;
    }
    trace_fp = fopen(path, "w");
    if (!trace_fp) {
        rc = -1;
    } else {
        setvbuf(trace_fp, NULL, _IOLBF, 0);
        init_node(&nodes[0], n1, "n1");
        init_node(&nodes[1], n2, "n2");
        queue_clear(&wire[0]);
        queue_clear(&wire[1]);
        queue_clear(&inbox[0]);
        queue_clear(&inbox[1]);
    }
    pthread_mutex_unlock(&trace_mu);
    return rc;
}

void tla_trace_close(void)
{
    pthread_mutex_lock(&trace_mu);
    if (trace_fp) {
        fflush(trace_fp);
        fclose(trace_fp);
        trace_fp = NULL;
    }
    pthread_mutex_unlock(&trace_mu);
}

bool tla_trace_is_open(void)
{
    bool open;
    pthread_mutex_lock(&trace_mu);
    open = trace_fp != NULL;
    pthread_mutex_unlock(&trace_mu);
    return open;
}

void tla_trace_register_lag(struct CSM *csm, struct LocalInterface *lif,
                            struct PeerInterface *pif)
{
    int i;
    pthread_mutex_lock(&trace_mu);
    i = node_index(csm);
    if (i >= 0) {
        nodes[i].lif = lif;
        nodes[i].pif = pif;
        nodes[i].lag_registered = true;
        refresh_actual(&nodes[i]);
    }
    pthread_mutex_unlock(&trace_mu);
}

void tla_trace_set_write_mode(struct CSM *csm,
                              enum tla_trace_write_mode mode)
{
    int i;
    pthread_mutex_lock(&trace_mu);
    i = node_index(csm);
    if (i >= 0)
        nodes[i].write_mode = mode;
    pthread_mutex_unlock(&trace_mu);
}

ssize_t tla_trace_write(struct CSM *csm, int fd, const void *buf,
                        size_t count)
{
    enum tla_trace_write_mode mode = TLA_TRACE_WRITE_NORMAL;
    int i;

    pthread_mutex_lock(&trace_mu);
    i = node_index(csm);
    if (i >= 0) {
        mode = nodes[i].write_mode;
        nodes[i].write_mode = TLA_TRACE_WRITE_NORMAL;
    }
    pthread_mutex_unlock(&trace_mu);

    if (mode == TLA_TRACE_WRITE_FAILED) {
        errno = EIO;
        return -1;
    }
    if (mode == TLA_TRACE_WRITE_HEADER_PARTIAL && count > 4)
        return write(fd, buf, 4);
    if (mode == TLA_TRACE_WRITE_PARTIAL && count > 1)
        return write(fd, buf, count - 1);
    return write(fd, buf, count);
}

void tla_trace_prepare_event(struct CSM *csm, const char *event,
                             const char *context, const char *kind,
                             int version, int generation, bool up)
{
    int i;
    pthread_mutex_lock(&trace_mu);
    i = node_index(csm);
    if (trace_fp && i >= 0 && !nodes[i].tx_pending)
        prepare_locked(i, event, context, kind, version, generation, up);
    pthread_mutex_unlock(&trace_mu);
}

void tla_trace_record_send_result(struct CSM *csm, ssize_t rc,
                                  size_t expected)
{
    int i;
    pthread_mutex_lock(&trace_mu);
    i = node_index(csm);
    if (trace_fp && i >= 0 && nodes[i].tx_pending) {
        nodes[i].recorded_rc = rc;
        nodes[i].recorded_expected = expected;
        nodes[i].send_recorded = true;
    }
    pthread_mutex_unlock(&trace_mu);
}

void tla_trace_emit_recorded_send_result(struct CSM *csm)
{
    int i;
    pthread_mutex_lock(&trace_mu);
    i = node_index(csm);
    if (trace_fp && i >= 0 && nodes[i].send_recorded) {
        ssize_t rc = nodes[i].recorded_rc;
        size_t expected = nodes[i].recorded_expected;
        nodes[i].send_recorded = false;
        finish_send_locked(i, rc, expected);
    }
    pthread_mutex_unlock(&trace_mu);
}

void tla_trace_send_result(struct CSM *csm, ssize_t rc, size_t expected)
{
    int i;
    pthread_mutex_lock(&trace_mu);
    i = node_index(csm);
    if (trace_fp && i >= 0)
        finish_send_locked(i, rc, expected);
    pthread_mutex_unlock(&trace_mu);
}

void tla_trace_event(struct CSM *csm, const char *event)
{
    int i;
    pthread_mutex_lock(&trace_mu);
    i = node_index(csm);
    if (trace_fp && i >= 0) {
        refresh_actual(&nodes[i]);
        apply_event(i, event, false, -1);
        emit_event(i, event, false, -1);
    }
    pthread_mutex_unlock(&trace_mu);
}

void tla_trace_event_bool(struct CSM *csm, const char *event, bool value)
{
    int i;
    pthread_mutex_lock(&trace_mu);
    i = node_index(csm);
    if (trace_fp && i >= 0) {
        refresh_actual(&nodes[i]);
        apply_event(i, event, value, -1);
        emit_event(i, event, value, -1);
    }
    pthread_mutex_unlock(&trace_mu);
}

void tla_trace_event_version(struct CSM *csm, const char *event, int version)
{
    int i;
    pthread_mutex_lock(&trace_mu);
    i = node_index(csm);
    if (trace_fp && i >= 0) {
        refresh_actual(&nodes[i]);
        apply_event(i, event, false, version);
        emit_event(i, event, false, version);
    }
    pthread_mutex_unlock(&trace_mu);
}

void tla_trace_partial_header(struct CSM *csm)
{
    int i;
    pthread_mutex_lock(&trace_mu);
    i = node_index(csm);
    if (trace_fp && i >= 0 &&
        strcmp(nodes[i].stream_state, "Idle") == 0) {
        refresh_actual(&nodes[i]);
        apply_event(i, "scheduler_csm_read_callback_PartialHeader",
                    false, -1);
        emit_event(i, "scheduler_csm_read_callback_PartialHeader",
                   false, -1);
    }
    pthread_mutex_unlock(&trace_mu);
}

void tla_trace_body_retry(struct CSM *csm)
{
    struct tla_frame f;
    int i, peer;
    pthread_mutex_lock(&trace_mu);
    i = node_index(csm);
    peer = 1 - i;
    if (trace_fp && i >= 0 && queue_peek(&wire[peer], &f) && !f.valid &&
        strcmp(nodes[i].stream_state, "Idle") == 0) {
        refresh_actual(&nodes[i]);
        apply_event(i, "scheduler_csm_read_callback_Corrupt", false, -1);
        emit_event(i, "scheduler_csm_read_callback_Corrupt", false, -1);
    }
    pthread_mutex_unlock(&trace_mu);
}

void tla_trace_read_error(struct CSM *csm)
{
    int i;
    pthread_mutex_lock(&trace_mu);
    i = node_index(csm);
    if (trace_fp && i >= 0 &&
        strcmp(nodes[i].stream_state, "Idle") != 0) {
        refresh_actual(&nodes[i]);
        apply_event(i, "scheduler_csm_read_callback_ReadError", false, -1);
        emit_event(i, "scheduler_csm_read_callback_ReadError", false, -1);
    }
    pthread_mutex_unlock(&trace_mu);
}

bool tla_trace_disconnect_prelogged(struct CSM *csm)
{
    bool value = false;
    int i;
    pthread_mutex_lock(&trace_mu);
    i = node_index(csm);
    if (i >= 0)
        value = nodes[i].disconnect_prelogged;
    pthread_mutex_unlock(&trace_mu);
    return value;
}

void tla_trace_supervisor_event(struct CSM *csm, const char *event)
{
    tla_trace_event(csm, event);
}

#endif /* ICCPD_TLA_TRACE */
