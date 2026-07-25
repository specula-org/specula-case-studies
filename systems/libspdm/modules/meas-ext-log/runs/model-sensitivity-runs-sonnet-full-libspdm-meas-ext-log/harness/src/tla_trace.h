/**
 * TLA+ trace emission interface for libspdm MEL paged-transfer instrumentation.
 * Include this header from instrumented library source files.
 */
#ifndef TLA_TRACE_H
#define TLA_TRACE_H

#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stddef.h>

/* Globals set by the test harness before exercising the library */
extern FILE    *g_tla_trace_file;
extern int      g_tla_seq;
extern uint32_t g_mel_generation_counter;

/* Open/close the trace file for one scenario */
void tla_trace_open(const char *path);
void tla_trace_close(void);

/* ---- Emit functions (called from instrumented library code) ---- */

/* negotiate_algorithms — from libspdm_req_negotiate_algorithms.c */
void tla_emit_negotiate_algorithms(void *spdm_context, uint8_t mel_spec_wire);

/* send events — from libspdm_req_get_measurement_extension_log.c */
void tla_emit_send_get_mel_first_chunk(void *spdm_context, uint32_t req_length);
void tla_emit_send_get_mel_next_chunk(void *spdm_context, uint32_t req_offset,
                                      uint32_t req_length);

/* respond events — from libspdm_rsp_measurement_extension_log.c */
void tla_emit_mel_update(size_t mel_size, uint32_t generation);
void tla_emit_respond_get_mel_first_chunk(void *spdm_context, uint32_t portion_len,
                                          uint32_t remainder_len, size_t mel_size,
                                          uint32_t generation);
void tla_emit_respond_get_mel_next_chunk(void *spdm_context, uint32_t portion_len,
                                         uint32_t remainder_len, size_t mel_size,
                                         uint32_t generation);

/* process events — from libspdm_req_get_measurement_extension_log.c */
void tla_emit_process_mel_first_chunk_resp(void *spdm_context, size_t mel_offset,
                                           uint32_t first_portion_len, bool is_done,
                                           uint32_t mel_snapshot_gen);
void tla_emit_process_mel_next_chunk_resp(void *spdm_context, size_t mel_offset,
                                          bool is_done);

#endif /* TLA_TRACE_H */
