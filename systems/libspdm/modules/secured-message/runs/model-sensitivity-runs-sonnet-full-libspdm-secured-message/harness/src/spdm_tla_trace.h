/**
 * spdm_tla_trace.h — TLA+ trace emission module for libspdm secured-message.
 *
 * Placed by apply.sh into artifact/libspdm/include/internal/
 * so it is included by all instrumented source files.
 *
 * Define SPDM_TLA_TRACE_ENABLE=1 to activate trace emission.
 * When 0 (default library build), all macros are no-ops.
 */
#ifndef SPDM_TLA_TRACE_H
#define SPDM_TLA_TRACE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef SPDM_TLA_TRACE_ENABLE

/* ---------- lifecycle -------------------------------------------------- */
void spdm_tla_init(const char *trace_file);
void spdm_tla_close(void);

/* ---------- context registration --------------------------------------- */
/* role: "requester" or "responder"
 * smc: pointer to libspdm_secured_message_context_t  */
void spdm_tla_register_ctx(void *smc, const char *role);

/* ---------- epoch tracking hooks --------------------------------------- */
/* Called from instrumented libspdm_create_update_session_data_key */
void spdm_tla_on_create_update(void *smc, int is_requester_action);
/* Called from instrumented libspdm_activate_update_session_data_key */
void spdm_tla_on_activate_update(void *smc, int is_requester_action, int commit);

/* ---------- synthesized state ----------------------------------------- */
void        spdm_tla_set_phase(const char *phase);     /* "Idle"/"PendingAck"/"PendingVerify" */
const char *spdm_tla_get_phase(void);
void        spdm_tla_set_committed(bool val);
bool        spdm_tla_get_committed(void);

/* ---------- epoch readers ---------------------------------------------- */
/* is_req_dir=1 → request direction key; 0 → response direction key */
uint32_t spdm_tla_epoch(void *smc, int is_req_dir);
uint32_t spdm_tla_backup_epoch(void *smc, int is_req_dir);
const char *spdm_tla_role(void *smc);  /* "requester" / "responder" / "unknown" */

/* ---------- low-level emitter ------------------------------------------ */
uint64_t spdm_tla_now_ms(void);
void     spdm_tla_emit(const char *json);  /* writes one NDJSON line */

/* ---------- encode / decode event emitters ----------------------------- */

/* Emit encode_advance_seq; called after seq increment in encode path.
 * seq: POST-increment sequence number.
 * is_request: true → direction=request, false → direction=response. */
void spdm_tla_emit_encode_advance_seq(void *smc, int is_request, uint64_t seq);

/* Emit encode_success; called after AEAD success in encode. */
void spdm_tla_emit_encode_success(void *smc, int is_request, uint64_t seq);

/* Emit decode_increment_seq; called after seq increment in decode path.
 * seq_after: POST-increment local counter.
 * msg_seq: sequence number parsed from the incoming message header. */
void spdm_tla_emit_decode_increment_seq(void *smc, int is_request,
                                        uint64_t seq_after, uint64_t msg_seq);

/* Emit decode_success; called after AEAD verification succeeds. */
void spdm_tla_emit_decode_success(void *smc, int is_request,
                                  uint64_t seq_after, uint64_t msg_seq);

/* Emit decode_session_id_fail; session_id field mismatch. */
void spdm_tla_emit_decode_session_id_fail(void *smc, int is_request,
                                          uint64_t seq_after, uint64_t msg_seq);

/* Emit decode_aead_fail; AEAD failed, backup_valid=false. */
void spdm_tla_emit_decode_aead_fail(void *smc, int is_request,
                                    uint64_t seq_after, uint64_t msg_seq);

/* Emit decode_aead_fail_backup; AEAD failed, backup_valid=true.
 * Returns LIBSPDM_STATUS_SESSION_TRY_DISCARD_KEY_UPDATE. */
void spdm_tla_emit_decode_aead_fail_backup(void *smc, int is_request,
                                           uint64_t seq_after, uint64_t msg_seq);

/* ---------- key-update event emitters ---------------------------------- */

/* Emitted from libspdm_req_key_update.c after create_update(RESPONDER) returns */
void spdm_tla_emit_create_update_responder_key(void *smc);

/* Emitted from libspdm_req_key_update.c after send_spdm_request(KEY_UPDATE) */
void spdm_tla_emit_send_key_update_request(void *smc, bool all_keys, uint64_t seq);

/* Emitted from libspdm_rsp_key_update_ack.c after key ops (UPDATE_KEY / ALL_KEYS) */
void spdm_tla_emit_responder_receive_key_update(void *smc, bool all_keys,
                                                uint64_t seq, uint32_t msg_epoch);

/* Emitted from libspdm_req_key_update.c after activate(REQUESTER, true) */
void spdm_tla_emit_requester_receive_key_update_ack(void *smc, bool all_keys,
                                                    uint64_t seq, uint32_t msg_epoch);

/* Emitted from libspdm_rsp_key_update_ack.c after activate(REQUESTER, true) for VERIFY */
void spdm_tla_emit_responder_receive_verify_new_key(void *smc, uint64_t seq,
                                                    uint32_t msg_epoch);

/* Emitted from libspdm_rsp_receive_send.c after rollback activate(REQUESTER, false) */
void spdm_tla_emit_responder_try_discard_key_update(void *smc, uint64_t seq,
                                                    uint32_t msg_epoch);

/* Emitted from libspdm_req_key_update.c after receiving VERIFY_ACK */
void spdm_tla_emit_requester_receive_verify_ack(void *smc, uint64_t seq,
                                                uint32_t msg_epoch);

/* Emitted from libspdm_rsp_encap_key_update.c after create+activate(RESPONDER) */
void spdm_tla_emit_encap_create_activate_rsp_key(void *smc);

#else /* !SPDM_TLA_TRACE_ENABLE */

/* When tracing is disabled, all calls are stripped at compile time. */
#define spdm_tla_init(f)                           ((void)0)
#define spdm_tla_close()                           ((void)0)
#define spdm_tla_register_ctx(s,r)                 ((void)0)
#define spdm_tla_on_create_update(s,a)             ((void)0)
#define spdm_tla_on_activate_update(s,a,c)         ((void)0)
#define spdm_tla_set_phase(p)                      ((void)0)
#define spdm_tla_set_committed(v)                  ((void)0)
#define spdm_tla_emit_encode_advance_seq(...)      ((void)0)
#define spdm_tla_emit_encode_success(...)          ((void)0)
#define spdm_tla_emit_decode_increment_seq(...)    ((void)0)
#define spdm_tla_emit_decode_success(...)          ((void)0)
#define spdm_tla_emit_decode_session_id_fail(...)  ((void)0)
#define spdm_tla_emit_decode_aead_fail(...)        ((void)0)
#define spdm_tla_emit_decode_aead_fail_backup(...) ((void)0)
#define spdm_tla_emit_create_update_responder_key(s)    ((void)0)
#define spdm_tla_emit_send_key_update_request(...)      ((void)0)
#define spdm_tla_emit_responder_receive_key_update(...) ((void)0)
#define spdm_tla_emit_requester_receive_key_update_ack(...)  ((void)0)
#define spdm_tla_emit_responder_receive_verify_new_key(...)  ((void)0)
#define spdm_tla_emit_responder_try_discard_key_update(...)  ((void)0)
#define spdm_tla_emit_requester_receive_verify_ack(...)      ((void)0)
#define spdm_tla_emit_encap_create_activate_rsp_key(s)       ((void)0)

#endif /* SPDM_TLA_TRACE_ENABLE */

#endif /* SPDM_TLA_TRACE_H */
