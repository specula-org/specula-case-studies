#ifndef TLA_TRACE_H
#define TLA_TRACE_H

#include <stdint.h>
#include <stdbool.h>
#include <time.h>

typedef struct {
    uint64_t session_state;
    uint64_t request_seq_num;
    uint64_t response_seq_num;
    uint8_t sequence_number_endian;
    int64_t endian_determined_at;
    uint8_t key_update_phase;
    bool backup_valid;
    const char *application_secret;
    const char *application_secret_backup;
    bool secrets_cleared;
} tla_state_t;

typedef struct {
    const char *event;
    const char *role;
    const char *session_id;
    uint64_t timestamp;
    tla_state_t state;
} tla_event_t;

void tla_trace_init(const char *trace_file);
void tla_trace_emit_transition_to_established(const char *role, const char *session_id,
                                               uint64_t session_state_before,
                                               uint64_t session_state_after,
                                               bool secrets_cleared_after);
void tla_trace_emit_complete_zeroization(const char *role, const char *session_id,
                                          tla_state_t *state,
                                          bool secrets_cleared_before,
                                          bool secrets_cleared_after);
void tla_trace_emit_encode_message(const char *role, const char *session_id,
                                    tla_state_t *state,
                                    uint64_t sequence_number_before,
                                    uint64_t sequence_number_after,
                                    const char *key_used,
                                    const uint8_t *iv, size_t iv_size,
                                    size_t cipher_text_size);
void tla_trace_emit_decode_first_endian(const char *role, const char *session_id,
                                         tla_state_t *state,
                                         uint64_t response_seq_num_before,
                                         uint64_t response_seq_num_after,
                                         uint8_t endian_attempted,
                                         uint8_t endian_determined,
                                         int64_t endian_determined_at_seq,
                                         bool decryption_success);
void tla_trace_emit_initiate_key_update(const char *role, const char *session_id,
                                         tla_state_t *state,
                                         uint8_t key_update_phase_before,
                                         uint8_t key_update_phase_after,
                                         bool backup_valid_after,
                                         const char *application_secret_backup,
                                         const char *application_secret_new);
void tla_trace_emit_confirm_key_update(const char *role, const char *session_id,
                                        tla_state_t *state,
                                        uint8_t key_update_phase_before,
                                        uint8_t key_update_phase_after,
                                        bool backup_valid_before,
                                        bool backup_valid_after);
void tla_trace_emit_rollback_backup_key(const char *role, const char *session_id,
                                         tla_state_t *state,
                                         uint8_t key_update_phase_before,
                                         uint8_t key_update_phase_after,
                                         const char *application_secret_before,
                                         const char *application_secret_after,
                                         bool backup_valid_after);
void tla_trace_shutdown(void);

#endif
