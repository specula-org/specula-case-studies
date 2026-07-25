/**
 * Test scenario for SPDM Encapsulated Mutual Authentication
 *
 * This test exercises the protocol flow:
 * 1. Responder generates encapsulated challenge request
 * 2. Requester generates encapsulated response with authentication
 * 3. Responder processes the response and verifies signature
 * 4. Transition to authenticated state
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "libspdm_tla_trace.h"

/*
 * Mock functions and stubs for testing.
 * In a real scenario, these would link against libspdm proper.
 */

typedef enum {
    STATE_UNINITIALIZED = 0,
    STATE_CHALLENGE_SENT = 1,
    STATE_CHALLENGE_AUTH_RESPONSE_RECEIVED = 2,
    STATE_AUTHENTICATED = 3
} connection_state_t;

/* Global test state */
static struct {
    uint32_t protocol_version;
    connection_state_t requester_state;
    connection_state_t responder_state;
    bool signature_verified;
    uint32_t response_buffer_size;
    uint32_t opaque_data_size;
    char buffer_reset_status[32];
} test_state = {
    .protocol_version = 13,
    .requester_state = STATE_UNINITIALIZED,
    .responder_state = STATE_UNINITIALIZED,
    .signature_verified = false,
    .response_buffer_size = 0,
    .opaque_data_size = 0,
    .buffer_reset_status = "pending"
};

static const char *state_to_string(connection_state_t state) {
    switch (state) {
        case STATE_UNINITIALIZED:
            return "uninitialized";
        case STATE_CHALLENGE_SENT:
            return "challenge_sent";
        case STATE_CHALLENGE_AUTH_RESPONSE_RECEIVED:
            return "challenge_auth_response_received";
        case STATE_AUTHENTICATED:
            return "authenticated";
        default:
            return "unknown";
    }
}

/**
 * Test scenario: Successful mutual authentication flow
 */
static void test_responder_get_encap_request_challenge(void) {
    printf("=== Test: ResponderGetEncapRequestChallenge ===\n");

    /* Simulate buffer reset */
    strcpy(test_state.buffer_reset_status, "success");

    /* Update state */
    test_state.responder_state = STATE_CHALLENGE_SENT;

    /* Emit trace event */
    char state_json[512];
    snprintf(state_json, sizeof(state_json),
             "\"protocol_version\": %u, "
             "\"requester_state\": \"%s\", "
             "\"responder_state\": \"%s\", "
             "\"signature_verified\": %s, "
             "\"response_buffer_size\": %u, "
             "\"opaque_data_size\": %u, "
             "\"buffer_reset_status\": \"%s\"",
             test_state.protocol_version,
             state_to_string(test_state.requester_state),
             state_to_string(test_state.responder_state),
             test_state.signature_verified ? "true" : "false",
             test_state.response_buffer_size,
             test_state.opaque_data_size,
             test_state.buffer_reset_status);

    char msg_json[256];
    snprintf(msg_json, sizeof(msg_json),
             "\"version\": %u",
             test_state.protocol_version);

    libspdm_tla_trace_emit(
        "responder_get_encap_request_challenge",
        "responder",
        state_json,
        msg_json
    );
}

/**
 * Test scenario: Requester generates response
 */
static void test_requester_get_encap_response_challenge_auth(void) {
    printf("=== Test: RequesterGetEncapResponseChallengeAuth ===\n");

    /* Simulate opaque data calculation */
    test_state.response_buffer_size = 512;
    test_state.opaque_data_size = 100;  /* After subtraction */
    test_state.requester_state = STATE_CHALLENGE_AUTH_RESPONSE_RECEIVED;

    char state_json[512];
    snprintf(state_json, sizeof(state_json),
             "\"protocol_version\": %u, "
             "\"requester_state\": \"%s\", "
             "\"responder_state\": \"%s\", "
             "\"signature_verified\": %s, "
             "\"response_buffer_size\": %u, "
             "\"opaque_data_size\": %u, "
             "\"buffer_reset_status\": \"%s\", "
             "\"transcript_complete\": true",
             test_state.protocol_version,
             state_to_string(test_state.requester_state),
             state_to_string(test_state.responder_state),
             test_state.signature_verified ? "true" : "false",
             test_state.response_buffer_size,
             test_state.opaque_data_size,
             test_state.buffer_reset_status);

    libspdm_tla_trace_emit(
        "requester_get_encap_response_challenge_auth",
        "requester",
        state_json,
        NULL
    );
}

/**
 * Test scenario: Responder processes response and verifies signature
 */
static void test_process_encap_response_challenge_auth(void) {
    printf("=== Test: ProcessEncapResponseChallengeAuth ===\n");

    /* Simulate signature verification */
    test_state.signature_verified = true;
    test_state.responder_state = STATE_CHALLENGE_AUTH_RESPONSE_RECEIVED;

    char state_json[512];
    snprintf(state_json, sizeof(state_json),
             "\"protocol_version\": %u, "
             "\"requester_state\": \"%s\", "
             "\"responder_state\": \"%s\", "
             "\"signature_verified\": %s, "
             "\"response_buffer_size\": %u, "
             "\"opaque_data_size\": %u, "
             "\"buffer_reset_status\": \"%s\"",
             test_state.protocol_version,
             state_to_string(test_state.requester_state),
             state_to_string(test_state.responder_state),
             test_state.signature_verified ? "true" : "false",
             test_state.response_buffer_size,
             test_state.opaque_data_size,
             test_state.buffer_reset_status);

    libspdm_tla_trace_emit(
        "process_encap_response_challenge_auth",
        "responder",
        state_json,
        NULL
    );
}

/**
 * Test scenario: Transition to authenticated state
 */
static void test_transition_to_authenticated(void) {
    printf("=== Test: TransitionToAuthenticated ===\n");

    /* Update states */
    test_state.requester_state = STATE_AUTHENTICATED;
    test_state.responder_state = STATE_AUTHENTICATED;

    char state_json[512];
    snprintf(state_json, sizeof(state_json),
             "\"protocol_version\": %u, "
             "\"requester_state\": \"%s\", "
             "\"responder_state\": \"%s\", "
             "\"signature_verified\": %s, "
             "\"response_buffer_size\": %u, "
             "\"opaque_data_size\": %u, "
             "\"buffer_reset_status\": \"%s\"",
             test_state.protocol_version,
             state_to_string(test_state.requester_state),
             state_to_string(test_state.responder_state),
             test_state.signature_verified ? "true" : "false",
             test_state.response_buffer_size,
             test_state.opaque_data_size,
             test_state.buffer_reset_status);

    libspdm_tla_trace_emit(
        "transition_to_authenticated",
        "responder",
        state_json,
        NULL
    );
}

/**
 * Test scenario: Buffer underflow (Family 3 bug candidate)
 */
static void test_opaque_data_underflow(void) {
    printf("=== Test: Opaque Data Size Underflow ===\n");

    /* Reset state */
    test_state.requester_state = STATE_UNINITIALIZED;
    test_state.responder_state = STATE_UNINITIALIZED;
    test_state.signature_verified = false;
    test_state.response_buffer_size = 100;  /* Too small */
    test_state.opaque_data_size = 18446744073709551516UL;  /* Wrapped underflow */
    strcpy(test_state.buffer_reset_status, "success");

    test_state.responder_state = STATE_CHALLENGE_SENT;

    char state_json[512];
    snprintf(state_json, sizeof(state_json),
             "\"protocol_version\": %u, "
             "\"requester_state\": \"%s\", "
             "\"responder_state\": \"%s\", "
             "\"signature_verified\": %s, "
             "\"response_buffer_size\": %u, "
             "\"opaque_data_size\": %lu, "
             "\"buffer_reset_status\": \"%s\"",
             test_state.protocol_version,
             state_to_string(test_state.requester_state),
             state_to_string(test_state.responder_state),
             test_state.signature_verified ? "true" : "false",
             test_state.response_buffer_size,
             test_state.opaque_data_size,
             test_state.buffer_reset_status);

    libspdm_tla_trace_emit(
        "requester_get_encap_response_challenge_auth",
        "requester",
        state_json,
        NULL
    );
}

int main(int argc, char *argv[]) {
    const char *trace_file = "traces/test_scenario_basic.ndjson";

    if (argc > 1) {
        trace_file = argv[1];
    }

    printf("Initializing trace to: %s\n", trace_file);
    if (libspdm_tla_trace_init(trace_file) != 0) {
        fprintf(stderr, "Failed to initialize trace\n");
        return 1;
    }

    /* Run test scenarios */
    test_responder_get_encap_request_challenge();
    test_requester_get_encap_response_challenge_auth();
    test_process_encap_response_challenge_auth();
    test_transition_to_authenticated();

    printf("\n");

    /* Test underflow scenario */
    test_opaque_data_underflow();

    libspdm_tla_trace_shutdown();
    printf("Trace complete\n");

    return 0;
}
