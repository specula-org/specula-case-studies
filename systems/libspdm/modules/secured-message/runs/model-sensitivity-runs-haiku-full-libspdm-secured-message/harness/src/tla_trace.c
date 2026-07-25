#include "tla_trace.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <time.h>

static FILE *g_trace_file = NULL;
static pthread_mutex_t g_trace_mutex = PTHREAD_MUTEX_INITIALIZER;

static uint64_t get_timestamp_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static void emit_json_event(const char *event_name, const char *role,
                            const char *session_id, tla_state_t *state)
{
    uint64_t ts = get_timestamp_ns();

    fprintf(g_trace_file,
            "{\"tag\":\"trace\",\"event\":\"%s\",\"role\":\"%s\",\"session_id\":\"%s\","
            "\"timestamp\":%llu,\"state\":{"
            "\"session_state\":%llu,\"request_seq_num\":%llu,\"response_seq_num\":%llu,"
            "\"sequence_number_endian\":%u,\"endian_determined_at\":%lld,"
            "\"key_update_phase\":%u,\"backup_valid\":%s,"
            "\"application_secret\":\"%s\",\"application_secret_backup\":\"%s\","
            "\"secrets_cleared\":%s}}\n",
            event_name, role, session_id, (unsigned long long)ts,
            (unsigned long long)state->session_state,
            (unsigned long long)state->request_seq_num,
            (unsigned long long)state->response_seq_num,
            state->sequence_number_endian,
            (long long)state->endian_determined_at,
            state->key_update_phase,
            state->backup_valid ? "true" : "false",
            state->application_secret ? state->application_secret : "null",
            state->application_secret_backup ? state->application_secret_backup : "null",
            state->secrets_cleared ? "true" : "false");
    fflush(g_trace_file);
}

void tla_trace_init(const char *trace_file)
{
    pthread_mutex_lock(&g_trace_mutex);
    if (g_trace_file != NULL) {
        fclose(g_trace_file);
    }
    g_trace_file = fopen(trace_file, "w");
    if (g_trace_file == NULL) {
        fprintf(stderr, "Failed to open trace file: %s\n", trace_file);
        exit(1);
    }
    pthread_mutex_unlock(&g_trace_mutex);
}

void tla_trace_emit_transition_to_established(const char *role, const char *session_id,
                                               uint64_t session_state_before,
                                               uint64_t session_state_after,
                                               bool secrets_cleared_after)
{
    pthread_mutex_lock(&g_trace_mutex);
    uint64_t ts = get_timestamp_ns();

    fprintf(g_trace_file,
            "{\"tag\":\"trace\",\"event\":\"transition_to_established\",\"role\":\"%s\","
            "\"session_id\":\"%s\",\"timestamp\":%llu,"
            "\"message\":{\"session_state_before\":%llu,\"session_state_after\":%llu,"
            "\"secrets_cleared_after\":%s}}\n",
            role, session_id, (unsigned long long)ts,
            (unsigned long long)session_state_before,
            (unsigned long long)session_state_after,
            secrets_cleared_after ? "true" : "false");
    fflush(g_trace_file);
    pthread_mutex_unlock(&g_trace_mutex);
}

void tla_trace_emit_complete_zeroization(const char *role, const char *session_id,
                                          tla_state_t *state,
                                          bool secrets_cleared_before,
                                          bool secrets_cleared_after)
{
    pthread_mutex_lock(&g_trace_mutex);
    uint64_t ts = get_timestamp_ns();

    fprintf(g_trace_file,
            "{\"tag\":\"trace\",\"event\":\"complete_zeroization\",\"role\":\"%s\","
            "\"session_id\":\"%s\",\"timestamp\":%llu,\"state\":{"
            "\"session_state\":%llu},\"message\":{"
            "\"secrets_cleared_before\":%s,\"secrets_cleared_after\":%s}}\n",
            role, session_id, (unsigned long long)ts,
            (unsigned long long)state->session_state,
            secrets_cleared_before ? "true" : "false",
            secrets_cleared_after ? "true" : "false");
    fflush(g_trace_file);
    pthread_mutex_unlock(&g_trace_mutex);
}

void tla_trace_emit_encode_message(const char *role, const char *session_id,
                                    tla_state_t *state,
                                    uint64_t sequence_number_before,
                                    uint64_t sequence_number_after,
                                    const char *key_used,
                                    const uint8_t *iv, size_t iv_size,
                                    size_t cipher_text_size)
{
    pthread_mutex_lock(&g_trace_mutex);
    uint64_t ts = get_timestamp_ns();

    fprintf(g_trace_file,
            "{\"tag\":\"trace\",\"event\":\"encode_message\",\"role\":\"%s\","
            "\"session_id\":\"%s\",\"timestamp\":%llu,\"state\":{"
            "\"session_state\":%llu,\"request_seq_num\":%llu},\"message\":{"
            "\"sequence_number_before\":%llu,\"sequence_number_after\":%llu,"
            "\"key_used\":\"%s\",\"cipher_text_size\":%zu}}\n",
            role, session_id, (unsigned long long)ts,
            (unsigned long long)state->session_state,
            (unsigned long long)state->request_seq_num,
            (unsigned long long)sequence_number_before,
            (unsigned long long)sequence_number_after,
            key_used ? key_used : "unknown",
            cipher_text_size);
    fflush(g_trace_file);
    pthread_mutex_unlock(&g_trace_mutex);
}

void tla_trace_emit_decode_first_endian(const char *role, const char *session_id,
                                         tla_state_t *state,
                                         uint64_t response_seq_num_before,
                                         uint64_t response_seq_num_after,
                                         uint8_t endian_attempted,
                                         uint8_t endian_determined,
                                         int64_t endian_determined_at_seq,
                                         bool decryption_success)
{
    pthread_mutex_lock(&g_trace_mutex);
    uint64_t ts = get_timestamp_ns();

    fprintf(g_trace_file,
            "{\"tag\":\"trace\",\"event\":\"decode_first_endian\",\"role\":\"%s\","
            "\"session_id\":\"%s\",\"timestamp\":%llu,\"state\":{"
            "\"session_state\":%llu,\"response_seq_num\":%llu,"
            "\"sequence_number_endian\":%u},\"message\":{"
            "\"response_seq_num_before\":%llu,\"response_seq_num_after\":%llu,"
            "\"endian_attempted\":%u,\"endian_determined\":%u,"
            "\"endian_determined_at_seq\":%lld,\"decryption_success\":%s}}\n",
            role, session_id, (unsigned long long)ts,
            (unsigned long long)state->session_state,
            (unsigned long long)state->response_seq_num,
            state->sequence_number_endian,
            (unsigned long long)response_seq_num_before,
            (unsigned long long)response_seq_num_after,
            endian_attempted, endian_determined,
            (long long)endian_determined_at_seq,
            decryption_success ? "true" : "false");
    fflush(g_trace_file);
    pthread_mutex_unlock(&g_trace_mutex);
}

void tla_trace_emit_initiate_key_update(const char *role, const char *session_id,
                                         tla_state_t *state,
                                         uint8_t key_update_phase_before,
                                         uint8_t key_update_phase_after,
                                         bool backup_valid_after,
                                         const char *application_secret_backup,
                                         const char *application_secret_new)
{
    pthread_mutex_lock(&g_trace_mutex);
    uint64_t ts = get_timestamp_ns();

    fprintf(g_trace_file,
            "{\"tag\":\"trace\",\"event\":\"initiate_key_update\",\"role\":\"%s\","
            "\"session_id\":\"%s\",\"timestamp\":%llu,\"state\":{"
            "\"session_state\":%llu,\"key_update_phase\":%u,\"backup_valid\":%s},"
            "\"message\":{\"key_update_phase_before\":%u,\"key_update_phase_after\":%u,"
            "\"backup_valid_after\":%s,\"application_secret_backup\":\"%s\","
            "\"application_secret_new\":\"%s\"}}\n",
            role, session_id, (unsigned long long)ts,
            (unsigned long long)state->session_state,
            state->key_update_phase,
            state->backup_valid ? "true" : "false",
            key_update_phase_before, key_update_phase_after,
            backup_valid_after ? "true" : "false",
            application_secret_backup ? application_secret_backup : "unknown",
            application_secret_new ? application_secret_new : "unknown");
    fflush(g_trace_file);
    pthread_mutex_unlock(&g_trace_mutex);
}

void tla_trace_emit_confirm_key_update(const char *role, const char *session_id,
                                        tla_state_t *state,
                                        uint8_t key_update_phase_before,
                                        uint8_t key_update_phase_after,
                                        bool backup_valid_before,
                                        bool backup_valid_after)
{
    pthread_mutex_lock(&g_trace_mutex);
    uint64_t ts = get_timestamp_ns();

    fprintf(g_trace_file,
            "{\"tag\":\"trace\",\"event\":\"confirm_key_update\",\"role\":\"%s\","
            "\"session_id\":\"%s\",\"timestamp\":%llu,\"state\":{"
            "\"session_state\":%llu,\"key_update_phase\":%u,\"backup_valid\":%s},"
            "\"message\":{\"key_update_phase_before\":%u,\"key_update_phase_after\":%u,"
            "\"backup_valid_before\":%s,\"backup_valid_after\":%s}}\n",
            role, session_id, (unsigned long long)ts,
            (unsigned long long)state->session_state,
            state->key_update_phase,
            state->backup_valid ? "true" : "false",
            key_update_phase_before, key_update_phase_after,
            backup_valid_before ? "true" : "false",
            backup_valid_after ? "true" : "false");
    fflush(g_trace_file);
    pthread_mutex_unlock(&g_trace_mutex);
}

void tla_trace_emit_rollback_backup_key(const char *role, const char *session_id,
                                         tla_state_t *state,
                                         uint8_t key_update_phase_before,
                                         uint8_t key_update_phase_after,
                                         const char *application_secret_before,
                                         const char *application_secret_after,
                                         bool backup_valid_after)
{
    pthread_mutex_lock(&g_trace_mutex);
    uint64_t ts = get_timestamp_ns();

    fprintf(g_trace_file,
            "{\"tag\":\"trace\",\"event\":\"rollback_backup_key\",\"role\":\"%s\","
            "\"session_id\":\"%s\",\"timestamp\":%llu,\"state\":{"
            "\"session_state\":%llu,\"key_update_phase\":%u,\"backup_valid\":%s},"
            "\"message\":{\"key_update_phase_before\":%u,\"key_update_phase_after\":%u,"
            "\"application_secret_before\":\"%s\",\"application_secret_after\":\"%s\","
            "\"backup_valid_after\":%s}}\n",
            role, session_id, (unsigned long long)ts,
            (unsigned long long)state->session_state,
            state->key_update_phase,
            state->backup_valid ? "true" : "false",
            key_update_phase_before, key_update_phase_after,
            application_secret_before ? application_secret_before : "unknown",
            application_secret_after ? application_secret_after : "unknown",
            backup_valid_after ? "true" : "false");
    fflush(g_trace_file);
    pthread_mutex_unlock(&g_trace_mutex);
}

void tla_trace_shutdown(void)
{
    pthread_mutex_lock(&g_trace_mutex);
    if (g_trace_file != NULL) {
        fclose(g_trace_file);
        g_trace_file = NULL;
    }
    pthread_mutex_unlock(&g_trace_mutex);
}
