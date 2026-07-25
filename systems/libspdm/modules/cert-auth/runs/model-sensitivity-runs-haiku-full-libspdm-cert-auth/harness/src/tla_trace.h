#ifndef TLA_TRACE_H
#define TLA_TRACE_H

#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <time.h>

/* ============ Trace Initialization ============ */
int tla_trace_init(const char *trace_file);
void tla_trace_shutdown(void);

/* ============ State Snapshot ============ */
typedef struct {
    const char *connection_state;  /* Pass as null or "null", "authenticated", "challenged", etc. */
    const char *authentication_phase;  /* Pass as "NONE", "ONE_WAY_STARTED", etc. - no quotes */
    const char *key_source;  /* Pass as null or "cert_chain", "public_key_only" - no quotes */
} tla_state_t;

/* ============ Event Emission ============ */
void tla_emit_requester_send_challenge(
    uint64_t timestamp,
    uint8_t slot_id,
    uint8_t version,
    const uint8_t *nonce,
    const uint8_t *context,
    tla_state_t state_before,
    tla_state_t state_after
);

void tla_emit_responder_handle_challenge(
    uint64_t timestamp,
    uint8_t slot_id,
    const char *key_source,
    const uint8_t *nonce,
    uint32_t message_c_len,
    const uint8_t *context_echo,
    tla_state_t state_before,
    tla_state_t state_after
);

void tla_emit_requester_handle_challenge_auth(
    uint64_t timestamp,
    uint8_t slot_id,
    const char *key_source,
    const uint8_t *responder_nonce,
    int context_match,
    tla_state_t state_before,
    tla_state_t state_after
);

void tla_emit_responder_handle_encap_challenge(
    uint64_t timestamp,
    uint32_t message_mut_c_len,
    tla_state_t state_before,
    tla_state_t state_after
);

void tla_emit_requester_handle_encap_challenge_auth(
    uint64_t timestamp,
    tla_state_t state_before,
    tla_state_t state_after
);

/* ============ Helper: Get current timestamp in microseconds ============ */
static inline uint64_t tla_get_timestamp_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000ULL + ts.tv_nsec / 1000ULL;
}

/* ============ Helper: Convert bytes to hex string ============ */
void tla_bytes_to_hex(const uint8_t *data, size_t len, char *hex_out, size_t hex_len);

#endif /* TLA_TRACE_H */
