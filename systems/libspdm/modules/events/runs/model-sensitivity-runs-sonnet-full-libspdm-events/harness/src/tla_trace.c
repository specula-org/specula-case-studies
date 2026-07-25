/**
 * TLA+ Trace Emission Library — Implementation
 * Emits NDJSON trace lines to the file opened by tla_trace_init().
 */

#ifdef TLA_TRACE_ENABLED

#define _POSIX_C_SOURCE 200112L
#include "tla_trace.h"
#include <stdio.h>
#include <string.h>
#include <time.h>

tla_trace_shadow_t g_tla_shadow;
static FILE *g_tla_file = NULL;

void tla_trace_init(const char *path)
{
    g_tla_file = fopen(path, "w");
    /* Reset all shadow fields to initial state */
    strncpy(g_tla_shadow.subscription_state, "SUB_NONE",
            sizeof(g_tla_shadow.subscription_state) - 1);
    g_tla_shadow.subscription_state[sizeof(g_tla_shadow.subscription_state) - 1] = '\0';
    g_tla_shadow.subscribe_types_sent = false;
    g_tla_shadow.direct_send_active = false;
    strncpy(g_tla_shadow.last_send_event_response, "NONE",
            sizeof(g_tla_shadow.last_send_event_response) - 1);
    g_tla_shadow.last_send_event_response[sizeof(g_tla_shadow.last_send_event_response) - 1] = '\0';
    g_tla_shadow.encap_event_in_flight = false;
    g_tla_shadow.event_all_policy = false;
}

void tla_trace_close(void)
{
    if (g_tla_file) {
        fflush(g_tla_file);
        fclose(g_tla_file);
        g_tla_file = NULL;
    }
}

static uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

#define TF(b) ((b) ? "true" : "false")

static void emit_line(const char *event, const char *params,
                      const char *sess_state, const char *resp_state)
{
    if (!g_tla_file) return;
    fprintf(g_tla_file,
        "{\"tag\":\"trace\",\"ts\":\"%llu\",\"event\":\"%s\","
        "\"params\":{%s},"
        "\"post\":{"
        "\"session_state\":\"%s\","
        "\"response_state\":\"%s\","
        "\"subscription_state\":\"%s\","
        "\"event_all_policy\":%s,"
        "\"subscribe_types_sent\":%s,"
        "\"encap_event_in_flight\":%s,"
        "\"direct_send_active\":%s,"
        "\"last_send_event_response\":\"%s\""
        "}}\n",
        (unsigned long long)now_ns(),
        event, params,
        sess_state, resp_state,
        g_tla_shadow.subscription_state,
        TF(g_tla_shadow.event_all_policy),
        TF(g_tla_shadow.subscribe_types_sent),
        TF(g_tla_shadow.encap_event_in_flight),
        TF(g_tla_shadow.direct_send_active),
        g_tla_shadow.last_send_event_response);
    fflush(g_tla_file);
}

void tla_emit_key_exchange(bool with_event_all)
{
    /* Reset session-scoped shadow fields */
    g_tla_shadow.event_all_policy      = with_event_all;
    g_tla_shadow.subscribe_types_sent  = false;
    g_tla_shadow.direct_send_active    = false;
    g_tla_shadow.encap_event_in_flight = false;
    strncpy(g_tla_shadow.last_send_event_response, "NONE",
            sizeof(g_tla_shadow.last_send_event_response) - 1);
    if (with_event_all) {
        strncpy(g_tla_shadow.subscription_state, "SUB_ALL",
                sizeof(g_tla_shadow.subscription_state) - 1);
    } else {
        strncpy(g_tla_shadow.subscription_state, "SUB_NONE",
                sizeof(g_tla_shadow.subscription_state) - 1);
    }

    char params[64];
    snprintf(params, sizeof(params), "\"with_event_all\":%s", TF(with_event_all));
    emit_line("HandleKeyExchange", params, "HANDSHAKE", "NORMAL");
}

void tla_emit_handle_finish(void)
{
    emit_line("HandleFinish", "", "ESTABLISHED", "NORMAL");
}

void tla_emit_subscribe_event_types(bool subscribe_none, uint8_t subscribe_type)
{
    /* subscribe_type: LIBSPDM_EVENT_SUBSCRIBE_NONE=1, LIBSPDM_EVENT_SUBSCRIBE_LIST=2 */
    if (subscribe_type == 1) {
        strncpy(g_tla_shadow.subscription_state, "SUB_NONE",
                sizeof(g_tla_shadow.subscription_state) - 1);
    } else {
        strncpy(g_tla_shadow.subscription_state, "SUB_LIST",
                sizeof(g_tla_shadow.subscription_state) - 1);
    }
    g_tla_shadow.subscribe_types_sent = true;

    char params[64];
    snprintf(params, sizeof(params), "\"subscribe_none\":%s", TF(subscribe_none));
    emit_line("HandleSubscribeEventTypes", params, "ESTABLISHED", "NORMAL");
}

void tla_emit_send_event_version_mismatch(const char *resp_state)
{
    g_tla_shadow.direct_send_active = true;
    strncpy(g_tla_shadow.last_send_event_response, "VERSION_MISMATCH",
            sizeof(g_tla_shadow.last_send_event_response) - 1);
    emit_line("HandleSendEventVersionMismatch", "", "ESTABLISHED", resp_state);
}

void tla_emit_send_event_version_match(const char *resp_state)
{
    g_tla_shadow.direct_send_active = true;
    if (strcmp(resp_state, "PROCESSING_ENCAP") == 0) {
        strncpy(g_tla_shadow.last_send_event_response, "REQUEST_IN_FLIGHT",
                sizeof(g_tla_shadow.last_send_event_response) - 1);
    } else {
        strncpy(g_tla_shadow.last_send_event_response, "OK",
                sizeof(g_tla_shadow.last_send_event_response) - 1);
    }
    emit_line("HandleSendEventVersionMatch", "", "ESTABLISHED", resp_state);
}

void tla_emit_send_event_complete(void)
{
    g_tla_shadow.direct_send_active = false;
    emit_line("HandleSendEventComplete", "", "ESTABLISHED", "NORMAL");
}

void tla_emit_init_encap_send_event(void)
{
    g_tla_shadow.encap_event_in_flight = true;
    emit_line("InitEncapSendEvent", "", "ESTABLISHED", "PROCESSING_ENCAP");
}

void tla_emit_handle_encap_send_event(void)
{
    emit_line("HandleEncapSendEvent", "", "ESTABLISHED", "PROCESSING_ENCAP");
}

void tla_emit_process_encap_event_ack(void)
{
    g_tla_shadow.encap_event_in_flight = false;
    /* response_state is cleared to NORMAL by caller after need_continue=false */
    emit_line("ProcessEncapEventAck", "", "ESTABLISHED", "NORMAL");
}

void tla_emit_terminate_session(void)
{
    /* Reset all shadow fields before emitting */
    strncpy(g_tla_shadow.subscription_state, "SUB_NONE",
            sizeof(g_tla_shadow.subscription_state) - 1);
    g_tla_shadow.subscribe_types_sent  = false;
    g_tla_shadow.direct_send_active    = false;
    g_tla_shadow.encap_event_in_flight = false;
    g_tla_shadow.event_all_policy      = false;
    strncpy(g_tla_shadow.last_send_event_response, "NONE",
            sizeof(g_tla_shadow.last_send_event_response) - 1);
    emit_line("TerminateSession", "", "NOT_STARTED", "NORMAL");
}

#endif /* TLA_TRACE_ENABLED */
