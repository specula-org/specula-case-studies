/*
 * tla_trace.h — NDJSON trace emission for sonic-iccpd
 * Category A (distributed, single-threaded event loop)
 */
#ifndef TLA_TRACE_H
#define TLA_TRACE_H

#include <stdio.h>
#include <time.h>

struct CSM;   /* forward declaration */

/* Initialize trace file. peer_id is "p1" or "p2". */
void tla_trace_init(const char *filename);
void tla_trace_close(void);

/* Register CSM → peer ID mapping */
void tla_trace_register_csm(struct CSM *csm, const char *peer_id);

/* Look up peer ID for a CSM */
const char *tla_trace_nid(struct CSM *csm);

/* Emit a protocol-state event (most actions) */
void tla_trace_emit(const char *event_name, struct CSM *csm);

/* Emit a MAC event with age_flag / pendingLocalDel / portState */
void tla_trace_emit_mac(const char *event_name, struct CSM *csm,
                        const char *mac_str, int age_flag,
                        int pending_local_del, int port_up);

/* Emit a MAC update event with both stored and incoming age flags (M1 bug) */
void tla_trace_emit_mac_update(const char *event_name, struct CSM *csm,
                               const char *mac_str, int stored_age_flag,
                               int incoming_age_flag);

/* Emit a NAK event */
void tla_trace_emit_nak(const char *event_name, struct CSM *csm,
                        const char *nak_type);

/* Emit a SysConfig event with remote node_id */
void tla_trace_emit_sysconfig(const char *event_name, struct CSM *csm,
                              int remote_node_id);

/* Write the config line (first line of trace) */
void tla_trace_write_config(void);

#endif /* TLA_TRACE_H */
