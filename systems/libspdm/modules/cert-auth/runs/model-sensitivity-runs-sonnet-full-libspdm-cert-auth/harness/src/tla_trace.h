/* TLA+ trace emission for libspdm CHALLENGE auth.
 * Emits one NDJSON line per protocol event to the configured trace file.
 * Every line includes "tag":"trace" so Trace.tla's ndJsonDeserialize sees it.
 *
 * All functions are defined with C linkage so they can be called from
 * instrumented C library files via extern declarations.
 */
#ifndef TLA_TRACE_H
#define TLA_TRACE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Call once before any trace emission. */
void tla_trace_init(const char *path);

/* Call once when done. */
void tla_trace_close(void);

/* Maps libspdm connection_state enum value -> string Trace.tla expects. */
const char *tla_conn_state_str(uint32_t state);

/* Simple event with no extra fields (negotiate, req_get_digests, rsp_get_digests,
 * req_digests_recv). */
void tla_trace_emit(const char *event, const char *node,
                    uint32_t conn_state);

/* Event with slot only (req_get_certificate, req_challenge, rsp_challenge_auth). */
void tla_trace_emit_slot(const char *event, const char *node,
                         uint32_t conn_state, unsigned int slot);

/* Event with slot + in_session flag (rsp_get_certificate). */
void tla_trace_emit_cert_rsp(const char *event, const char *node,
                              uint32_t conn_state, unsigned int slot,
                              int in_session);

/* Event with slot + cert_fetched + cert_hash_valid (req_certificate_recv). */
void tla_trace_emit_cert_recv(const char *event, const char *node,
                               uint32_t conn_state, unsigned int slot,
                               int cert_fetched, int cert_hash_valid);

/* Event with slot + verify_result string (req_challenge_auth_recv). */
void tla_trace_emit_verify(const char *event, const char *node,
                            uint32_t conn_state, unsigned int slot,
                            const char *verify_result);

/* Event with status code only (req_encap_fail, rsp_encap_sig_fail,
 * rsp_digest_append_fail, rsp_cert_append_fail). */
void tla_trace_emit_status(const char *event, const char *node,
                            uint32_t conn_state, uint32_t status_code);

/* Event with slot + status (rsp_cert_append_fail). */
void tla_trace_emit_slot_status(const char *event, const char *node,
                                 uint32_t conn_state, unsigned int slot,
                                 uint32_t status_code);

#ifdef __cplusplus
}
#endif

#endif /* TLA_TRACE_H */
