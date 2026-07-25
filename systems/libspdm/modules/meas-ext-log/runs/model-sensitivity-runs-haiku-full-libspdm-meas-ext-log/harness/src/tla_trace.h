#ifndef TLA_TRACE_H
#define TLA_TRACE_H

#include <stdint.h>
#include <stddef.h>
#include <time.h>

/* Initialization and shutdown */
void tla_trace_init(const char *trace_file);
void tla_trace_shutdown(void);

/* Event emission - requester events */
void tla_trace_req_send_get_mel(
    uint32_t msg_offset,
    uint32_t msg_length,
    uint32_t req_offset,
    uint32_t req_mel_size,
    uint32_t req_remainder,
    uint32_t req_total_mel_size,
    const char *req_pc);

void tla_trace_req_receive_mel_response(
    uint32_t recv_portion_length,
    uint32_t recv_remainder_length,
    uint32_t req_mel_size,
    uint32_t req_offset,
    uint32_t req_remainder,
    uint32_t req_total_mel_size,
    const char *req_pc);

void tla_trace_req_check_termination(
    uint32_t req_mel_size,
    uint32_t req_offset,
    const char *req_pc);

/* Event emission - responder events */
void tla_trace_resp_receive_and_send_mel(
    uint32_t msg_portion_length,
    uint32_t msg_remainder_length,
    uint32_t msg_data_len,
    uint32_t responder_mel_size,
    uint32_t responder_mel_entries_len);

/* Error event */
void tla_trace_error(const char *event_name, const char *error_code);

/* Initialize event - at startup */
void tla_trace_init_event(
    uint32_t responder_mel_size,
    uint32_t responder_mel_entries_len,
    uint32_t req_offset,
    uint32_t req_mel_size,
    uint32_t req_remainder,
    uint32_t req_total_mel_size,
    const char *req_pc,
    const char *responder_pc);

#endif /* TLA_TRACE_H */
