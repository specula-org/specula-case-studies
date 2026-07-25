/**
 * tla_trace.h — NDJSON trace emission for TLA+ trace validation.
 *
 * Usage:
 *   - In ONE translation unit (tla_encap_test.c): define TLA_TRACE_DEFINE_GLOBALS before including.
 *   - In all other instrumented TUs: just #include "tla_trace.h" (under LIBSPDM_TRACE_ENCAP guard).
 *
 * Event format:
 *   {"tag":"trace","ts":<ns>,"event":"<name>","cur_op":<u8>,"request_id":<u8>,
 *    "response_state":"<NORMAL|PROCESSING_ENCAP>","variant":"<V>",
 *    "cur_op_after":<u8>,"request_id_after":<u8>,"response_state_after":"<S>", ...}
 */

#ifndef TLA_TRACE_H
#define TLA_TRACE_H

#ifdef LIBSPDM_TRACE_ENCAP

#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
/* Caller must have already included the appropriate libspdm internal header
 * (internal/libspdm_responder_lib.h or internal/libspdm_requester_lib.h) before
 * including this header so that libspdm_context_t and SPDM_* constants are defined. */

/* ---------- globals (defined once via TLA_TRACE_DEFINE_GLOBALS) ---------- */

#ifdef TLA_TRACE_DEFINE_GLOBALS
FILE *g_tla_trace_file = NULL;
/* Pointer to the Responder's spdm_context, set by the test before Requester calls.
 * Used so verify_responder (emitted from req_challenge.c) can read Responder-side state. */
libspdm_context_t *g_tla_rsp_ctx = NULL;
/* Variant string for the current scenario (set at init_encap_state emit time). */
const char *g_tla_variant_str = "BASIC_CERT";
/* Monotonic event counter — TLA+ only needs ordering, not wall-clock values. */
uint64_t g_tla_ts_counter = 0;
#else
extern FILE *g_tla_trace_file;
extern libspdm_context_t *g_tla_rsp_ctx;
extern const char *g_tla_variant_str;
extern uint64_t g_tla_ts_counter;
#endif

/* ---------- helpers ---------- */

static inline uint64_t tla_now_ns(void)
{
    return ++g_tla_ts_counter;
}

/* Map SPDM wire op-code to the abstract integer the TLA+ spec expects.
 * Trace.tla TraceOpCode: 0=OP_NONE, 1=GET_DIGESTS, 2=GET_CERTIFICATE, 17=CHALLENGE. */
static inline uint8_t tla_abstract_op(uint8_t wire_op)
{
    switch (wire_op) {
    case 0x81: return 1;   /* SPDM_GET_DIGESTS */
    case 0x82: return 2;   /* SPDM_GET_CERTIFICATE */
    case 0x83: return 17;  /* SPDM_CHALLENGE */
    default:   return 0;   /* OP_NONE */
    }
}

static inline const char *tla_response_state_str(uint8_t state)
{
    return (state == LIBSPDM_RESPONSE_STATE_NORMAL) ? "NORMAL" : "PROCESSING_ENCAP";
}

/* Determine variant string from context + mut_auth_requested + is_basic flag. */
static inline const char *tla_variant_str(libspdm_context_t *ctx,
                                           uint8_t mut_auth_requested,
                                           bool is_basic)
{
    if (is_basic) {
        if (libspdm_is_capabilities_flag_supported(ctx, false,
                SPDM_GET_CAPABILITIES_REQUEST_FLAGS_PUB_KEY_ID_CAP, 0))
            return "BASIC_PK";
        else
            return "BASIC_CERT";
    }
    switch (mut_auth_requested) {
    case SPDM_KEY_EXCHANGE_RESPONSE_MUT_AUTH_REQUESTED:
        return "NO_ENCAP";
    case SPDM_KEY_EXCHANGE_RESPONSE_MUT_AUTH_REQUESTED_WITH_ENCAP_REQUEST:
        return "WITH_ENCAP_REQUEST";
    case SPDM_KEY_EXCHANGE_RESPONSE_MUT_AUTH_REQUESTED_WITH_GET_DIGESTS:
        return "WITH_GET_DIGESTS";
    default:
        return "NO_ENCAP";
    }
}

/* ---------- emit functions (static inline — defined in every TU that includes) ---------- */

/**
 * init_encap_state — emitted at end of libspdm_init_basic_mut_auth_encap_state /
 *                    libspdm_init_mut_auth_encap_state.
 */
static inline void tla_emit_init_encap_state(libspdm_context_t *ctx,
                                              uint8_t mut_auth_requested,
                                              bool is_basic)
{
    if (!g_tla_trace_file) return;
    const char *variant = tla_variant_str(ctx, mut_auth_requested, is_basic);
    /* Save variant for verify_responder to use later. */
    g_tla_variant_str = variant;
    uint8_t cur_op   = ctx->encap_context.current_request_op_code;
    uint8_t req_id   = ctx->encap_context.request_id;
    uint8_t rsp_state = ctx->response_state;
    bool resp_auth    = (ctx->connection_info.connection_state ==
                         LIBSPDM_CONNECTION_STATE_AUTHENTICATED);
    fprintf(g_tla_trace_file,
            "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"init_encap_state\","
            "\"cur_op\":%u,\"request_id\":%u,\"response_state\":\"%s\","
            "\"variant\":\"%s\",\"resp_authenticated\":%s,"
            "\"cur_op_after\":%u,\"request_id_after\":%u,\"response_state_after\":\"%s\"}\n",
            (unsigned long long)tla_now_ns(),
            tla_abstract_op(cur_op), req_id, tla_response_state_str(rsp_state),
            variant,
            resp_auth ? "true" : "false",
            tla_abstract_op(cur_op), 0, tla_response_state_str(rsp_state));
    fflush(g_tla_trace_file);
}

/**
 * verify_responder — emitted from req_challenge.c after connection_state=AUTHENTICATED,
 *                    inside the BASIC_MUT_AUTH_REQ check.
 *                    Uses g_tla_rsp_ctx (Responder context) if set; else uses req_ctx.
 */
static inline void tla_emit_verify_responder(libspdm_context_t *req_ctx)
{
    if (!g_tla_trace_file) return;
    libspdm_context_t *ctx = g_tla_rsp_ctx ? g_tla_rsp_ctx : req_ctx;
    uint8_t cur_op    = ctx->encap_context.current_request_op_code;
    uint8_t req_id    = ctx->encap_context.request_id;
    uint8_t rsp_state = ctx->response_state;
    fprintf(g_tla_trace_file,
            "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"verify_responder\","
            "\"cur_op\":%u,\"request_id\":%u,\"response_state\":\"%s\","
            "\"variant\":\"%s\",\"resp_authenticated\":true,"
            "\"cur_op_after\":%u,\"request_id_after\":%u,\"response_state_after\":\"%s\"}\n",
            (unsigned long long)tla_now_ns(),
            tla_abstract_op(cur_op), req_id, tla_response_state_str(rsp_state),
            g_tla_variant_str,
            tla_abstract_op(cur_op), req_id, tla_response_state_str(rsp_state));
    fflush(g_tla_trace_file);
}

/**
 * get_encapsulated_request — emitted after libspdm_process_encapsulated_response succeeds
 *                            in libspdm_get_response_encapsulated_request.
 * pre_* are captured before process_encapsulated_response modifies state.
 */
static inline void tla_emit_get_encapsulated_request(libspdm_context_t *ctx,
                                                      uint8_t pre_cur_op,
                                                      uint8_t pre_request_id,
                                                      uint8_t pre_response_state)
{
    if (!g_tla_trace_file) return;
    uint8_t cur_op_after    = ctx->encap_context.current_request_op_code;
    uint8_t req_id_after    = ctx->encap_context.request_id;
    uint8_t rsp_state_after = ctx->response_state;
    fprintf(g_tla_trace_file,
            "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"get_encapsulated_request\","
            "\"cur_op\":%u,\"request_id\":%u,\"response_state\":\"%s\","
            "\"variant\":\"%s\",\"resp_authenticated\":true,"
            "\"cur_op_after\":%u,\"request_id_after\":%u,\"response_state_after\":\"%s\"}\n",
            (unsigned long long)tla_now_ns(),
            tla_abstract_op(pre_cur_op), pre_request_id, tla_response_state_str(pre_response_state),
            g_tla_variant_str,
            tla_abstract_op(cur_op_after), req_id_after, tla_response_state_str(rsp_state_after));
    fflush(g_tla_trace_file);
}

/**
 * deliver_encap_digests — emitted from libspdm_process_encapsulated_response
 *                         after request_id increment and op advance, when prev_op = GET_DIGESTS.
 * pre_* are captured before the advance.
 */
static inline void tla_emit_deliver_encap_digests(libspdm_context_t *ctx,
                                                   uint8_t pre_cur_op,
                                                   uint8_t pre_request_id,
                                                   uint8_t pre_response_state)
{
    if (!g_tla_trace_file) return;
    uint8_t cur_op_after    = ctx->encap_context.current_request_op_code;
    uint8_t req_id_after    = ctx->encap_context.request_id;
    /* response_state may still be PROCESSING_ENCAP here; the caller sets NORMAL later if done. */
    uint8_t rsp_state_after = (cur_op_after == 0) ?
        LIBSPDM_RESPONSE_STATE_NORMAL : ctx->response_state;
    fprintf(g_tla_trace_file,
            "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"deliver_encap_digests\","
            "\"cur_op\":%u,\"request_id\":%u,\"response_state\":\"%s\","
            "\"variant\":\"%s\",\"resp_authenticated\":true,"
            "\"cur_op_after\":%u,\"request_id_after\":%u,\"response_state_after\":\"%s\"}\n",
            (unsigned long long)tla_now_ns(),
            tla_abstract_op(pre_cur_op), pre_request_id, tla_response_state_str(pre_response_state),
            g_tla_variant_str,
            tla_abstract_op(cur_op_after), req_id_after, tla_response_state_str(rsp_state_after));
    fflush(g_tla_trace_file);
}

/**
 * deliver_encap_certificate — emitted when prev_op = GET_CERTIFICATE and !need_continue.
 */
static inline void tla_emit_deliver_encap_certificate(libspdm_context_t *ctx,
                                                       uint8_t pre_cur_op,
                                                       uint8_t pre_request_id,
                                                       uint8_t pre_response_state)
{
    if (!g_tla_trace_file) return;
    uint8_t cur_op_after    = ctx->encap_context.current_request_op_code;
    uint8_t req_id_after    = ctx->encap_context.request_id;
    uint8_t rsp_state_after = (cur_op_after == 0) ?
        LIBSPDM_RESPONSE_STATE_NORMAL : ctx->response_state;
    fprintf(g_tla_trace_file,
            "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"deliver_encap_certificate\","
            "\"cur_op\":%u,\"request_id\":%u,\"response_state\":\"%s\","
            "\"variant\":\"%s\",\"resp_authenticated\":true,"
            "\"cur_op_after\":%u,\"request_id_after\":%u,\"response_state_after\":\"%s\","
            "\"cert_chain_received_after\":true}\n",
            (unsigned long long)tla_now_ns(),
            tla_abstract_op(pre_cur_op), pre_request_id, tla_response_state_str(pre_response_state),
            g_tla_variant_str,
            tla_abstract_op(cur_op_after), req_id_after, tla_response_state_str(rsp_state_after));
    fflush(g_tla_trace_file);
}

/**
 * deliver_encap_challenge_auth — emitted from libspdm_process_encap_response_challenge_auth
 *                                after libspdm_set_connection_state(AUTHENTICATED).
 * At this point current_request_op_code has not yet been advanced (happens in caller).
 * We hardcode cur_op_after=0 (CHALLENGE is always last) and response_state_after=NORMAL.
 */
static inline void tla_emit_deliver_encap_challenge_auth(libspdm_context_t *ctx,
                                                          uint8_t pre_cur_op,
                                                          uint8_t pre_request_id,
                                                          uint8_t pre_response_state)
{
    if (!g_tla_trace_file) return;
    /* request_id_after = pre_request_id + 1 (incremented in caller after this returns) */
    fprintf(g_tla_trace_file,
            "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"deliver_encap_challenge_auth\","
            "\"cur_op\":%u,\"request_id\":%u,\"response_state\":\"%s\","
            "\"variant\":\"%s\",\"resp_authenticated\":true,"
            "\"cur_op_after\":0,\"request_id_after\":%u,\"response_state_after\":\"NORMAL\","
            "\"mutually_authenticated_after\":true,\"slot_id_ok_after\":true,"
            "\"slot_mask_ok_after\":true,\"cert_hash_ok_after\":true}\n",
            (unsigned long long)tla_now_ns(),
            tla_abstract_op(pre_cur_op), pre_request_id, tla_response_state_str(pre_response_state),
            g_tla_variant_str,
            (uint8_t)(pre_request_id + 1));
    fflush(g_tla_trace_file);
}

/**
 * encap_not_ready — emitted inside NOT_READY_PEER branch of libspdm_process_encapsulated_response,
 *                   after current_request_op_code = 0 is assigned.
 */
static inline void tla_emit_encap_not_ready(libspdm_context_t *ctx,
                                             uint8_t pre_cur_op,
                                             uint8_t pre_request_id,
                                             uint8_t pre_response_state)
{
    if (!g_tla_trace_file) return;
    fprintf(g_tla_trace_file,
            "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"encap_not_ready\","
            "\"cur_op\":%u,\"request_id\":%u,\"response_state\":\"%s\","
            "\"variant\":\"%s\",\"resp_authenticated\":true,"
            "\"cur_op_after\":0,\"request_id_after\":%u,\"response_state_after\":\"NORMAL\"}\n",
            (unsigned long long)tla_now_ns(),
            tla_abstract_op(pre_cur_op), pre_request_id, tla_response_state_str(pre_response_state),
            g_tla_variant_str,
            pre_request_id);
    fflush(g_tla_trace_file);
}

/**
 * encap_error — emitted after response_state = NORMAL is assigned in error paths.
 * cur_op_after = current_request_op_code (NOT reset — this is the Family 4 bug).
 */
static inline void tla_emit_encap_error(libspdm_context_t *ctx,
                                         uint8_t pre_cur_op,
                                         uint8_t pre_request_id)
{
    if (!g_tla_trace_file) return;
    /* At this point response_state has been set to NORMAL by the caller. */
    uint8_t cur_op_after = ctx->encap_context.current_request_op_code;
    fprintf(g_tla_trace_file,
            "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"encap_error\","
            "\"cur_op\":%u,\"request_id\":%u,\"response_state\":\"PROCESSING_ENCAP\","
            "\"variant\":\"%s\",\"resp_authenticated\":true,"
            "\"cur_op_after\":%u,\"request_id_after\":%u,\"response_state_after\":\"NORMAL\","
            "\"encap_error_after\":true}\n",
            (unsigned long long)tla_now_ns(),
            tla_abstract_op(pre_cur_op), pre_request_id,
            g_tla_variant_str,
            tla_abstract_op(cur_op_after), pre_request_id);
    fflush(g_tla_trace_file);
}

#endif /* LIBSPDM_TRACE_ENCAP */
#endif /* TLA_TRACE_H */
