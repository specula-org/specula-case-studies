#include "tla_trace.h"
#include <string.h>
#include <stdlib.h>

static FILE *g_trace_file = NULL;
static pthread_mutex_t g_trace_mutex = PTHREAD_MUTEX_INITIALIZER;

void tla_trace_init(const char *trace_file)
{
    pthread_mutex_lock(&g_trace_mutex);
    if (g_trace_file != NULL) {
        fclose(g_trace_file);
    }
    g_trace_file = fopen(trace_file, "w");
    if (g_trace_file == NULL) {
        fprintf(stderr, "Failed to open trace file: %s\n", trace_file);
    }
    pthread_mutex_unlock(&g_trace_mutex);
}

void tla_trace_close(void)
{
    pthread_mutex_lock(&g_trace_mutex);
    if (g_trace_file != NULL) {
        fclose(g_trace_file);
        g_trace_file = NULL;
    }
    pthread_mutex_unlock(&g_trace_mutex);
}

uint64_t tla_trace_now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

void tla_trace_emit(
    const char *event_name,
    const char *role,
    uint8_t spdm_version,
    bool session_established,
    uint32_t session_id,
    bool has_sig_cap,
    const char *request_format_version,
    const char *response_format_version,
    const char *req_message_type,
    const char *resp_message_type,
    const char *message_m_state,
    uint32_t transcript_appended_count,
    bool computed_signature,
    bool opaque_data_enabled,
    bool opaque_data_validated,
    uint64_t requester_context_sent,
    uint64_t requester_context_received,
    bool requester_context_validated,
    uint8_t slot_id_used,
    bool slot_id_validated,
    bool pubkey_available,
    const bool *cert_available,
    int cert_available_count,
    bool signature_requested)
{
    if (g_trace_file == NULL) {
        return;
    }

    pthread_mutex_lock(&g_trace_mutex);

    uint64_t now_ns = tla_trace_now_ns();

    /* Write JSON event */
    fprintf(g_trace_file,
        "{"
        "\"event_name\":\"%s\","
        "\"role\":\"%s\","
        "\"timestamp_ns\":%llu,"
        "\"spdm_version\":\"0x%02x\","
        "\"session_established\":%s,"
        "\"session_id\":%u,"
        "\"has_sig_cap\":%s,"
        "\"request_format_version\":\"%s\","
        "\"response_format_version\":\"%s\","
        "\"req_message_type\":\"%s\","
        "\"resp_message_type\":\"%s\","
        "\"message_m_state\":\"%s\","
        "\"transcript_appended_count\":%u,"
        "\"computed_signature\":%s,"
        "\"opaque_data_enabled\":%s,"
        "\"opaque_data_validated\":%s,"
        "\"requester_context_sent\":%llu,"
        "\"requester_context_received\":%llu,"
        "\"requester_context_validated\":%s,"
        "\"slot_id_used\":%u,"
        "\"slot_id_validated\":%s,"
        "\"pubkey_available\":%s,"
        "\"cert_available\":[",
        event_name,
        role,
        (unsigned long long)now_ns,
        spdm_version,
        session_established ? "true" : "false",
        session_id,
        has_sig_cap ? "true" : "false",
        request_format_version,
        response_format_version,
        req_message_type,
        resp_message_type,
        message_m_state,
        transcript_appended_count,
        computed_signature ? "true" : "false",
        opaque_data_enabled ? "true" : "false",
        opaque_data_validated ? "true" : "false",
        (unsigned long long)requester_context_sent,
        (unsigned long long)requester_context_received,
        requester_context_validated ? "true" : "false",
        slot_id_used,
        slot_id_validated ? "true" : "false",
        pubkey_available ? "true" : "false"
    );

    /* Write cert_available array */
    for (int i = 0; i < cert_available_count; i++) {
        fprintf(g_trace_file, "%s", cert_available[i] ? "true" : "false");
        if (i < cert_available_count - 1) {
            fprintf(g_trace_file, ",");
        }
    }

    fprintf(g_trace_file,
        "],"
        "\"signature_requested\":%s"
        "}\n",
        signature_requested ? "true" : "false"
    );

    fflush(g_trace_file);
    pthread_mutex_unlock(&g_trace_mutex);
}
