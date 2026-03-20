/**
 * TLA+ Trace Emission Module for willemt/raft
 *
 * Writes NDJSON lines to a trace file. Each line is one protocol event
 * matching the schema expected by Trace.tla.
 */

#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include "tla_trace.h"
#include "raft.h"

static FILE* trace_fp = NULL;

int tla_trace_init(const char* filename)
{
    if (trace_fp) return 0;
    trace_fp = fopen(filename, "w");
    return trace_fp ? 0 : -1;
}

void tla_trace_close(void)
{
    if (trace_fp) {
        fflush(trace_fp);
        fclose(trace_fp);
        trace_fp = NULL;
    }
}

int tla_trace_enabled(void)
{
    return trace_fp != NULL;
}

/* Real monotonic timestamp in nanoseconds */
static long long get_ts_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

/* Map raft state enum to spec string */
static const char* state_str(int state)
{
    switch (state) {
        case 1: return "follower";   /* RAFT_STATE_FOLLOWER */
        case 2: return "candidate";  /* RAFT_STATE_CANDIDATE */
        case 3: return "leader";     /* RAFT_STATE_LEADER */
        default: return "unknown";
    }
}

/* Write post-state JSON fragment (no surrounding braces for the event) */
static void write_post(FILE* fp, raft_server_t* raft)
{
    fprintf(fp, "\"post\":{\"term\":%ld,\"state\":\"%s\","
                "\"commitIndex\":%ld,\"lastLogIndex\":%ld,\"lastLogTerm\":%ld}",
            raft_get_current_term(raft),
            state_str(raft_get_state(raft)),
            raft_get_commit_idx(raft),
            raft_get_current_idx(raft),
            raft_get_last_log_term(raft));
}

/* Write timestamp and close the JSON line */
static void write_ts_close(FILE* fp)
{
    fprintf(fp, ",\"ts\":\"%lld\"}\n", get_ts_ns());
    fflush(fp);
}

/* ---- Public emit functions ---- */

void tla_emit_node_event(raft_server_t* raft, const char* event)
{
    if (!trace_fp) return;
    int nid = raft_get_nodeid(raft);
    fprintf(trace_fp, "{\"tag\":\"trace\",\"event\":\"%s\",\"node\":\"s%d\",",
            event, nid);
    write_post(trace_fp, raft);
    write_ts_close(trace_fp);
}

void tla_emit_client_request(raft_server_t* raft, const char* value)
{
    if (!trace_fp) return;
    int nid = raft_get_nodeid(raft);
    fprintf(trace_fp, "{\"tag\":\"trace\",\"event\":\"ClientRequest\","
                      "\"node\":\"s%d\",\"value\":\"%s\",",
            nid, value);
    write_post(trace_fp, raft);
    write_ts_close(trace_fp);
}

void tla_emit_rv_request(raft_server_t* raft, int from_id,
                         msg_requestvote_t* vr,
                         msg_requestvote_response_t* r)
{
    if (!trace_fp) return;
    int my_id = raft_get_nodeid(raft);
    fprintf(trace_fp, "{\"tag\":\"trace\",\"event\":\"HandleRequestVoteRequest\","
                      "\"node\":\"s%d\",\"from\":\"s%d\",\"to\":\"s%d\","
                      "\"msg\":{\"term\":%ld,\"candidateId\":\"s%d\","
                      "\"lastLogIdx\":%ld,\"lastLogTerm\":%ld,"
                      "\"voteGranted\":%d},",
            my_id, from_id, my_id,
            vr->term, vr->candidate_id,
            vr->last_log_idx, vr->last_log_term,
            r->vote_granted);
    write_post(trace_fp, raft);
    write_ts_close(trace_fp);
}

void tla_emit_rv_response(raft_server_t* raft, int from_id,
                          msg_requestvote_response_t* r)
{
    if (!trace_fp) return;
    int my_id = raft_get_nodeid(raft);
    fprintf(trace_fp, "{\"tag\":\"trace\",\"event\":\"HandleRequestVoteResponse\","
                      "\"node\":\"s%d\",\"from\":\"s%d\",\"to\":\"s%d\","
                      "\"msg\":{\"term\":%ld,\"voteGranted\":%d},",
            my_id, from_id, my_id,
            r->term, r->vote_granted);
    write_post(trace_fp, raft);
    write_ts_close(trace_fp);
}

void tla_emit_send_ae(raft_server_t* raft, int to_id,
                      msg_appendentries_t* ae)
{
    if (!trace_fp) return;
    int my_id = raft_get_nodeid(raft);
    fprintf(trace_fp, "{\"tag\":\"trace\",\"event\":\"SendAppendEntries\","
                      "\"node\":\"s%d\",\"from\":\"s%d\",\"to\":\"s%d\","
                      "\"msg\":{\"term\":%ld,\"prevLogIdx\":%ld,"
                      "\"prevLogTerm\":%ld,\"leaderCommit\":%ld,"
                      "\"nEntries\":%d}",
            my_id, my_id, to_id,
            ae->term, ae->prev_log_idx,
            ae->prev_log_term, ae->leader_commit,
            ae->n_entries);
    write_ts_close(trace_fp);
}

void tla_emit_ae_request(raft_server_t* raft, int from_id,
                         msg_appendentries_t* ae,
                         msg_appendentries_response_t* r)
{
    if (!trace_fp) return;
    int my_id = raft_get_nodeid(raft);
    fprintf(trace_fp, "{\"tag\":\"trace\",\"event\":\"HandleAppendEntriesRequest\","
                      "\"node\":\"s%d\",\"from\":\"s%d\",\"to\":\"s%d\","
                      "\"msg\":{\"term\":%ld,\"prevLogIdx\":%ld,"
                      "\"prevLogTerm\":%ld,\"leaderCommit\":%ld,"
                      "\"nEntries\":%d,\"success\":%d,\"currentIdx\":%ld},",
            my_id, from_id, my_id,
            ae->term, ae->prev_log_idx,
            ae->prev_log_term, ae->leader_commit,
            ae->n_entries, r->success, r->current_idx);
    write_post(trace_fp, raft);
    write_ts_close(trace_fp);
}

void tla_emit_ae_response(raft_server_t* raft, int from_id,
                          msg_appendentries_response_t* r)
{
    if (!trace_fp) return;
    int my_id = raft_get_nodeid(raft);
    fprintf(trace_fp, "{\"tag\":\"trace\",\"event\":\"HandleAppendEntriesResponse\","
                      "\"node\":\"s%d\",\"from\":\"s%d\",\"to\":\"s%d\","
                      "\"msg\":{\"term\":%ld,\"success\":%d,"
                      "\"currentIdx\":%ld,\"firstIdx\":%ld},",
            my_id, from_id, my_id,
            r->term, r->success,
            r->current_idx, r->first_idx);
    write_post(trace_fp, raft);
    write_ts_close(trace_fp);
}

void tla_emit_send_snapshot(raft_server_t* raft, int to_id,
                            long snapshot_last_idx,
                            long snapshot_last_term)
{
    if (!trace_fp) return;
    int my_id = raft_get_nodeid(raft);
    fprintf(trace_fp, "{\"tag\":\"trace\",\"event\":\"SendInstallSnapshot\","
                      "\"node\":\"s%d\",\"from\":\"s%d\",\"to\":\"s%d\","
                      "\"msg\":{\"snapshotLastIdx\":%ld,\"snapshotLastTerm\":%ld}",
            my_id, my_id, to_id,
            snapshot_last_idx, snapshot_last_term);
    write_ts_close(trace_fp);
}

void tla_emit_install_snapshot(raft_server_t* raft, int from_id,
                               long snapshot_last_idx,
                               long snapshot_last_term)
{
    if (!trace_fp) return;
    int my_id = raft_get_nodeid(raft);
    fprintf(trace_fp, "{\"tag\":\"trace\",\"event\":\"HandleInstallSnapshot\","
                      "\"node\":\"s%d\",\"from\":\"s%d\",\"to\":\"s%d\","
                      "\"msg\":{\"snapshotLastIdx\":%ld,\"snapshotLastTerm\":%ld},",
            my_id, from_id, my_id,
            snapshot_last_idx, snapshot_last_term);
    write_post(trace_fp, raft);
    write_ts_close(trace_fp);
}

void tla_emit_crash(int node_id)
{
    if (!trace_fp) return;
    fprintf(trace_fp, "{\"tag\":\"trace\",\"event\":\"Crash\","
                      "\"node\":\"s%d\"", node_id);
    write_ts_close(trace_fp);
}

void tla_emit_recover(raft_server_t* raft)
{
    if (!trace_fp) return;
    int nid = raft_get_nodeid(raft);
    fprintf(trace_fp, "{\"tag\":\"trace\",\"event\":\"Recover\","
                      "\"node\":\"s%d\",", nid);
    write_post(trace_fp, raft);
    write_ts_close(trace_fp);
}
