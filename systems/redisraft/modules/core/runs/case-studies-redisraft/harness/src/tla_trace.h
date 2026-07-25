/*
 * TLA+ Trace Emission Module for RedisRaft
 *
 * Emits NDJSON trace events for TLA+ trace validation.
 * Compile with -DREDISRAFT_ENABLE_TRACE to enable.
 * Set RAFT_TRACE_FILE env var to output path.
 */

#ifndef TLA_TRACE_H
#define TLA_TRACE_H

#include "raft.h"

#ifdef REDISRAFT_ENABLE_TRACE

/* Initialize trace system. Call once at startup.
 * Opens the file specified by RAFT_TRACE_FILE env var.
 * If env var is not set, tracing is disabled. */
void tla_trace_init(void);

/* Shutdown trace system. Flush and close file. */
void tla_trace_shutdown(void);

/* Register a server ID mapping: impl_id (raft_node_id_t) -> "s1", "s2", etc.
 * Call for each node in the cluster after setup. */
void tla_trace_register_server(raft_node_id_t impl_id, const char *tla_id);

/* Get the TLA+ server ID string for a given implementation node ID.
 * Returns "" if not registered. */
const char *tla_trace_server_id(raft_node_id_t impl_id);

/* --- Event emission functions --- */

/* Full state capture: term, role, commitIndex, lastLogIndex, lastLogTerm, votedFor */
void tla_trace_event(raft_server_t *me, const char *event_name);

/* Full state + snapshot fields */
void tla_trace_event_snapshot(raft_server_t *me, const char *event_name);

/* Weak state capture: term + role only */
void tla_trace_event_weak(raft_server_t *me, const char *event_name);

/* Commit state capture: term + role + commitIndex */
void tla_trace_event_commit(raft_server_t *me, const char *event_name);

/* Full state + message fields for RequestVote */
void tla_trace_event_rv(raft_server_t *me, const char *event_name,
                        raft_node_id_t from, raft_node_id_t to,
                        int vote_granted);

/* Weak state + message fields for RequestVote response */
void tla_trace_event_rv_resp_weak(raft_server_t *me, const char *event_name,
                                  raft_node_id_t from, raft_node_id_t to,
                                  int vote_granted);

/* Full state + message fields for AppendEntries request */
void tla_trace_event_ae_req(raft_server_t *me, const char *event_name,
                            raft_node_id_t from, raft_node_id_t to,
                            raft_term_t msg_term,
                            raft_index_t prev_log_idx, raft_term_t prev_log_term,
                            raft_index_t leader_commit);

/* Weak state + message fields for AppendEntries response */
void tla_trace_event_ae_resp_weak(raft_server_t *me, const char *event_name,
                                  raft_node_id_t from, raft_node_id_t to,
                                  int success, raft_index_t match_index);

/* Weak state + message fields for InstallSnapshot request */
void tla_trace_event_is_req_weak(raft_server_t *me, const char *event_name,
                                 raft_node_id_t from, raft_node_id_t to,
                                 raft_index_t snap_idx, raft_term_t snap_term);

/* Full state + target for membership change */
void tla_trace_event_config(raft_server_t *me, const char *event_name,
                            raft_node_id_t target);

/* Emit a config line at trace start */
void tla_trace_emit_config(raft_server_t *me);

#define TLA_TRACE_IF(stmt) do { if (tla_trace_enabled()) { stmt; } } while(0)
int tla_trace_enabled(void);

#else /* !REDISRAFT_ENABLE_TRACE */

#define tla_trace_init()                          ((void)0)
#define tla_trace_shutdown()                      ((void)0)
#define tla_trace_register_server(id, name)       ((void)0)
#define tla_trace_server_id(id)                   ""
#define tla_trace_event(me, name)                 ((void)0)
#define tla_trace_event_snapshot(me, name)        ((void)0)
#define tla_trace_event_weak(me, name)            ((void)0)
#define tla_trace_event_commit(me, name)          ((void)0)
#define tla_trace_event_rv(me, n, f, t, v)        ((void)0)
#define tla_trace_event_rv_resp_weak(me,n,f,t,v)  ((void)0)
#define tla_trace_event_ae_req(me,n,f,t,mt,pli,plt,lc) ((void)0)
#define tla_trace_event_ae_resp_weak(me,n,f,t,s,mi)     ((void)0)
#define tla_trace_event_is_req_weak(me,n,f,t,si,st)     ((void)0)
#define tla_trace_event_config(me, name, target)  ((void)0)
#define tla_trace_emit_config(me)                 ((void)0)
#define TLA_TRACE_IF(stmt)                        ((void)0)
#define tla_trace_enabled()                       0

#endif /* REDISRAFT_ENABLE_TRACE */

#endif /* TLA_TRACE_H */
