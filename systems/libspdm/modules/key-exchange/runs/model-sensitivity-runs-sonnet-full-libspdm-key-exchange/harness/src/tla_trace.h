/**
 * TLA+ trace emission for libspdm key exchange / finish.
 * Header-only: include in instrumented source files.
 * Enable by compiling with -DTLA_TRACE_ENABLED=1.
 */
#ifndef TLA_TRACE_H
#define TLA_TRACE_H

#ifdef TLA_TRACE_ENABLED

#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <time.h>

/* Global trace file pointer, opened by tla_trace_open(). */
extern FILE *g_tla_trace_fp;

/* Raw 32-bit session_id of the most-recently-allocated session.
 * Updated by rsp_handle_key_exchange; read by rsp_decode_secured_message
 * to recover the 1-based TLA+ slot for single-session tests. */
extern uint32_t g_tla_last_session_raw_id;

/* Return current time in nanoseconds (monotonic). */
static inline uint64_t tla_now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

/* ------------------------------------------------------------------ */
/* Helper macros to format booleans and strings safely                  */

#define TLA_BOOL(b) ((b) ? "true" : "false")

/* ------------------------------------------------------------------ */
/* Event emit macros — write one NDJSON line per event                  */

/* req_send_key_exchange */
#define TLA_EMIT_REQ_SEND_KEY_EXCHANGE(session_id, hitc, req_slot_id, mode_str) \
    do { if (g_tla_trace_fp) { \
        fprintf(g_tla_trace_fp, \
            "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"req_send_key_exchange\"," \
            "\"session_id\":%d,\"hitc\":%s,\"req_slot_id\":%d,\"mode\":\"%s\"}\n", \
            (unsigned long long)tla_now_ns(), \
            (int)(session_id), TLA_BOOL(hitc), (int)(req_slot_id), (mode_str)); \
        fflush(g_tla_trace_fp); \
    }} while(0)

/* rsp_handle_key_exchange */
#define TLA_EMIT_RSP_HANDLE_KEY_EXCHANGE(session_id, hitc, req_slot_id, mode_str, \
        latest_session_id, session_state_str, peer_cert_slot, cert_advertised, mut_auth_mode_str) \
    do { if (g_tla_trace_fp) { \
        fprintf(g_tla_trace_fp, \
            "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"rsp_handle_key_exchange\"," \
            "\"session_id\":%d,\"hitc\":%s,\"req_slot_id\":%d,\"mode\":\"%s\"," \
            "\"latest_session_id\":%d,\"session_state\":\"%s\"," \
            "\"peer_cert_slot\":%d,\"cert_advertised\":%d,\"mut_auth_mode\":\"%s\"}\n", \
            (unsigned long long)tla_now_ns(), \
            (int)(session_id), TLA_BOOL(hitc), (int)(req_slot_id), (mode_str), \
            (int)(latest_session_id), (session_state_str), \
            (int)(peer_cert_slot), (int)(cert_advertised), (mut_auth_mode_str)); \
        fflush(g_tla_trace_fp); \
    }} while(0)

/* req_send_finish */
#define TLA_EMIT_REQ_SEND_FINISH(session_id, session_id_valid, auth_session, req_slot_id) \
    do { if (g_tla_trace_fp) { \
        fprintf(g_tla_trace_fp, \
            "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"req_send_finish\"," \
            "\"session_id\":%d,\"session_id_valid\":%s,\"auth_session\":%d,\"req_slot_id\":%d}\n", \
            (unsigned long long)tla_now_ns(), \
            (int)(session_id), TLA_BOOL(session_id_valid), \
            (int)(auth_session), (int)(req_slot_id)); \
        fflush(g_tla_trace_fp); \
    }} while(0)

/* rsp_derive_data_keys */
#define TLA_EMIT_RSP_DERIVE_DATA_KEYS(session_id, session_id_valid, auth_session, req_slot_id, \
        session_state_str, data_keys_live, cert_slot_verified, finish_authenticated_for, latest_session_id) \
    do { if (g_tla_trace_fp) { \
        fprintf(g_tla_trace_fp, \
            "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"rsp_derive_data_keys\"," \
            "\"session_id\":%d,\"session_id_valid\":%s,\"auth_session\":%d,\"req_slot_id\":%d," \
            "\"session_state\":\"%s\",\"data_keys_live\":%s," \
            "\"cert_slot_verified\":%d,\"finish_authenticated_for\":%d,\"latest_session_id\":%d}\n", \
            (unsigned long long)tla_now_ns(), \
            (int)(session_id), TLA_BOOL(session_id_valid), \
            (int)(auth_session), (int)(req_slot_id), \
            (session_state_str), TLA_BOOL(data_keys_live), \
            (int)(cert_slot_verified), (int)(finish_authenticated_for), \
            (int)(latest_session_id)); \
        fflush(g_tla_trace_fp); \
    }} while(0)

/* rsp_commit_established */
#define TLA_EMIT_RSP_COMMIT_ESTABLISHED(session_id, session_state_str, latest_session_id) \
    do { if (g_tla_trace_fp) { \
        fprintf(g_tla_trace_fp, \
            "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"rsp_commit_established\"," \
            "\"session_id\":%d,\"session_state\":\"%s\",\"latest_session_id\":%d}\n", \
            (unsigned long long)tla_now_ns(), \
            (int)(session_id), (session_state_str), (int)(latest_session_id)); \
        fflush(g_tla_trace_fp); \
    }} while(0)

/* rsp_encode_failure */
#define TLA_EMIT_RSP_ENCODE_FAILURE(session_id, session_state_str, data_keys_live) \
    do { if (g_tla_trace_fp) { \
        fprintf(g_tla_trace_fp, \
            "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"rsp_encode_failure\"," \
            "\"session_id\":%d,\"session_state\":\"%s\",\"data_keys_live\":%s}\n", \
            (unsigned long long)tla_now_ns(), \
            (int)(session_id), (session_state_str), TLA_BOOL(data_keys_live)); \
        fflush(g_tla_trace_fp); \
    }} while(0)

/* req_send_app_data (emitted from test code) */
#define TLA_EMIT_REQ_SEND_APP_DATA(session_id, seq_num) \
    do { if (g_tla_trace_fp) { \
        fprintf(g_tla_trace_fp, \
            "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"req_send_app_data\"," \
            "\"session_id\":%d,\"seq_num\":%d,\"authentic\":true}\n", \
            (unsigned long long)tla_now_ns(), \
            (int)(session_id), (int)(seq_num)); \
        fflush(g_tla_trace_fp); \
    }} while(0)

/* rsp_decode_secured_message */
#define TLA_EMIT_RSP_DECODE_SECURED_MESSAGE(session_id, seq_num, authentic, \
        seq_before_advance, expected_seq, last_decode_rejected) \
    do { if (g_tla_trace_fp) { \
        fprintf(g_tla_trace_fp, \
            "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"rsp_decode_secured_message\"," \
            "\"session_id\":%d,\"seq_num\":%d,\"authentic\":%s," \
            "\"seq_before_advance\":%llu,\"expected_seq\":%llu,\"last_decode_rejected\":%s}\n", \
            (unsigned long long)tla_now_ns(), \
            (int)(session_id), (int)(seq_num), TLA_BOOL(authentic), \
            (unsigned long long)(seq_before_advance), \
            (unsigned long long)(expected_seq), \
            TLA_BOOL(last_decode_rejected)); \
        fflush(g_tla_trace_fp); \
    }} while(0)

/* ------------------------------------------------------------------ */
/* Lifecycle                                                            */

static inline void tla_trace_open(const char *filename) {
    g_tla_trace_fp = fopen(filename, "w");
}

static inline void tla_trace_close(void) {
    if (g_tla_trace_fp) {
        fflush(g_tla_trace_fp);
        fclose(g_tla_trace_fp);
        g_tla_trace_fp = NULL;
    }
}

#else  /* TLA_TRACE_ENABLED not set — no-ops */

#define TLA_EMIT_REQ_SEND_KEY_EXCHANGE(...)          do {} while(0)
#define TLA_EMIT_RSP_HANDLE_KEY_EXCHANGE(...)         do {} while(0)
#define TLA_EMIT_REQ_SEND_FINISH(...)                do {} while(0)
#define TLA_EMIT_RSP_DERIVE_DATA_KEYS(...)           do {} while(0)
#define TLA_EMIT_RSP_COMMIT_ESTABLISHED(...)         do {} while(0)
#define TLA_EMIT_RSP_ENCODE_FAILURE(...)             do {} while(0)
#define TLA_EMIT_REQ_SEND_APP_DATA(...)              do {} while(0)
#define TLA_EMIT_RSP_DECODE_SECURED_MESSAGE(...)     do {} while(0)

#define tla_trace_open(f)    do {} while(0)
#define tla_trace_close()    do {} while(0)

#endif /* TLA_TRACE_ENABLED */

#endif /* TLA_TRACE_H */
