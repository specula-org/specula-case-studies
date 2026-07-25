#include "tla_trace.h"
#include <pthread.h>
#include <stdlib.h>
#include <stdio.h>

static FILE *g_trace_file = NULL;
static pthread_mutex_t g_trace_lock = PTHREAD_MUTEX_INITIALIZER;

int tla_trace_init(const char *trace_file) {
    pthread_mutex_lock(&g_trace_lock);
    if (g_trace_file != NULL) {
        fclose(g_trace_file);
    }
    g_trace_file = fopen(trace_file, "w");
    if (g_trace_file == NULL) {
        pthread_mutex_unlock(&g_trace_lock);
        return -1;
    }
    pthread_mutex_unlock(&g_trace_lock);
    return 0;
}

void tla_trace_shutdown(void) {
    pthread_mutex_lock(&g_trace_lock);
    if (g_trace_file != NULL) {
        fflush(g_trace_file);
        fclose(g_trace_file);
        g_trace_file = NULL;
    }
    pthread_mutex_unlock(&g_trace_lock);
}

void tla_bytes_to_hex(const uint8_t *data, size_t len, char *hex_out, size_t hex_len) {
    if (data == NULL || len == 0) {
        if (hex_len > 0) hex_out[0] = '\0';
        return;
    }
    size_t needed = len * 2 + 1;
    if (hex_len < needed) {
        if (hex_len > 0) hex_out[0] = '\0';
        return;
    }
    for (size_t i = 0; i < len; i++) {
        sprintf(hex_out + i * 2, "%02x", data[i]);
    }
    hex_out[len * 2] = '\0';
}

static void emit_event(
    const char *event_name,
    const char *node,
    uint64_t timestamp,
    const char *state_json,
    const char *message_json
) {
    pthread_mutex_lock(&g_trace_lock);
    if (g_trace_file != NULL) {
        fprintf(g_trace_file, "{\"tag\":\"trace\",\"event\":\"%s\",\"node\":\"%s\",\"timestamp\":%llu",
                event_name, node, (unsigned long long)timestamp);
        if (state_json && strlen(state_json) > 0) {
            fprintf(g_trace_file, ",%s", state_json);
        }
        if (message_json && strlen(message_json) > 0) {
            fprintf(g_trace_file, ",%s", message_json);
        }
        fprintf(g_trace_file, "}\n");
        fflush(g_trace_file);
    }
    pthread_mutex_unlock(&g_trace_lock);
}

static void add_quoted_field(char *buffer, size_t len, const char *value) {
    if (value == NULL) {
        snprintf(buffer, len, "null");
    } else {
        snprintf(buffer, len, "\"%s\"", value);
    }
}

static void build_state_json(char *buffer, size_t len,
                             tla_state_t state_before, tla_state_t state_after) {
    char cs_before[64], ap_before[64], ks_before[64];
    char cs_after[64], ap_after[64], ks_after[64];

    add_quoted_field(cs_before, sizeof(cs_before), state_before.connection_state);
    add_quoted_field(ap_before, sizeof(ap_before), state_before.authentication_phase);
    add_quoted_field(ks_before, sizeof(ks_before), state_before.key_source);
    add_quoted_field(cs_after, sizeof(cs_after), state_after.connection_state);
    add_quoted_field(ap_after, sizeof(ap_after), state_after.authentication_phase);
    add_quoted_field(ks_after, sizeof(ks_after), state_after.key_source);

    snprintf(buffer, len,
             "\"state_before\":{\"connection_state\":%s,\"authentication_phase\":%s,\"key_source\":%s},"
             "\"state_after\":{\"connection_state\":%s,\"authentication_phase\":%s,\"key_source\":%s}",
             cs_before, ap_before, ks_before, cs_after, ap_after, ks_after
    );
}

void tla_emit_requester_send_challenge(
    uint64_t timestamp,
    uint8_t slot_id,
    uint8_t version,
    const uint8_t *nonce,
    const uint8_t *context,
    tla_state_t state_before,
    tla_state_t state_after
) {
    char nonce_hex[65] = {0};
    char context_hex[65] = {0};
    char context_json[70] = "null";
    char state_buf[512];
    char msg_buf[1024];

    if (nonce) tla_bytes_to_hex(nonce, 32, nonce_hex, sizeof(nonce_hex));
    if (context) {
        tla_bytes_to_hex(context, 32, context_hex, sizeof(context_hex));
        snprintf(context_json, sizeof(context_json), "\"%s\"", context_hex);
    }

    build_state_json(state_buf, sizeof(state_buf), state_before, state_after);

    snprintf(msg_buf, sizeof(msg_buf),
             "\"slot_id\":%u,\"version\":%u,\"nonce\":\"%s\",\"context\":%s",
             slot_id, version,
             nonce_hex[0] ? nonce_hex : "null",
             context_json);

    emit_event("requester_send_challenge", "requester", timestamp, state_buf, msg_buf);
}

void tla_emit_responder_handle_challenge(
    uint64_t timestamp,
    uint8_t slot_id,
    const char *key_source,
    const uint8_t *nonce,
    uint32_t message_c_len,
    const uint8_t *context_echo,
    tla_state_t state_before,
    tla_state_t state_after
) {
    char nonce_hex[65] = {0};
    char context_hex[65] = {0};
    char key_source_json[50] = "null";
    char context_echo_json[70] = "null";
    char state_buf[512];
    char msg_buf[1024];

    if (nonce) tla_bytes_to_hex(nonce, 32, nonce_hex, sizeof(nonce_hex));
    if (context_echo) {
        tla_bytes_to_hex(context_echo, 32, context_hex, sizeof(context_hex));
        snprintf(context_echo_json, sizeof(context_echo_json), "\"%s\"", context_hex);
    }
    if (key_source) {
        snprintf(key_source_json, sizeof(key_source_json), "\"%s\"", key_source);
    }

    build_state_json(state_buf, sizeof(state_buf), state_before, state_after);

    snprintf(msg_buf, sizeof(msg_buf),
             "\"slot_id\":%u,\"key_source\":%s,\"nonce\":\"%s\",\"message_c_len\":%u,\"context_echo\":%s",
             slot_id,
             key_source_json,
             nonce_hex[0] ? nonce_hex : "null",
             message_c_len,
             context_echo_json);

    emit_event("responder_handle_challenge", "responder", timestamp, state_buf, msg_buf);
}

void tla_emit_requester_handle_challenge_auth(
    uint64_t timestamp,
    uint8_t slot_id,
    const char *key_source,
    const uint8_t *responder_nonce,
    int context_match,
    tla_state_t state_before,
    tla_state_t state_after
) {
    char nonce_hex[65] = {0};
    char key_source_json[50] = "null";
    char state_buf[512];
    char msg_buf[512];

    if (responder_nonce) tla_bytes_to_hex(responder_nonce, 32, nonce_hex, sizeof(nonce_hex));
    if (key_source) {
        snprintf(key_source_json, sizeof(key_source_json), "\"%s\"", key_source);
    }

    build_state_json(state_buf, sizeof(state_buf), state_before, state_after);

    snprintf(msg_buf, sizeof(msg_buf),
             "\"slot_id\":%u,\"key_source\":%s,\"responder_nonce\":\"%s\",\"context_match\":%s",
             slot_id,
             key_source_json,
             nonce_hex[0] ? nonce_hex : "null",
             context_match ? "true" : "false");

    emit_event("requester_handle_challenge_auth", "requester", timestamp, state_buf, msg_buf);
}

void tla_emit_responder_handle_encap_challenge(
    uint64_t timestamp,
    uint32_t message_mut_c_len,
    tla_state_t state_before,
    tla_state_t state_after
) {
    char state_buf[512];
    char msg_buf[256];

    build_state_json(state_buf, sizeof(state_buf), state_before, state_after);

    snprintf(msg_buf, sizeof(msg_buf),
             "\"message_mut_c_len\":%u",
             message_mut_c_len);

    emit_event("responder_handle_encap_challenge", "responder", timestamp, state_buf, msg_buf);
}

void tla_emit_requester_handle_encap_challenge_auth(
    uint64_t timestamp,
    tla_state_t state_before,
    tla_state_t state_after
) {
    char state_buf[512];

    build_state_json(state_buf, sizeof(state_buf), state_before, state_after);

    emit_event("requester_handle_encap_challenge_auth", "requester", timestamp, state_buf, "");
}
