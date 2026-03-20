/**
 * TLA+ Trace Emission Module for willemt/raft
 *
 * Emits NDJSON trace events from the instrumented raft library.
 * Each event line is consumed by Trace.tla for trace validation.
 */

#ifndef TLA_TRACE_H
#define TLA_TRACE_H

#include <stdlib.h>
#include "raft.h"

/* Initialize trace output. Returns 0 on success, -1 on failure. */
int tla_trace_init(const char* filename);

/* Flush and close trace file. */
void tla_trace_close(void);

/* Returns 1 if tracing is active, 0 otherwise. */
int tla_trace_enabled(void);

/* --- Node events (Timeout, TakeSnapshot) --- */
void tla_emit_node_event(raft_server_t* raft, const char* event);

/* --- ClientRequest --- */
void tla_emit_client_request(raft_server_t* raft, const char* value);

/* --- HandleRequestVoteRequest --- */
void tla_emit_rv_request(raft_server_t* raft, int from_id,
                         msg_requestvote_t* vr,
                         msg_requestvote_response_t* r);

/* --- HandleRequestVoteResponse --- */
void tla_emit_rv_response(raft_server_t* raft, int from_id,
                          msg_requestvote_response_t* r);

/* --- SendAppendEntries --- */
void tla_emit_send_ae(raft_server_t* raft, int to_id,
                      msg_appendentries_t* ae);

/* --- HandleAppendEntriesRequest --- */
void tla_emit_ae_request(raft_server_t* raft, int from_id,
                         msg_appendentries_t* ae,
                         msg_appendentries_response_t* r);

/* --- HandleAppendEntriesResponse --- */
void tla_emit_ae_response(raft_server_t* raft, int from_id,
                          msg_appendentries_response_t* r);

/* --- SendInstallSnapshot --- */
void tla_emit_send_snapshot(raft_server_t* raft, int to_id,
                            long snapshot_last_idx,
                            long snapshot_last_term);

/* --- HandleInstallSnapshot (emitted from test harness) --- */
void tla_emit_install_snapshot(raft_server_t* raft, int from_id,
                               long snapshot_last_idx,
                               long snapshot_last_term);

/* --- Crash (no post state) --- */
void tla_emit_crash(int node_id);

/* --- Recover (with post state) --- */
void tla_emit_recover(raft_server_t* raft);

#endif /* TLA_TRACE_H */
