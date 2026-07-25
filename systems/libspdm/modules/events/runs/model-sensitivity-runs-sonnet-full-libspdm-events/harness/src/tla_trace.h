/**
 * TLA+ Trace Emission Library — libspdm SPDM 1.3 Event Subscription
 *
 * Include this header in instrumented source files (guarded by TLA_TRACE_ENABLED).
 * Shadow state in g_tla_shadow is maintained across calls by tla_trace.c.
 */

#ifndef TLA_TRACE_H
#define TLA_TRACE_H

#ifdef TLA_TRACE_ENABLED

#include <stdbool.h>
#include <stdint.h>

/* -----------------------------------------------------------------------
 * Shadow state — fields not directly readable from libspdm_context_t
 * ----------------------------------------------------------------------- */
typedef struct {
    char subscription_state[16];       /* "SUB_NONE" | "SUB_ALL" | "SUB_LIST" */
    bool subscribe_types_sent;
    bool direct_send_active;
    char last_send_event_response[24]; /* "OK" | "VERSION_MISMATCH" | "REQUEST_IN_FLIGHT" | "NONE" */
    bool encap_event_in_flight;
    bool event_all_policy;
} tla_trace_shadow_t;

extern tla_trace_shadow_t g_tla_shadow;

/* -----------------------------------------------------------------------
 * Lifecycle
 * ----------------------------------------------------------------------- */
void tla_trace_init(const char *path);
void tla_trace_close(void);

/* -----------------------------------------------------------------------
 * Per-action emit functions — one per spec action.
 *
 * Caller is responsible for passing pre-converted string values where
 * needed (response_state_str).  Session state is hardcoded per action
 * since each action only fires at a known session state.
 * ----------------------------------------------------------------------- */

/* Called after libspdm_set_session_state(... HANDSHAKING) in key_exchange.c */
void tla_emit_key_exchange(bool with_event_all);

/* Called inside libspdm_set_session_state when transitioning to ESTABLISHED */
void tla_emit_handle_finish(void);

/* Called after libspdm_event_subscribe() succeeds in subscribe_event_types_ack.c
 * subscribe_type: LIBSPDM_EVENT_SUBSCRIBE_NONE=1, LIBSPDM_EVENT_SUBSCRIBE_LIST=2 */
void tla_emit_subscribe_event_types(bool subscribe_none, uint8_t subscribe_type);

/* Called before the version-mismatch return in event_ack.c
 * resp_state: "NORMAL" or "PROCESSING_ENCAP" at the moment of the check */
void tla_emit_send_event_version_mismatch(const char *resp_state);

/* Called after the version check passes (before response_state check) in event_ack.c */
void tla_emit_send_event_version_match(const char *resp_state);

/* Harness-level: called from test code after the SEND_EVENT exchange completes */
void tla_emit_send_event_complete(void);

/* Called after response_state = PROCESSING_ENCAP in libspdm_init_send_event_encap_state */
void tla_emit_init_encap_send_event(void);

/* Called after libspdm_generate_event_list() succeeds in encap_send_event.c */
void tla_emit_handle_encap_send_event(void);

/* Called after *need_continue = false in libspdm_process_encap_response_event_ack */
void tla_emit_process_encap_event_ack(void);

/* Called at start of libspdm_terminate_session, before state is cleared */
void tla_emit_terminate_session(void);

#endif /* TLA_TRACE_ENABLED */
#endif /* TLA_TRACE_H */
