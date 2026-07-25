/* Additional test scenarios for PSK exchange protocol
 * These scenarios are designed to exercise different code paths
 * and test edge cases relevant to the bug families
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "tla_trace.h"

/* Scenario 1: Happy path trace generation
 * Simulates successful PSK exchange with version negotiation
 */
void scenario_happy_path(const char *trace_file) {
    printf("Scenario 1: Happy path PSK exchange\n");
    tla_trace_init(trace_file);

    /* Requester sends PSK_EXCHANGE */
    uint16_t req_sid = 0x0001;
    trace_message_fields_t req_msg = {
        .req_session_id = req_sid,
        .rsp_session_id = 0,
        .opaque_length = 32,
        .context_length = 32,
        .psk_hint_length = 8,
        .opaque_data = true,
        .context_data = true,
        .version_negotiated = false,
        .use_default_opaque = false,
        .opaque_data_valid = false,
        .session_id = 0
    };
    trace_state_snapshot_t req_state = {
        .pc = "sent_psk_exchange",
        .session_state = "IDLE",
        .allocated_ids = &req_sid,
        .num_allocated_ids = 1,
        .version_negotiated = false,
        .opaque_length_checked = false,
        .context_length_checked = false
    };
    tla_trace_emit("RequesterSendPskExchange", "req", &req_state, &req_msg);

    /* Responder receives PSK_EXCHANGE */
    trace_message_fields_t rsp_recv_msg = {
        .req_session_id = req_sid,
        .rsp_session_id = 0,
        .opaque_length = 32,
        .context_length = 32,
        .psk_hint_length = 8,
        .opaque_data = true,
        .context_data = true,
        .version_negotiated = false,
        .use_default_opaque = false,
        .opaque_data_valid = true,
        .session_id = 0
    };
    trace_state_snapshot_t rsp_recv_state = {
        .pc = "recv_psk_exchange",
        .session_state = "IDLE",
        .allocated_ids = NULL,
        .num_allocated_ids = 0,
        .version_negotiated = false,
        .opaque_length_checked = true,
        .context_length_checked = true
    };
    tla_trace_emit("ResponderRecvPskExchange", "rsp", &rsp_recv_state, &rsp_recv_msg);

    /* Responder sends PSK_EXCHANGE_RSP */
    uint16_t rsp_sid = 0x0002;
    uint32_t session_id = (req_sid << 16) | rsp_sid;
    trace_message_fields_t rsp_send_msg = {
        .req_session_id = req_sid,
        .rsp_session_id = rsp_sid,
        .opaque_length = 16,
        .context_length = 0,
        .psk_hint_length = 0,
        .opaque_data = true,
        .context_data = false,
        .version_negotiated = true,
        .use_default_opaque = true,
        .opaque_data_valid = true,
        .session_id = session_id
    };
    trace_state_snapshot_t rsp_send_state = {
        .pc = "sent_psk_exchange_rsp",
        .session_state = "HANDSHAKING",
        .allocated_ids = NULL,
        .num_allocated_ids = 0,
        .version_negotiated = true,
        .opaque_length_checked = false,
        .context_length_checked = false
    };
    tla_trace_emit("ResponderSendPskExchangeRsp", "rsp", &rsp_send_state, &rsp_send_msg);

    /* Requester receives PSK_EXCHANGE_RSP */
    trace_message_fields_t req_recv_msg = {
        .req_session_id = req_sid,
        .rsp_session_id = rsp_sid,
        .opaque_length = 16,
        .context_length = 0,
        .psk_hint_length = 0,
        .opaque_data = true,
        .context_data = false,
        .version_negotiated = true,
        .use_default_opaque = false,
        .opaque_data_valid = true,
        .session_id = session_id
    };
    trace_state_snapshot_t req_recv_state = {
        .pc = "received_psk_exchange_rsp",
        .session_state = "HANDSHAKING",
        .allocated_ids = NULL,
        .num_allocated_ids = 0,
        .version_negotiated = true,
        .opaque_length_checked = true,
        .context_length_checked = true
    };
    tla_trace_emit("RequesterRecvPskExchangeRsp", "req", &req_recv_state, &req_recv_msg);

    tla_trace_shutdown();
    printf("  Generated happy path trace with 4 events\n");
}

/* Scenario 2: Family 1 - Opaque length bounds test
 * Simulates behavior with various opaque lengths to test bounds checking
 */
void scenario_opaque_bounds(const char *trace_file) {
    printf("Scenario 2: Opaque data bounds validation\n");
    tla_trace_init(trace_file);

    uint16_t req_sid = 0x0003;

    /* Test case 1: Valid opaque length */
    trace_message_fields_t msg1 = {
        .req_session_id = req_sid,
        .rsp_session_id = 0,
        .opaque_length = 100,
        .context_length = 32,
        .psk_hint_length = 0,
        .opaque_data = true,
        .context_data = true,
        .version_negotiated = false,
        .use_default_opaque = false,
        .opaque_data_valid = false,
        .session_id = 0
    };
    trace_state_snapshot_t state1 = {
        .pc = "sent_psk_exchange",
        .session_state = "IDLE",
        .allocated_ids = &req_sid,
        .num_allocated_ids = 1,
        .version_negotiated = false,
        .opaque_length_checked = false,
        .context_length_checked = false
    };
    tla_trace_emit("RequesterSendPskExchange", "req", &state1, &msg1);

    /* Responder validates bounds (implicit check) */
    trace_state_snapshot_t rsp_state = {
        .pc = "recv_psk_exchange",
        .session_state = "IDLE",
        .allocated_ids = NULL,
        .num_allocated_ids = 0,
        .version_negotiated = false,
        .opaque_length_checked = true,
        .context_length_checked = true
    };
    tla_trace_emit("ResponderRecvPskExchange", "rsp", &rsp_state, &msg1);

    tla_trace_shutdown();
    printf("  Generated bounds test trace with 2 events\n");
}

/* Scenario 3: Family 2 - Session ID tracking
 * Tests session ID allocation and deallocation
 */
void scenario_session_id_tracking(const char *trace_file) {
    printf("Scenario 3: Session ID allocation tracking\n");
    tla_trace_init(trace_file);

    uint16_t req_sid1 = 0x0001;
    uint16_t req_sid2 = 0x0002;

    /* First session allocation */
    trace_state_snapshot_t alloc_state1 = {
        .pc = "sent_psk_exchange",
        .session_state = "IDLE",
        .allocated_ids = &req_sid1,
        .num_allocated_ids = 1,
        .version_negotiated = false,
        .opaque_length_checked = false,
        .context_length_checked = false
    };
    trace_message_fields_t msg1 = {
        .req_session_id = req_sid1,
        .rsp_session_id = 0,
        .opaque_length = 16,
        .context_length = 32,
        .psk_hint_length = 0,
        .opaque_data = true,
        .context_data = true,
        .version_negotiated = false,
        .use_default_opaque = false,
        .opaque_data_valid = false,
        .session_id = 0
    };
    tla_trace_emit("RequesterSendPskExchange", "req", &alloc_state1, &msg1);

    /* Second session allocation */
    uint16_t ids[] = {req_sid1, req_sid2};
    trace_state_snapshot_t alloc_state2 = {
        .pc = "sent_psk_exchange",
        .session_state = "IDLE",
        .allocated_ids = ids,
        .num_allocated_ids = 2,
        .version_negotiated = false,
        .opaque_length_checked = false,
        .context_length_checked = false
    };
    trace_message_fields_t msg2 = {
        .req_session_id = req_sid2,
        .rsp_session_id = 0,
        .opaque_length = 16,
        .context_length = 32,
        .psk_hint_length = 0,
        .opaque_data = true,
        .context_data = true,
        .version_negotiated = false,
        .use_default_opaque = false,
        .opaque_data_valid = false,
        .session_id = 0
    };
    tla_trace_emit("RequesterSendPskExchange", "req", &alloc_state2, &msg2);

    tla_trace_shutdown();
    printf("  Generated session ID tracking trace with 2 events\n");
}

int main(int argc, char *argv[]) {
    if (argc > 1) {
        const char *scenario = argv[1];
        const char *trace_file = (argc > 2) ? argv[2] : "../traces/scenarios.ndjson";

        if (strcmp(scenario, "happy_path") == 0) {
            scenario_happy_path(trace_file);
        } else if (strcmp(scenario, "bounds") == 0) {
            scenario_opaque_bounds(trace_file);
        } else if (strcmp(scenario, "session_ids") == 0) {
            scenario_session_id_tracking(trace_file);
        } else {
            fprintf(stderr, "Unknown scenario: %s\n", scenario);
            fprintf(stderr, "Usage: %s <scenario> [trace_file]\n", argv[0]);
            fprintf(stderr, "Scenarios: happy_path, bounds, session_ids\n");
            return 1;
        }
    } else {
        fprintf(stderr, "Usage: %s <scenario> [trace_file]\n", argv[0]);
        fprintf(stderr, "Scenarios: happy_path, bounds, session_ids\n");
        return 1;
    }

    return 0;
}
