/*
 * TLA+ Trace Emission Module for RedisRaft
 *
 * Outputs NDJSON lines conforming to the Trace.tla event schema.
 * Single-threaded (Redis event loop), no locking needed.
 */

#ifdef REDISRAFT_ENABLE_TRACE

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "tla_trace.h"
#include "raft.h"
#include "raft_private.h"

/* --- Server ID mapping --- */

#define MAX_SERVERS 16

typedef struct {
    raft_node_id_t impl_id;
    char tla_id[8];  /* "s1", "s2", ... */
} server_map_entry_t;

static server_map_entry_t server_map[MAX_SERVERS];
static int server_map_count = 0;

/* --- File output --- */

static FILE *trace_fp = NULL;
static int trace_active = 0;

/* --- Timestamp --- */

static long long get_timestamp_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000000000LL + (long long)ts.tv_nsec;
}

/* --- Public API --- */

void tla_trace_init(void) {
    const char *path = getenv("RAFT_TRACE_FILE");
    if (!path || path[0] == '\0') {
        trace_active = 0;
        return;
    }

    trace_fp = fopen(path, "w");
    if (!trace_fp) {
        fprintf(stderr, "tla_trace: failed to open %s\n", path);
        trace_active = 0;
        return;
    }

    trace_active = 1;
    server_map_count = 0;
}

void tla_trace_shutdown(void) {
    if (trace_fp) {
        fflush(trace_fp);
        fclose(trace_fp);
        trace_fp = NULL;
    }
    trace_active = 0;
}

int tla_trace_enabled(void) {
    return trace_active;
}

void tla_trace_register_server(raft_node_id_t impl_id, const char *tla_id) {
    if (server_map_count >= MAX_SERVERS) return;

    /* Don't register duplicates */
    for (int i = 0; i < server_map_count; i++) {
        if (server_map[i].impl_id == impl_id) return;
    }

    server_map[server_map_count].impl_id = impl_id;
    strncpy(server_map[server_map_count].tla_id, tla_id,
            sizeof(server_map[0].tla_id) - 1);
    server_map[server_map_count].tla_id[sizeof(server_map[0].tla_id) - 1] = '\0';
    server_map_count++;
}

const char *tla_trace_server_id(raft_node_id_t impl_id) {
    for (int i = 0; i < server_map_count; i++) {
        if (server_map[i].impl_id == impl_id) {
            return server_map[i].tla_id;
        }
    }
    return "";
}

/* --- Role string --- */

static const char *role_str(raft_server_t *me) {
    switch (raft_get_state(me)) {
        case RAFT_STATE_FOLLOWER:     return "Follower";
        case RAFT_STATE_PRECANDIDATE: return "Candidate";  /* map to Candidate for TLA+ */
        case RAFT_STATE_CANDIDATE:    return "Candidate";
        case RAFT_STATE_LEADER:       return "Leader";
        default:                      return "Follower";
    }
}

/* --- VotedFor string --- */

static const char *voted_for_str(raft_server_t *me) {
    raft_node_id_t vf = raft_get_voted_for(me);
    if (vf == RAFT_NODE_ID_NONE) {
        return "";
    }
    return tla_trace_server_id(vf);
}

/* --- Emit helpers --- */

static void emit_line(const char *line) {
    if (!trace_fp) return;
    fputs(line, trace_fp);
    fputc('\n', trace_fp);
    fflush(trace_fp);
}

/* Build full state JSON fragment */
static int state_full(char *buf, int bufsz, raft_server_t *me) {
    return snprintf(buf, bufsz,
        "\"state\": {\"term\": %ld, \"role\": \"%s\", \"commitIndex\": %ld, "
        "\"lastLogIndex\": %ld, \"lastLogTerm\": %ld, \"votedFor\": \"%s\"}",
        raft_get_current_term(me),
        role_str(me),
        raft_get_commit_idx(me),
        raft_get_current_idx(me),
        raft_get_last_log_term(me),
        voted_for_str(me));
}

/* Build weak state JSON fragment (term + role only) */
static int state_weak(char *buf, int bufsz, raft_server_t *me) {
    return snprintf(buf, bufsz,
        "\"state\": {\"term\": %ld, \"role\": \"%s\"}",
        raft_get_current_term(me),
        role_str(me));
}

/* Build commit state JSON fragment (term + role + commitIndex) */
static int state_commit(char *buf, int bufsz, raft_server_t *me) {
    return snprintf(buf, bufsz,
        "\"state\": {\"term\": %ld, \"role\": \"%s\", \"commitIndex\": %ld}",
        raft_get_current_term(me),
        role_str(me),
        raft_get_commit_idx(me));
}

/* --- Event emission functions --- */

void tla_trace_event(raft_server_t *me, const char *event_name) {
    if (!trace_active) return;

    char state_buf[256];
    state_full(state_buf, sizeof(state_buf), me);

    char line[512];
    snprintf(line, sizeof(line),
        "{\"tag\": \"trace\", \"ts\": \"%lld\", \"event\": {\"name\": \"%s\", "
        "\"nid\": \"%s\", %s}}",
        get_timestamp_ns(), event_name,
        tla_trace_server_id(raft_get_nodeid(me)),
        state_buf);

    emit_line(line);
}

void tla_trace_event_snapshot(raft_server_t *me, const char *event_name) {
    if (!trace_active) return;

    char state_buf[256];
    state_full(state_buf, sizeof(state_buf), me);

    char line[512];
    snprintf(line, sizeof(line),
        "{\"tag\": \"trace\", \"ts\": \"%lld\", \"event\": {\"name\": \"%s\", "
        "\"nid\": \"%s\", %s, "
        "\"snapshotIdx\": %ld, \"snapshotTerm\": %ld}}",
        get_timestamp_ns(), event_name,
        tla_trace_server_id(raft_get_nodeid(me)),
        state_buf,
        raft_get_snapshot_last_idx(me),
        raft_get_snapshot_last_term(me));

    emit_line(line);
}

void tla_trace_event_weak(raft_server_t *me, const char *event_name) {
    if (!trace_active) return;

    char state_buf[128];
    state_weak(state_buf, sizeof(state_buf), me);

    char line[384];
    snprintf(line, sizeof(line),
        "{\"tag\": \"trace\", \"ts\": \"%lld\", \"event\": {\"name\": \"%s\", "
        "\"nid\": \"%s\", %s}}",
        get_timestamp_ns(), event_name,
        tla_trace_server_id(raft_get_nodeid(me)),
        state_buf);

    emit_line(line);
}

void tla_trace_event_commit(raft_server_t *me, const char *event_name) {
    if (!trace_active) return;

    char state_buf[192];
    state_commit(state_buf, sizeof(state_buf), me);

    char line[384];
    snprintf(line, sizeof(line),
        "{\"tag\": \"trace\", \"ts\": \"%lld\", \"event\": {\"name\": \"%s\", "
        "\"nid\": \"%s\", %s}}",
        get_timestamp_ns(), event_name,
        tla_trace_server_id(raft_get_nodeid(me)),
        state_buf);

    emit_line(line);
}

void tla_trace_event_rv(raft_server_t *me, const char *event_name,
                        raft_node_id_t from, raft_node_id_t to,
                        int vote_granted) {
    if (!trace_active) return;

    char state_buf[256];
    state_full(state_buf, sizeof(state_buf), me);

    char line[512];
    snprintf(line, sizeof(line),
        "{\"tag\": \"trace\", \"ts\": \"%lld\", \"event\": {\"name\": \"%s\", "
        "\"nid\": \"%s\", %s, "
        "\"msg\": {\"from\": \"%s\", \"to\": \"%s\", \"term\": %ld, \"voteGranted\": %s}}}",
        get_timestamp_ns(), event_name,
        tla_trace_server_id(raft_get_nodeid(me)),
        state_buf,
        tla_trace_server_id(from),
        tla_trace_server_id(to),
        raft_get_current_term(me),
        vote_granted ? "true" : "false");

    emit_line(line);
}

void tla_trace_event_rv_resp_weak(raft_server_t *me, const char *event_name,
                                  raft_node_id_t from, raft_node_id_t to,
                                  int vote_granted) {
    if (!trace_active) return;

    char state_buf[128];
    state_weak(state_buf, sizeof(state_buf), me);

    char line[512];
    snprintf(line, sizeof(line),
        "{\"tag\": \"trace\", \"ts\": \"%lld\", \"event\": {\"name\": \"%s\", "
        "\"nid\": \"%s\", %s, "
        "\"msg\": {\"from\": \"%s\", \"to\": \"%s\", \"voteGranted\": %s}}}",
        get_timestamp_ns(), event_name,
        tla_trace_server_id(raft_get_nodeid(me)),
        state_buf,
        tla_trace_server_id(from),
        tla_trace_server_id(to),
        vote_granted ? "true" : "false");

    emit_line(line);
}

void tla_trace_event_ae_req(raft_server_t *me, const char *event_name,
                            raft_node_id_t from, raft_node_id_t to,
                            raft_term_t msg_term,
                            raft_index_t prev_log_idx, raft_term_t prev_log_term,
                            raft_index_t leader_commit) {
    if (!trace_active) return;

    char state_buf[256];
    state_full(state_buf, sizeof(state_buf), me);

    char line[640];
    snprintf(line, sizeof(line),
        "{\"tag\": \"trace\", \"ts\": \"%lld\", \"event\": {\"name\": \"%s\", "
        "\"nid\": \"%s\", %s, "
        "\"msg\": {\"from\": \"%s\", \"to\": \"%s\", \"term\": %ld, "
        "\"prevLogIndex\": %ld, \"prevLogTerm\": %ld, \"leaderCommit\": %ld}}}",
        get_timestamp_ns(), event_name,
        tla_trace_server_id(raft_get_nodeid(me)),
        state_buf,
        tla_trace_server_id(from),
        tla_trace_server_id(to),
        msg_term,
        prev_log_idx, prev_log_term,
        leader_commit);

    emit_line(line);
}

void tla_trace_event_ae_resp_weak(raft_server_t *me, const char *event_name,
                                  raft_node_id_t from, raft_node_id_t to,
                                  int success, raft_index_t match_index) {
    if (!trace_active) return;

    char state_buf[128];
    state_weak(state_buf, sizeof(state_buf), me);

    char line[512];
    snprintf(line, sizeof(line),
        "{\"tag\": \"trace\", \"ts\": \"%lld\", \"event\": {\"name\": \"%s\", "
        "\"nid\": \"%s\", %s, "
        "\"msg\": {\"from\": \"%s\", \"to\": \"%s\", \"success\": %s, \"matchIndex\": %ld}}}",
        get_timestamp_ns(), event_name,
        tla_trace_server_id(raft_get_nodeid(me)),
        state_buf,
        tla_trace_server_id(from),
        tla_trace_server_id(to),
        success ? "true" : "false",
        match_index);

    emit_line(line);
}

void tla_trace_event_is_req_weak(raft_server_t *me, const char *event_name,
                                 raft_node_id_t from, raft_node_id_t to,
                                 raft_index_t snap_idx, raft_term_t snap_term) {
    if (!trace_active) return;

    char state_buf[128];
    state_weak(state_buf, sizeof(state_buf), me);

    char line[512];
    snprintf(line, sizeof(line),
        "{\"tag\": \"trace\", \"ts\": \"%lld\", \"event\": {\"name\": \"%s\", "
        "\"nid\": \"%s\", %s, "
        "\"msg\": {\"from\": \"%s\", \"to\": \"%s\", \"snapIdx\": %ld, \"snapTerm\": %ld}}}",
        get_timestamp_ns(), event_name,
        tla_trace_server_id(raft_get_nodeid(me)),
        state_buf,
        tla_trace_server_id(from),
        tla_trace_server_id(to),
        snap_idx, snap_term);

    emit_line(line);
}

void tla_trace_event_config(raft_server_t *me, const char *event_name,
                            raft_node_id_t target) {
    if (!trace_active) return;

    char state_buf[256];
    state_full(state_buf, sizeof(state_buf), me);

    char line[512];
    snprintf(line, sizeof(line),
        "{\"tag\": \"trace\", \"ts\": \"%lld\", \"event\": {\"name\": \"%s\", "
        "\"nid\": \"%s\", %s, "
        "\"target\": \"%s\"}}",
        get_timestamp_ns(), event_name,
        tla_trace_server_id(raft_get_nodeid(me)),
        state_buf,
        tla_trace_server_id(target));

    emit_line(line);
}

void tla_trace_emit_config(raft_server_t *me) {
    if (!trace_active) return;

    /* Build servers array string */
    char servers[128] = "[";
    for (int i = 0; i < server_map_count; i++) {
        if (i > 0) strcat(servers, ", ");
        strcat(servers, "\"");
        strcat(servers, server_map[i].tla_id);
        strcat(servers, "\"");
    }
    strcat(servers, "]");

    char line[256];
    snprintf(line, sizeof(line),
        "{\"tag\": \"config\", \"ts\": \"%lld\", \"config\": {\"servers\": %s}}",
        get_timestamp_ns(), servers);

    emit_line(line);
}

#endif /* REDISRAFT_ENABLE_TRACE */
