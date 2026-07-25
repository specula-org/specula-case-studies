/*
 * Test scenario for libspdm CHALLENGE/CHALLENGE_AUTH protocol
 * Exercises trace instrumentation for all 5 protocol actions
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "tla_trace.h"

/*
 * This is a minimal test harness that:
 * 1. Initializes the trace file
 * 2. Emits example trace events for all 5 protocol actions
 * 3. Closes the trace file
 *
 * In a real scenario, this would integrate with libspdm's test framework
 * to exercise the actual protocol code paths. For Phase 2.5 demonstratio,
 * we emit synthetic traces that match the instrumentation spec.
 */

int main(int argc, char *argv[]) {
    const char *trace_file = "traces/test_scenario.ndjson";
    if (argc > 1) {
        trace_file = argv[1];
    }

    /* Create traces directory if needed */
    system("mkdir -p traces");

    /* Initialize trace output */
    if (tla_trace_init(trace_file) != 0) {
        fprintf(stderr, "Failed to initialize trace file: %s\n", trace_file);
        return 1;
    }

    /* Example trace events matching the instrumentation spec */

    /* Event 1: RequesterSendChallenge */
    {
        uint64_t ts = 1000;
        uint8_t slot_id = 0;
        uint8_t version = 0x10;  /* SPDM 1.0 */
        uint8_t nonce[32] = {0xa1, 0xb2, 0xc3, 0xd4, 0xe5, 0xf6, 0x07, 0x18};

        tla_state_t before = {NULL, "NONE", NULL};
        tla_state_t after = {NULL, "ONE_WAY_STARTED", NULL};

        tla_emit_requester_send_challenge(ts, slot_id, version, nonce, NULL, before, after);
    }

    /* Event 2: ResponderHandleChallenge */
    {
        uint64_t ts = 2000;
        uint8_t slot_id = 0;
        const char *key_source = "cert_chain";
        uint8_t nonce[32] = {0xd4, 0xc3, 0xb2, 0xa1, 0xf0, 0xe1, 0xd2, 0xc3};
        uint32_t message_c_len = 150;

        tla_state_t before = {NULL, "NONE", NULL};
        tla_state_t after = {"challenged", "MUTUAL_IN_PROGRESS", "cert_chain"};

        tla_emit_responder_handle_challenge(ts, slot_id, key_source, nonce, message_c_len,
                                           NULL, before, after);
    }

    /* Event 3: RequesterHandleChallengeAuth */
    {
        uint64_t ts = 3000;
        uint8_t slot_id = 0;
        const char *key_source = "cert_chain";
        uint8_t responder_nonce[32] = {0xd4, 0xc3, 0xb2, 0xa1, 0xf0, 0xe1, 0xd2, 0xc3};
        int context_match = 0;  /* SPDM 1.0 has no context */

        tla_state_t before = {"challenged", "ONE_WAY_STARTED", NULL};
        tla_state_t after = {"authenticated", "ONE_WAY_COMPLETE", "cert_chain"};

        tla_emit_requester_handle_challenge_auth(ts, slot_id, key_source, responder_nonce,
                                                context_match, before, after);
    }

    /* Event 4: ResponderHandleEncapChallenge */
    {
        uint64_t ts = 4000;
        uint32_t message_mut_c_len = 200;

        tla_state_t before = {"challenged", "MUTUAL_IN_PROGRESS", "cert_chain"};
        tla_state_t after = {"challenged", "MUTUAL_IN_PROGRESS", "cert_chain"};

        tla_emit_responder_handle_encap_challenge(ts, message_mut_c_len, before, after);
    }

    /* Event 5: RequesterHandleEncapChallengeAuth */
    {
        uint64_t ts = 5000;

        tla_state_t before = {"authenticated", "ONE_WAY_COMPLETE", "cert_chain"};
        tla_state_t after = {"authenticated", "FULLY_AUTHENTICATED", "cert_chain"};

        tla_emit_requester_handle_encap_challenge_auth(ts, before, after);
    }

    /* Shutdown trace file */
    tla_trace_shutdown();

    printf("Trace events emitted to %s\n", trace_file);
    return 0;
}
