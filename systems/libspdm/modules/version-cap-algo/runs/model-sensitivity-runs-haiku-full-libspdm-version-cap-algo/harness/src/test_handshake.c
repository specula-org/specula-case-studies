#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include "tla_trace.h"
#include "state_capture.h"

/* Mock SPDM context structure for testing */
typedef struct {
    int is_requester;
    int connection_state;
    uint8_t version;
    int capabilities_negotiated;
    int algorithms_negotiated;
} mock_spdm_context_t;

/* Simple handshake scenario - exercises the protocol flow */
int test_scenario_1_normal_handshake(void) {
    printf("Test Scenario 1: Normal handshake\n");

    /* Initialize tracer */
    tla_trace_init("scenario_1_normal.ndjson");

    /* Simulate requester initializing version */
    state_capture_requester_state("requester_version_sent");
    state_capture_responder_state("responder_init");
    char *state_json = build_state_json();
    tla_trace_event_t evt = {
        .event = "requester_init_version",
        .node_id = "requester",
        .state_json = state_json,
        .msg_json = NULL
    };
    tla_trace_emit(&evt);
    free(state_json);

    /* Simulate responder handling version */
    state_capture_responder_state("responder_version_resp");
    state_json = build_state_json();
    evt.event = "responder_handles_version";
    evt.node_id = "responder";
    evt.state_json = state_json;
    evt.msg_json = NULL;
    tla_trace_emit(&evt);
    free(state_json);

    /* Simulate responder sending version */
    state_capture_version_negotiated(true);
    state_capture_responder_state("responder_caps_resp");
    state_capture_negotiated_version(0x10);
    state_json = build_state_json();
    char *evt_json = build_event_json_version(0x10);
    evt.event = "responder_sends_version";
    evt.state_json = state_json;
    evt.msg_json = evt_json;
    tla_trace_emit(&evt);
    free(state_json);
    free(evt_json);

    /* Simulate requester receiving version */
    state_capture_requester_state("requester_caps_sent");
    state_json = build_state_json();
    evt_json = build_event_json_version(0x10);
    evt.event = "requester_receives_version";
    evt.node_id = "requester";
    evt.state_json = state_json;
    evt.msg_json = evt_json;
    tla_trace_emit(&evt);
    free(state_json);
    free(evt_json);

    /* Simulate requester sending capabilities */
    state_capture_requester_state("requester_algo_sent");
    state_json = build_state_json();
    evt.event = "requester_init_capabilities";
    evt.node_id = "requester";
    evt.state_json = state_json;
    evt.msg_json = NULL;
    tla_trace_emit(&evt);
    free(state_json);

    /* Simulate responder handling capabilities */
    state_capture_responder_state("responder_algo_resp");
    state_json = build_state_json();
    evt.event = "responder_handles_capabilities";
    evt.node_id = "responder";
    evt.state_json = state_json;
    evt.msg_json = NULL;
    tla_trace_emit(&evt);
    free(state_json);

    /* Simulate responder sending capabilities */
    state_capture_capabilities_negotiated(true);
    state_capture_responder_state("responder_algo_resp");
    state_json = build_state_json();
    evt.event = "responder_sends_capabilities";
    evt.node_id = "responder";
    evt.state_json = state_json;
    evt.msg_json = NULL;
    tla_trace_emit(&evt);
    free(state_json);

    /* Simulate requester receiving capabilities */
    state_capture_requester_state("requester_algo_sent");
    state_json = build_state_json();
    evt.event = "requester_receives_capabilities";
    evt.node_id = "requester";
    evt.state_json = state_json;
    evt.msg_json = NULL;
    tla_trace_emit(&evt);
    free(state_json);

    /* Simulate requester proposing algorithms */
    state_json = build_state_json();
    evt_json = build_event_json_proposed_algos("[1, 16, 4, 8]", false);
    evt.event = "requester_init_algorithms";
    evt.node_id = "requester";
    evt.state_json = state_json;
    evt.msg_json = evt_json;
    tla_trace_emit(&evt);
    free(state_json);
    free(evt_json);

    /* Simulate responder handling algorithms */
    state_capture_responder_state("responder_complete");
    state_json = build_state_json();
    evt_json = build_event_json_proposed_algos("[1, 16, 4, 8]", false);
    evt.event = "responder_handles_algorithms";
    evt.node_id = "responder";
    evt.state_json = state_json;
    evt.msg_json = evt_json;
    tla_trace_emit(&evt);
    free(state_json);
    free(evt_json);

    /* Simulate responder sending algorithms */
    state_capture_algorithms_negotiated(true);
    state_json = build_state_json();
    evt_json = build_event_json_algos("[1]", true);
    evt.event = "responder_sends_algorithms";
    evt.node_id = "responder";
    evt.state_json = state_json;
    evt.msg_json = evt_json;
    tla_trace_emit(&evt);
    free(state_json);
    free(evt_json);

    /* Simulate requester validating algorithms */
    state_capture_requester_state("requester_complete");
    state_json = build_state_json();
    evt_json = build_event_json_algos("[1]", true);
    evt.event = "requester_validates_algorithms";
    evt.node_id = "requester";
    evt.state_json = state_json;
    evt.msg_json = evt_json;
    tla_trace_emit(&evt);
    free(state_json);
    free(evt_json);

    tla_trace_shutdown();
    printf("  ✓ Generated trace file: traces/scenario_1_normal.ndjson\n");
    return 0;
}

/* Test case with prioritization failure (Family 2 bug) */
int test_scenario_2_prioritization_failure(void) {
    printf("Test Scenario 2: Prioritization failure\n");

    tla_trace_init("scenario_2_prioritization_failure.ndjson");

    /* Simulate the handshake up to algorithm negotiation */
    state_capture_requester_state("requester_init");
    state_capture_responder_state("responder_init");
    state_capture_version_negotiated(false);
    state_capture_capabilities_negotiated(false);
    state_capture_algorithms_negotiated(false);

    /* Skip to algorithm phase and simulate failure */
    state_capture_version_negotiated(true);
    state_capture_capabilities_negotiated(true);
    state_capture_requester_state("requester_algo_sent");
    state_capture_responder_state("responder_algo_resp");

    /* Requester proposes algorithms */
    char *state_json = build_state_json();
    char *evt_json = build_event_json_proposed_algos("[2, 32, 8, 16]", false);
    tla_trace_event_t evt = {
        .event = "requester_init_algorithms",
        .node_id = "requester",
        .state_json = state_json,
        .msg_json = evt_json
    };
    tla_trace_emit(&evt);
    free(state_json);
    free(evt_json);

    /* Responder handles algorithms but prioritization fails (no common algo) */
    state_capture_responder_state("responder_complete");
    state_json = build_state_json();
    evt_json = build_event_json_proposed_algos("[3, 64, 16, 32]", true);
    evt.event = "responder_handles_algorithms";
    evt.node_id = "responder";
    evt.state_json = state_json;
    evt.msg_json = evt_json;
    tla_trace_emit(&evt);
    free(state_json);
    free(evt_json);

    /* Responder sends failed algorithms (0 = failure) */
    state_json = build_state_json();
    evt_json = build_event_json_algos("[0]", false);
    evt.event = "responder_sends_algorithms";
    evt.node_id = "responder";
    evt.state_json = state_json;
    evt.msg_json = evt_json;
    tla_trace_emit(&evt);
    free(state_json);
    free(evt_json);

    /* Requester validates and fails */
    state_capture_algorithms_negotiated(false);
    state_capture_requester_state("requester_complete");
    state_json = build_state_json();
    evt_json = build_event_json_algos("[0]", false);
    evt.event = "requester_validates_algorithms";
    evt.node_id = "requester";
    evt.state_json = state_json;
    evt.msg_json = evt_json;
    tla_trace_emit(&evt);
    free(state_json);
    free(evt_json);

    tla_trace_shutdown();
    printf("  ✓ Generated trace file: traces/scenario_2_prioritization_failure.ndjson\n");
    return 0;
}

/* Test case with mid-handshake version reset (Family 4 bug) */
int test_scenario_3_mid_handshake_reset(void) {
    printf("Test Scenario 3: Mid-handshake version reset (Family 4)\n");

    tla_trace_init("scenario_3_mid_handshake_reset.ndjson");

    /* Handshake up to capabilities */
    state_capture_requester_state("requester_init");
    state_capture_responder_state("responder_init");
    state_capture_version_negotiated(true);
    state_capture_capabilities_negotiated(true);
    state_capture_requester_state("requester_algo_sent");
    state_capture_responder_state("responder_algo_resp");

    /* Responder receives unexpected GET_VERSION mid-handshake */
    state_capture_responder_state("responder_handles_version");
    char *state_json = build_state_json();
    tla_trace_event_t evt = {
        .event = "responder_handles_version",
        .node_id = "responder",
        .state_json = state_json,
        .msg_json = NULL
    };
    tla_trace_emit(&evt);
    free(state_json);

    /* Reset clears negotiated flags */
    state_capture_version_negotiated(false);
    state_capture_capabilities_negotiated(false);
    state_capture_algorithms_negotiated(false);
    state_capture_responder_state("responder_version_resp");
    state_json = build_state_json();
    char *evt_json = build_event_json_version(0x10);
    evt.event = "responder_sends_version";
    evt.node_id = "responder";
    evt.state_json = state_json;
    evt.msg_json = evt_json;
    tla_trace_emit(&evt);
    free(state_json);
    free(evt_json);

    tla_trace_shutdown();
    printf("  ✓ Generated trace file: traces/scenario_3_mid_handshake_reset.ndjson\n");
    return 0;
}

int main(void) {
    printf("=== SPDM Handshake Trace Generation ===\n\n");

    int ret = 0;
    ret |= test_scenario_1_normal_handshake();
    printf("\n");
    ret |= test_scenario_2_prioritization_failure();
    printf("\n");
    ret |= test_scenario_3_mid_handshake_reset();
    printf("\n");

    if (ret == 0) {
        printf("✓ All scenarios completed successfully\n");
    } else {
        printf("✗ Some scenarios failed\n");
    }

    cleanup_json_strings();
    return ret;
}
