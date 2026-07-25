/**
 * TLA+ trace emission library for libspdm VCA handshake.
 * Include guard compatible with all libspdm compilation units.
 */
#ifndef TLA_TRACE_H
#define TLA_TRACE_H

#include <stdint.h>

/* Alg type presence bitmask for req_alg_types / rsp_alg_types */
#define TLA_ALG_DHE          (1U << 0)
#define TLA_ALG_AEAD         (1U << 1)
#define TLA_ALG_REQ_ASYM     (1U << 2)
#define TLA_ALG_KEY_SCHEDULE (1U << 3)
#define TLA_ALG_REQ_PQC_ASYM (1U << 4)
#define TLA_ALG_KEM          (1U << 5)

/* Open / close the active trace file.
 * All emit calls between open and close write to this file.
 * Calls outside open/close are no-ops. */
void tla_trace_open(const char *filename);
void tla_trace_close(void);

/* VERSION phase */
void tla_trace_req_send_get_version(uint32_t conn_state);

/* rsp_handle_get_version: offered_ver_byte is (spdm_version_number >> 8) & 0xFF
 * e.g. 0x12 for "1.2", 0x13 for "1.3" */
void tla_trace_rsp_handle_get_version(uint32_t conn_state, uint8_t offered_ver_byte);

void tla_trace_req_handle_version(uint32_t conn_state, uint8_t negotiated_ver_byte);

/* CAPABILITIES phase */
void tla_trace_req_send_get_capabilities(uint32_t conn_state, uint32_t req_cap_flags);

void tla_trace_rsp_handle_get_capabilities(uint32_t conn_state,
                                           uint32_t req_cap_flags,
                                           uint32_t rsp_cap_flags);

void tla_trace_req_handle_capabilities(uint32_t conn_state, uint32_t rsp_cap_flags);

/* Error paths (F4) */
void tla_trace_rsp_error_capabilities(uint32_t conn_state);

/* ALGORITHMS phase */
/* req_alg_types_mask: OR of TLA_ALG_* bits present in the request struct_table */
void tla_trace_req_send_negotiate_algorithms(uint32_t conn_state,
                                             uint32_t req_alg_types_mask);

void tla_trace_rsp_handle_negotiate_algorithms(uint32_t conn_state,
                                               uint32_t base_hash_algo,
                                               uint32_t base_asym_algo,
                                               uint32_t measurement_spec,
                                               uint32_t measurement_hash_algo,
                                               uint32_t dhe_algo,
                                               uint32_t aead_algo,
                                               uint32_t req_asym_algo,
                                               uint32_t key_schedule_algo,
                                               uint32_t rsp_alg_types_mask);

void tla_trace_req_handle_algorithms(uint32_t conn_state,
                                     uint32_t base_hash_algo,
                                     uint32_t base_asym_algo,
                                     uint32_t measurement_spec,
                                     uint32_t measurement_hash_algo,
                                     uint32_t rsp_alg_types_mask);

void tla_trace_rsp_error_algorithms(uint32_t conn_state);

/* Explicit context reset (called from test code, not from libspdm_reset_context) */
void tla_trace_context_reset(uint32_t conn_state_before);

#endif /* TLA_TRACE_H */
