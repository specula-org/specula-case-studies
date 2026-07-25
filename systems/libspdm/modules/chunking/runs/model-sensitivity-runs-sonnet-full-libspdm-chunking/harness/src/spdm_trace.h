/**
 * spdm_trace.h — NDJSON trace emission for libspdm chunking harness.
 *
 * Every event line:
 *   {"tag":"trace","ts_ns":<ns>,"event":"<name>","node":"<node>",
 *    "send_in_use":<bool>,"send_seq_no":<n>,"send_bytes_transferred":<n>,
 *    "send_large_msg_size":<n>,"get_in_use":<bool>,"get_seq_no":<n>,
 *    "get_bytes_sent":<n>,"get_large_msg_size":<n>,
 *    "req_state":"<str>","req_bytes_so_far":<n>,"last_chunk_received":<bool>,
 *    "output_written":<bool>,"scratch_zeroed":<bool>,"transfer_status":"<str>",
 *    <extra fields>}
 */

#ifndef SPDM_TRACE_H
#define SPDM_TRACE_H

#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <time.h>
#include "internal/libspdm_common_lib.h"

/* --- Global trace file handle --- */
extern FILE *g_spdm_trace_file;

/* --- Shadow state for requester side (local to libspdm_handle_error_large_response) ---
 * These are injected as local variables by the instrumentation patch.
 * The emit macros below reference them by name. */

/* --- Timestamp helper --- */
static inline uint64_t spdm_trace_ts_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

/* --- Core emit function --- */
static inline void spdm_trace_emit_core(
    const char *event,
    const char *node,
    /* send context fields */
    bool send_in_use, uint32_t send_seq_no, size_t send_bytes_transferred, uint32_t send_large_msg_size,
    /* get context fields */
    bool get_in_use, uint32_t get_seq_no, size_t get_bytes_sent, uint32_t get_large_msg_size,
    /* requester shadow fields */
    const char *req_state, size_t req_bytes_so_far,
    bool last_chunk_received, bool output_written, bool scratch_zeroed,
    const char *transfer_status,
    /* event-specific extra fields (may be NULL or empty string) */
    const char *extra)
{
    if (!g_spdm_trace_file) return;
    uint64_t ts = spdm_trace_ts_ns();
    fprintf(g_spdm_trace_file,
        "{\"tag\":\"trace\",\"ts_ns\":%llu,\"event\":\"%s\",\"node\":\"%s\","
        "\"send_in_use\":%s,\"send_seq_no\":%u,\"send_bytes_transferred\":%zu,"
        "\"send_large_msg_size\":%u,"
        "\"get_in_use\":%s,\"get_seq_no\":%u,\"get_bytes_sent\":%zu,"
        "\"get_large_msg_size\":%u,"
        "\"req_state\":\"%s\",\"req_bytes_so_far\":%zu,"
        "\"last_chunk_received\":%s,\"output_written\":%s,\"scratch_zeroed\":%s,"
        "\"transfer_status\":\"%s\"%s%s}\n",
        (unsigned long long)ts, event, node,
        send_in_use ? "true" : "false", send_seq_no, send_bytes_transferred,
        send_large_msg_size,
        get_in_use ? "true" : "false", get_seq_no, get_bytes_sent,
        get_large_msg_size,
        req_state, req_bytes_so_far,
        last_chunk_received ? "true" : "false",
        output_written ? "true" : "false",
        scratch_zeroed ? "true" : "false",
        transfer_status,
        (extra && extra[0]) ? "," : "", (extra && extra[0]) ? extra : "");
    fflush(g_spdm_trace_file);
}

/* --- Convenience macros that read from spdm_context --- */

/* Extract send/get state from a libspdm_context_t* named ctx */
#define _SPDM_TRACE_SEND(ctx) \
    (ctx)->chunk_context.send.chunk_in_use, \
    (ctx)->chunk_context.send.chunk_seq_no, \
    (ctx)->chunk_context.send.chunk_bytes_transferred, \
    (uint32_t)(ctx)->chunk_context.send.large_message_size

#define _SPDM_TRACE_GET(ctx) \
    (ctx)->chunk_context.get.chunk_in_use, \
    (ctx)->chunk_context.get.chunk_seq_no, \
    (ctx)->chunk_context.get.chunk_bytes_transferred, \
    (uint32_t)(ctx)->chunk_context.get.large_message_size

/* Default requester shadow values (used for responder events) */
#define _SPDM_TRACE_REQ_DEFAULT  "IDLE", 0, false, false, false, "IDLE"

/* ----------------------------------------------------------------
 * Event-specific emit macros
 * ---------------------------------------------------------------- */

/* Responder: first chunk of a large CHUNK_SEND received */
#define SPDM_TRACE_CHUNK_SEND_FIRST(ctx, handle, chunk_sz, large_sz) \
    do { \
        char _extra[128]; \
        snprintf(_extra, sizeof(_extra), \
            "\"handle\":%u,\"incoming_seq_no\":0,\"chunk_size\":%u,\"large_size\":%u", \
            (unsigned)(handle), (unsigned)(chunk_sz), (unsigned)(large_sz)); \
        spdm_trace_emit_core("chunk_send_first", "responder", \
            _SPDM_TRACE_SEND(ctx), _SPDM_TRACE_GET(ctx), \
            _SPDM_TRACE_REQ_DEFAULT, _extra); \
    } while (0)

/* Responder: valid subsequent chunk received */
#define SPDM_TRACE_CHUNK_SEND_VALID(ctx, handle, seq, is_last) \
    do { \
        char _extra[128]; \
        snprintf(_extra, sizeof(_extra), \
            "\"handle\":%u,\"incoming_seq_no\":%u,\"is_last\":%s", \
            (unsigned)(handle), (unsigned)(seq), (is_last) ? "true" : "false"); \
        spdm_trace_emit_core("chunk_send_valid", "responder", \
            _SPDM_TRACE_SEND(ctx), _SPDM_TRACE_GET(ctx), \
            _SPDM_TRACE_REQ_DEFAULT, _extra); \
    } while (0)

/* Responder: invalid seq-no chunk received (Family 2) */
#define SPDM_TRACE_CHUNK_SEND_INVALID_SEQ(ctx, handle, incoming_seq, bytes_advanced) \
    do { \
        char _extra[160]; \
        snprintf(_extra, sizeof(_extra), \
            "\"handle\":%u,\"incoming_seq_no\":%u,\"seq_no_mismatch\":true,\"bytes_advanced\":%s", \
            (unsigned)(handle), (unsigned)(incoming_seq), (bytes_advanced) ? "true" : "false"); \
        spdm_trace_emit_core("chunk_send_invalid_seq", "responder", \
            _SPDM_TRACE_SEND(ctx), _SPDM_TRACE_GET(ctx), \
            _SPDM_TRACE_REQ_DEFAULT, _extra); \
    } while (0)

/* Responder: large response stored in scratch, ready for CHUNK_GET */
#define SPDM_TRACE_LARGE_RESPONSE_READY(ctx, handle, large_sz) \
    do { \
        char _extra[128]; \
        snprintf(_extra, sizeof(_extra), \
            "\"handle\":%u,\"large_size\":%u", \
            (unsigned)(handle), (unsigned)(large_sz)); \
        spdm_trace_emit_core("large_response_ready", "responder", \
            _SPDM_TRACE_SEND(ctx), _SPDM_TRACE_GET(ctx), \
            _SPDM_TRACE_REQ_DEFAULT, _extra); \
    } while (0)

/* Requester: received LARGE_RESPONSE error, starting CHUNK_GET loop */
#define SPDM_TRACE_LARGE_RESPONSE_ERROR_RECEIVED(ctx, handle, large_sz) \
    do { \
        char _extra[128]; \
        snprintf(_extra, sizeof(_extra), \
            "\"handle\":%u,\"large_size\":%u,\"chunk_seq_no\":0", \
            (unsigned)(handle), (unsigned)(large_sz)); \
        spdm_trace_emit_core("large_response_error_received", "requester", \
            _SPDM_TRACE_SEND(ctx), _SPDM_TRACE_GET(ctx), \
            "IN_PROGRESS", 0, false, false, false, "IN_PROGRESS", _extra); \
    } while (0)

/* Responder: serving a CHUNK_GET (normal path) */
#define SPDM_TRACE_CHUNK_GET_SERVED(ctx, handle, seq, chunk_sz, is_last, large_sz) \
    do { \
        char _extra[160]; \
        snprintf(_extra, sizeof(_extra), \
            "\"handle\":%u,\"seq_no\":%u,\"chunk_size\":%u,\"is_last\":%s,\"large_size\":%u", \
            (unsigned)(handle), (unsigned)(seq), (unsigned)(chunk_sz), \
            (is_last) ? "true" : "false", (unsigned)(large_sz)); \
        spdm_trace_emit_core("chunk_get_served", "responder", \
            _SPDM_TRACE_SEND(ctx), _SPDM_TRACE_GET(ctx), \
            _SPDM_TRACE_REQ_DEFAULT, _extra); \
    } while (0)

/* Responder: serving CHUNK_GET while send is in progress (Family 5) */
#define SPDM_TRACE_CHUNK_GET_DURING_SEND(ctx, handle, seq, chunk_sz, is_last, large_sz) \
    do { \
        char _extra[192]; \
        snprintf(_extra, sizeof(_extra), \
            "\"handle\":%u,\"seq_no\":%u,\"chunk_size\":%u,\"is_last\":%s," \
            "\"large_size\":%u,\"send_in_use_at_entry\":true", \
            (unsigned)(handle), (unsigned)(seq), (unsigned)(chunk_sz), \
            (is_last) ? "true" : "false", (unsigned)(large_sz)); \
        spdm_trace_emit_core("chunk_get_during_send", "responder", \
            _SPDM_TRACE_SEND(ctx), _SPDM_TRACE_GET(ctx), \
            _SPDM_TRACE_REQ_DEFAULT, _extra); \
    } while (0)

/* Requester: processed a valid CHUNK_RESPONSE */
#define SPDM_TRACE_CHUNK_RESPONSE_VALID(ctx, seq, chunk_sz, rcv_msg_sz, is_last, \
                                         req_bytes, last_chunk, xfer_status) \
    do { \
        char _extra[256]; \
        snprintf(_extra, sizeof(_extra), \
            "\"seq_no\":%u,\"chunk_size\":%u,\"received_msg_size\":%zu,\"is_last\":%s", \
            (unsigned)(seq), (unsigned)(chunk_sz), (size_t)(rcv_msg_sz), \
            (is_last) ? "true" : "false"); \
        spdm_trace_emit_core("chunk_response_processed_valid", "requester", \
            _SPDM_TRACE_SEND(ctx), _SPDM_TRACE_GET(ctx), \
            "IN_PROGRESS", (size_t)(req_bytes), (bool)(last_chunk), \
            false, false, (xfer_status), _extra); \
    } while (0)

/* Requester: CHUNK_RESPONSE chunk_size exceeds message bounds (Family 4) */
#define SPDM_TRACE_CHUNK_RESPONSE_SOURCE_OOB(ctx, seq, chunk_sz, rcv_msg_sz, \
                                              payload_bound, req_bytes, xfer_status) \
    do { \
        char _extra[256]; \
        snprintf(_extra, sizeof(_extra), \
            "\"seq_no\":%u,\"chunk_size\":%u,\"received_msg_size\":%zu," \
            "\"oob_detected\":true,\"actual_payload_bound\":%zu", \
            (unsigned)(seq), (unsigned)(chunk_sz), (size_t)(rcv_msg_sz), \
            (size_t)(payload_bound)); \
        spdm_trace_emit_core("chunk_response_source_oob", "requester", \
            _SPDM_TRACE_SEND(ctx), _SPDM_TRACE_GET(ctx), \
            "IN_PROGRESS", (size_t)(req_bytes), false, false, false, (xfer_status), _extra); \
    } while (0)

/* Requester: transfer complete, output written and scratch zeroed */
#define SPDM_TRACE_TRANSFER_COMPLETE_SUCCESS(ctx, last_chunk, bytes_so_far, large_sz) \
    do { \
        char _extra[128]; \
        snprintf(_extra, sizeof(_extra), \
            "\"bytes_so_far\":%zu,\"large_size\":%zu", \
            (size_t)(bytes_so_far), (size_t)(large_sz)); \
        spdm_trace_emit_core("transfer_complete_success", "requester", \
            _SPDM_TRACE_SEND(ctx), _SPDM_TRACE_GET(ctx), \
            "SUCCESS", (size_t)(bytes_so_far), (bool)(last_chunk), \
            true, true, "SUCCESS", _extra); \
    } while (0)

/* Requester: transfer complete but buffer overflow — Family 3 bug */
#define SPDM_TRACE_TRANSFER_COMPLETE_OVERFLOW(ctx, last_chunk, bytes_so_far, large_sz, cap) \
    do { \
        char _extra[160]; \
        snprintf(_extra, sizeof(_extra), \
            "\"bytes_so_far\":%zu,\"large_size\":%zu,\"response_capacity\":%zu", \
            (size_t)(bytes_so_far), (size_t)(large_sz), (size_t)(cap)); \
        spdm_trace_emit_core("transfer_complete_overflow", "requester", \
            _SPDM_TRACE_SEND(ctx), _SPDM_TRACE_GET(ctx), \
            "SUCCESS", (size_t)(bytes_so_far), (bool)(last_chunk), \
            false, false, "SUCCESS", _extra); \
    } while (0)

/* --- Lifecycle --- */
static inline void spdm_trace_init(const char *filename)
{
    g_spdm_trace_file = fopen(filename, "w");
}

static inline void spdm_trace_close(void)
{
    if (g_spdm_trace_file) {
        fclose(g_spdm_trace_file);
        g_spdm_trace_file = NULL;
    }
}

#endif /* SPDM_TRACE_H */
