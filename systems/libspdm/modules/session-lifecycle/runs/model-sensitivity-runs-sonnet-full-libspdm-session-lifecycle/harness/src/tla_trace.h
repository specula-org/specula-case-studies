/*
 * TLA+ trace emission module for libspdm session lifecycle verification.
 * Place in artifact/libspdm/include/tla_trace.h and include as "tla_trace.h".
 */

#ifndef TLA_TRACE_H
#define TLA_TRACE_H

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

/* Shadow state updated at instrumentation points, read at emit time */
typedef struct {
    int req_tx_gen;              /* incremented each activate(REQUESTER,new) on req */
    int rsp_rx_gen;              /* incremented each create_update(REQUESTER) on rsp */
    const char *req_ku_state;    /* "idle" | "update_sent" | "verify_sent" */
    const char *rsp_last_key_op; /* "none" | "update_key" | "update_all_keys" */
    const char *req_session_state; /* "ESTABLISHED" | "NOT_STARTED" */
    const char *rsp_session_state; /* "ESTABLISHED" | "NOT_STARTED" */
    bool rsp_rx_backup_valid;
    bool end_session_sent;
    bool end_session_ack_encoded;
    bool watchdog_active;
} tla_state_t;

extern tla_state_t g_tla;
extern FILE *g_tla_file;

void tla_init(const char *path);
void tla_finish(void);
void tla_emit(const char *event, const char *mtype, int param1, int param2);

#define TLA_EMIT(ev)                    tla_emit((ev), NULL, 0, 0)
#define TLA_EMIT_MSG(ev, mt, p1, p2)    tla_emit((ev), (mt), (p1), (p2))

#endif /* TLA_TRACE_H */
