/**
 * TLA+ trace emission implementation for libspdm MEL paged-transfer.
 * Linked into the test_mel_trace binary alongside the instrumented libraries.
 */
#include "tla_trace.h"
#include "internal/libspdm_common_lib.h"
#include <string.h>

FILE    *g_tla_trace_file       = NULL;
int      g_tla_seq              = 0;
uint32_t g_mel_generation_counter = 0;

/* ---- helpers ---- */

static const char *conn_state_str(void *spdm_context)
{
    libspdm_context_t *ctx = (libspdm_context_t *)spdm_context;
    return (ctx->connection_info.connection_state >=
            LIBSPDM_CONNECTION_STATE_NEGOTIATED) ? "negotiated" : "init";
}

static bool has_session_cap(void *spdm_context)
{
    return libspdm_is_capabilities_flag_supported(
               spdm_context, true,
               SPDM_GET_CAPABILITIES_REQUEST_FLAGS_KEY_EX_CAP,
               SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_KEY_EX_CAP) ||
           libspdm_is_capabilities_flag_supported(
               spdm_context, true,
               SPDM_GET_CAPABILITIES_REQUEST_FLAGS_PSK_CAP,
               SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_PSK_CAP);
}

/* ---- open/close ---- */

void tla_trace_open(const char *path)
{
    g_tla_trace_file = fopen(path, "w");
    g_tla_seq = 0;
    g_mel_generation_counter = 0;
}

void tla_trace_close(void)
{
    if (g_tla_trace_file) {
        fflush(g_tla_trace_file);
        fclose(g_tla_trace_file);
        g_tla_trace_file = NULL;
    }
}

/* ---- emit functions ---- */

void tla_emit_negotiate_algorithms(void *spdm_context, uint8_t mel_spec_wire)
{
    if (!g_tla_trace_file) return;
    libspdm_context_t *ctx = (libspdm_context_t *)spdm_context;
    bool sc = has_session_cap(ctx);
    fprintf(g_tla_trace_file,
        "{\"event\":\"negotiate_algorithms\",\"seq\":%d,\"node\":\"req\","
        "\"mel_spec_wire\":%d,"
        "\"mel_spec_conn\":%d,"
        "\"has_session_cap\":%s,"
        "\"conn_state\":\"%s\"}\n",
        g_tla_seq++,
        (int)mel_spec_wire,
        (int)ctx->connection_info.algorithm.mel_spec,
        sc ? "true" : "false",
        conn_state_str(ctx));
}

void tla_emit_send_get_mel_first_chunk(void *spdm_context, uint32_t req_length)
{
    if (!g_tla_trace_file) return;
    libspdm_context_t *ctx = (libspdm_context_t *)spdm_context;
    fprintf(g_tla_trace_file,
        "{\"event\":\"send_get_mel_first_chunk\",\"seq\":%d,\"node\":\"req\","
        "\"req_offset\":0,"
        "\"req_length\":%u,"
        "\"conn_state\":\"%s\","
        "\"mel_offset\":0}\n",
        g_tla_seq++,
        req_length,
        conn_state_str(ctx));
}

void tla_emit_send_get_mel_next_chunk(void *spdm_context, uint32_t req_offset,
                                      uint32_t req_length)
{
    if (!g_tla_trace_file) return;
    (void)spdm_context;
    fprintf(g_tla_trace_file,
        "{\"event\":\"send_get_mel_next_chunk\",\"seq\":%d,\"node\":\"req\","
        "\"req_offset\":%u,"
        "\"req_length\":%u}\n",
        g_tla_seq++,
        req_offset,
        req_length);
}

void tla_emit_mel_update(size_t mel_size, uint32_t generation)
{
    if (!g_tla_trace_file) return;
    fprintf(g_tla_trace_file,
        "{\"event\":\"mel_update\",\"seq\":%d,\"node\":\"rsp\","
        "\"mel_generation\":%u,"
        "\"mel_size\":%u}\n",
        g_tla_seq++,
        generation,
        (unsigned)mel_size);
}

void tla_emit_respond_get_mel_first_chunk(void *spdm_context, uint32_t portion_len,
                                          uint32_t remainder_len, size_t mel_size,
                                          uint32_t generation)
{
    if (!g_tla_trace_file) return;
    (void)spdm_context;
    fprintf(g_tla_trace_file,
        "{\"event\":\"respond_get_mel_first_chunk\",\"seq\":%d,\"node\":\"rsp\","
        "\"portion_length\":%u,"
        "\"remainder_length\":%u,"
        "\"mel_generation\":%u,"
        "\"mel_size\":%u}\n",
        g_tla_seq++,
        portion_len,
        remainder_len,
        generation,
        (unsigned)mel_size);
}

void tla_emit_respond_get_mel_next_chunk(void *spdm_context, uint32_t portion_len,
                                         uint32_t remainder_len, size_t mel_size,
                                         uint32_t generation)
{
    if (!g_tla_trace_file) return;
    (void)spdm_context;
    fprintf(g_tla_trace_file,
        "{\"event\":\"respond_get_mel_next_chunk\",\"seq\":%d,\"node\":\"rsp\","
        "\"portion_length\":%u,"
        "\"remainder_length\":%u,"
        "\"mel_generation\":%u,"
        "\"mel_size\":%u}\n",
        g_tla_seq++,
        portion_len,
        remainder_len,
        generation,
        (unsigned)mel_size);
}

void tla_emit_process_mel_first_chunk_resp(void *spdm_context, size_t mel_offset,
                                           uint32_t first_portion_len, bool is_done,
                                           uint32_t mel_snapshot_gen)
{
    if (!g_tla_trace_file) return;
    (void)spdm_context;
    fprintf(g_tla_trace_file,
        "{\"event\":\"process_mel_first_chunk_resp\",\"seq\":%d,\"node\":\"req\","
        "\"mel_offset\":%u,"
        "\"first_portion_len\":%u,"
        "\"transfer_state\":\"%s\","
        "\"mel_snapshot_gen\":%u}\n",
        g_tla_seq++,
        (unsigned)mel_offset,
        first_portion_len,
        is_done ? "done" : "pending",
        mel_snapshot_gen);
}

void tla_emit_process_mel_next_chunk_resp(void *spdm_context, size_t mel_offset,
                                          bool is_done)
{
    if (!g_tla_trace_file) return;
    (void)spdm_context;
    fprintf(g_tla_trace_file,
        "{\"event\":\"process_mel_next_chunk_resp\",\"seq\":%d,\"node\":\"req\","
        "\"mel_offset\":%u,"
        "\"transfer_state\":\"%s\"}\n",
        g_tla_seq++,
        (unsigned)mel_offset,
        is_done ? "done" : "pending");
}
