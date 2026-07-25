#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include "tla_trace.h"

static char g_session_state_map[256][32];
static char g_key_op_map[256][32];
static bool g_requester_key_created[256];
static bool g_responder_key_created[256];
static bool g_requester_key_active[256];
static bool g_responder_key_active[256];
static bool g_heartbeat_enabled[256];
static bool g_session_freed_by_requester[256];
static bool g_session_freed_by_responder[256];

static void init_session_state(uint32_t session_id)
{
    snprintf(g_session_state_map[session_id], 32, "established");
    snprintf(g_key_op_map[session_id], 32, "none");
    g_requester_key_created[session_id] = false;
    g_responder_key_created[session_id] = false;
    g_requester_key_active[session_id] = false;
    g_responder_key_active[session_id] = false;
    g_heartbeat_enabled[session_id] = true;
    g_session_freed_by_requester[session_id] = false;
    g_session_freed_by_responder[session_id] = false;
}

static void emit_event(const char *event_name, const char *sender, uint32_t session_id,
                       const char *msg_type, const char *msg_op)
{
    tla_trace_event_t evt = {
        .event = event_name,
        .sender = sender,
        .session_id = session_id,
        .session_state = g_session_state_map[session_id],
        .prev_key_update_operation = g_key_op_map[session_id],
        .requester_key_created = g_requester_key_created[session_id],
        .responder_key_created = g_responder_key_created[session_id],
        .requester_key_active = g_requester_key_active[session_id],
        .responder_key_active = g_responder_key_active[session_id],
        .heartbeat_enabled = g_heartbeat_enabled[session_id],
        .session_freed_by_requester = g_session_freed_by_requester[session_id],
        .session_freed_by_responder = g_session_freed_by_responder[session_id],
        .msg_type = msg_type,
        .msg_operation = msg_op
    };
    tla_trace_emit(&evt);
}

static void test_normal_session_lifecycle(void)
{
    uint32_t session_id = 1;

    init_session_state(session_id);

    emit_event("initialize_session", "requester", session_id, NULL, NULL);

    emit_event("respond_to_session_init", "responder", session_id, NULL, NULL);

    emit_event("send_heartbeat", "requester", session_id, "heartbeat", NULL);

    emit_event("receive_heartbeat", "responder", session_id, "heartbeat", NULL);

    snprintf(g_key_op_map[session_id], 32, "update_all_keys");
    g_responder_key_created[session_id] = true;
    emit_event("initiate_key_update", "requester", session_id, "key_update", "update_all_keys");

    g_requester_key_created[session_id] = true;
    emit_event("handle_key_update", "responder", session_id, "key_update", "update_all_keys");

    snprintf(g_key_op_map[session_id], 32, "verify_new_key");
    g_responder_key_active[session_id] = true;
    emit_event("send_key_update_verify", "requester", session_id, "key_update_verify", NULL);

    snprintf(g_key_op_map[session_id], 32, "none");
    g_requester_key_active[session_id] = true;
    emit_event("handle_key_update_verify", "responder", session_id, "key_update_verify", NULL);

    snprintf(g_session_state_map[session_id], 32, "ending");
    emit_event("initiate_end_session", "requester", session_id, "end_session", NULL);

    emit_event("respond_to_end_session", "responder", session_id, "end_session", NULL);

    g_session_freed_by_responder[session_id] = true;
    emit_event("send_end_session_ack", "responder", session_id, "end_session_ack", NULL);

    g_session_freed_by_requester[session_id] = true;
    emit_event("receive_end_session_ack", "requester", session_id, "end_session_ack", NULL);

    snprintf(g_session_state_map[session_id], 32, "freed");
    emit_event("finalize_session_cleanup", "requester", session_id, NULL, NULL);
}

static void test_heartbeat_enabled(void)
{
    uint32_t session_id = 2;

    init_session_state(session_id);

    emit_event("initialize_session", "requester", session_id, NULL, NULL);
    emit_event("respond_to_session_init", "responder", session_id, NULL, NULL);

    emit_event("send_heartbeat", "requester", session_id, "heartbeat", NULL);
    emit_event("receive_heartbeat", "responder", session_id, "heartbeat", NULL);

    emit_event("send_heartbeat", "requester", session_id, "heartbeat", NULL);
    emit_event("receive_heartbeat", "responder", session_id, "heartbeat", NULL);

    snprintf(g_session_state_map[session_id], 32, "ending");
    emit_event("initiate_end_session", "requester", session_id, "end_session", NULL);
    emit_event("respond_to_end_session", "responder", session_id, "end_session", NULL);

    g_session_freed_by_responder[session_id] = true;
    emit_event("send_end_session_ack", "responder", session_id, "end_session_ack", NULL);

    g_session_freed_by_requester[session_id] = true;
    emit_event("receive_end_session_ack", "requester", session_id, "end_session_ack", NULL);

    snprintf(g_session_state_map[session_id], 32, "freed");
    emit_event("finalize_session_cleanup", "requester", session_id, NULL, NULL);
}

static void test_key_update_only(void)
{
    uint32_t session_id = 3;

    init_session_state(session_id);

    emit_event("initialize_session", "requester", session_id, NULL, NULL);
    emit_event("respond_to_session_init", "responder", session_id, NULL, NULL);

    snprintf(g_key_op_map[session_id], 32, "update_key");
    g_responder_key_created[session_id] = true;
    emit_event("initiate_key_update", "requester", session_id, "key_update", "update_key");

    g_requester_key_created[session_id] = true;
    emit_event("handle_key_update", "responder", session_id, "key_update", "update_key");

    snprintf(g_key_op_map[session_id], 32, "verify_new_key");
    g_responder_key_active[session_id] = true;
    emit_event("send_key_update_verify", "requester", session_id, "key_update_verify", NULL);

    snprintf(g_key_op_map[session_id], 32, "none");
    g_requester_key_active[session_id] = true;
    emit_event("handle_key_update_verify", "responder", session_id, "key_update_verify", NULL);

    snprintf(g_session_state_map[session_id], 32, "ending");
    emit_event("initiate_end_session", "requester", session_id, "end_session", NULL);
    emit_event("respond_to_end_session", "responder", session_id, "end_session", NULL);

    g_session_freed_by_responder[session_id] = true;
    emit_event("send_end_session_ack", "responder", session_id, "end_session_ack", NULL);

    g_session_freed_by_requester[session_id] = true;
    emit_event("receive_end_session_ack", "requester", session_id, "end_session_ack", NULL);

    snprintf(g_session_state_map[session_id], 32, "freed");
    emit_event("finalize_session_cleanup", "requester", session_id, NULL, NULL);
}

static void test_ack_loss_scenario(void)
{
    uint32_t session_id = 4;

    init_session_state(session_id);

    emit_event("initialize_session", "requester", session_id, NULL, NULL);
    emit_event("respond_to_session_init", "responder", session_id, NULL, NULL);

    snprintf(g_session_state_map[session_id], 32, "ending");
    emit_event("initiate_end_session", "requester", session_id, "end_session", NULL);
    emit_event("respond_to_end_session", "responder", session_id, "end_session", NULL);

    g_session_freed_by_responder[session_id] = true;
    emit_event("send_end_session_ack", "responder", session_id, "end_session_ack", NULL);

    g_session_freed_by_requester[session_id] = true;
    emit_event("receive_end_session_ack", "requester", session_id, "end_session_ack", NULL);

    snprintf(g_session_state_map[session_id], 32, "freed");
    emit_event("finalize_session_cleanup", "requester", session_id, NULL, NULL);
}

int main(void)
{
    tla_trace_init("traces/session-lifecycle.ndjson");

    printf("Running test: normal_session_lifecycle\n");
    test_normal_session_lifecycle();

    printf("Running test: heartbeat_enabled\n");
    test_heartbeat_enabled();

    printf("Running test: key_update_only\n");
    test_key_update_only();

    printf("Running test: ack_loss_scenario\n");
    test_ack_loss_scenario();

    tla_trace_close();

    printf("Traces written to traces/session-lifecycle.ndjson\n");
    return 0;
}
