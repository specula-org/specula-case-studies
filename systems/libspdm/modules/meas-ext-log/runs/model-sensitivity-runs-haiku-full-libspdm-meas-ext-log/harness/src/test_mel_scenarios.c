/**
 * TLA+ Trace Test Scenarios for MEL Protocol
 * Tests various code paths to generate comprehensive traces
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "tla_trace.h"

/* Mock structures for standalone testing */
typedef struct {
    uint32_t portion_length;
    uint32_t remainder_length;
} mel_response_t;

/* Scenario 1: Single-chunk MEL (fits in one response) */
void test_scenario_single_chunk(void) {
    char trace_path[256];
    printf("Running test scenario: single-chunk MEL\n");

    build_trace_path(trace_path, sizeof(trace_path), "scenario_single_chunk.ndjson");
    tla_trace_init(trace_path);

    /* Initialize: responder has 16 bytes, requester starts */
    tla_trace_init_event(
        16,     /* responder_mel_size */
        14,     /* responder_mel_entries_len */
        0,      /* req_offset */
        0,      /* req_mel_size */
        0,      /* req_remainder */
        0,      /* req_total_mel_size */
        "ready", /* req_pc */
        "ready" /* responder_pc */
    );

    /* Requester sends request for offset=0, length=32 */
    tla_trace_req_send_get_mel(
        0,      /* msg_offset */
        32,     /* msg_length */
        0,      /* req_offset */
        0,      /* req_mel_size */
        0,      /* req_remainder */
        0,      /* req_total_mel_size */
        "waiting"
    );

    /* Responder sends response: 16 bytes, 0 remainder */
    tla_trace_resp_receive_and_send_mel(
        16,     /* msg_portion_length */
        0,      /* msg_remainder_length */
        16,     /* msg_data_len */
        16,     /* responder_mel_size */
        14      /* responder_mel_entries_len */
    );

    /* Requester receives response and processes it */
    tla_trace_req_receive_mel_response(
        16,     /* recv_portion_length */
        0,      /* recv_remainder_length */
        16,     /* req_mel_size */
        16,     /* req_offset */
        0,      /* req_remainder */
        16,     /* req_total_mel_size */
        "done"  /* req_pc */
    );

    tla_trace_shutdown();
    printf("  Generated trace: traces/scenario_single_chunk.ndjson\n");
}

/* Scenario 2: Multi-chunk MEL (requires multiple requests) */
void test_scenario_multi_chunk(void) {
    char trace_path[256];
    printf("Running test scenario: multi-chunk MEL\n");

    build_trace_path(trace_path, sizeof(trace_path), "scenario_multi_chunk.ndjson");
    tla_trace_init(trace_path);

    /* Initialize: responder has 48 bytes, requester starts */
    tla_trace_init_event(
        48,     /* responder_mel_size */
        46,     /* responder_mel_entries_len */
        0,      /* req_offset */
        0,      /* req_mel_size */
        0,      /* req_remainder */
        0,      /* req_total_mel_size */
        "ready", /* req_pc */
        "ready" /* responder_pc */
    );

    /* First request: offset=0, length=32 */
    tla_trace_req_send_get_mel(
        0,      /* msg_offset */
        32,     /* msg_length */
        0,      /* req_offset */
        0,      /* req_mel_size */
        0,      /* req_remainder */
        0,      /* req_total_mel_size */
        "waiting"
    );

    /* First response: 32 bytes, 16 remainder */
    tla_trace_resp_receive_and_send_mel(
        32,     /* msg_portion_length */
        16,     /* msg_remainder_length */
        32,     /* msg_data_len */
        48,     /* responder_mel_size */
        46      /* responder_mel_entries_len */
    );

    /* Requester receives first response */
    tla_trace_req_receive_mel_response(
        32,     /* recv_portion_length */
        16,     /* recv_remainder_length */
        32,     /* req_mel_size */
        32,     /* req_offset */
        16,     /* req_remainder */
        48,     /* req_total_mel_size */
        "ready" /* req_pc */
    );

    /* Second request: offset=32, length=16 */
    tla_trace_req_send_get_mel(
        32,     /* msg_offset */
        32,     /* msg_length (clamped to remaining) */
        32,     /* req_offset */
        32,     /* req_mel_size */
        16,     /* req_remainder */
        48,     /* req_total_mel_size */
        "waiting"
    );

    /* Second response: 16 bytes, 0 remainder */
    tla_trace_resp_receive_and_send_mel(
        16,     /* msg_portion_length */
        0,      /* msg_remainder_length */
        16,     /* msg_data_len */
        48,     /* responder_mel_size */
        46      /* responder_mel_entries_len */
    );

    /* Requester receives second response and completes */
    tla_trace_req_receive_mel_response(
        16,     /* recv_portion_length */
        0,      /* recv_remainder_length */
        48,     /* req_mel_size */
        48,     /* req_offset */
        0,      /* req_remainder */
        48,     /* req_total_mel_size */
        "done"  /* req_pc */
    );

    tla_trace_shutdown();
    printf("  Generated trace: traces/scenario_multi_chunk.ndjson\n");
}

/* Scenario 3: Error handling - invalid offset */
void test_scenario_error_invalid_offset(void) {
    char trace_path[256];
    printf("Running test scenario: error - invalid offset\n");

    build_trace_path(trace_path, sizeof(trace_path), "scenario_error_invalid_offset.ndjson");
    tla_trace_init(trace_path);

    /* Initialize: responder has 16 bytes */
    tla_trace_init_event(
        16,     /* responder_mel_size */
        14,     /* responder_mel_entries_len */
        0,      /* req_offset */
        0,      /* req_mel_size */
        0,      /* req_remainder */
        0,      /* req_total_mel_size */
        "ready", /* req_pc */
        "ready" /* responder_pc */
    );

    /* Requester sends request with offset beyond MEL size */
    tla_trace_req_send_get_mel(
        20,     /* msg_offset (> responder_mel_size) */
        32,     /* msg_length */
        20,     /* req_offset */
        0,      /* req_mel_size */
        0,      /* req_remainder */
        0,      /* req_total_mel_size */
        "waiting"
    );

    /* Responder rejects with error */
    tla_trace_error("resp_error", "INVALID_REQUEST");

    tla_trace_shutdown();
    printf("  Generated trace: traces/scenario_error_invalid_offset.ndjson\n");
}

/* Scenario 4: Three-chunk MEL */
void test_scenario_three_chunk(void) {
    char trace_path[256];
    printf("Running test scenario: three-chunk MEL\n");

    build_trace_path(trace_path, sizeof(trace_path), "scenario_three_chunk.ndjson");
    tla_trace_init(trace_path);

    /* Initialize: responder has 80 bytes */
    tla_trace_init_event(
        80,     /* responder_mel_size */
        78,     /* responder_mel_entries_len */
        0,      /* req_offset */
        0,      /* req_mel_size */
        0,      /* req_remainder */
        0,      /* req_total_mel_size */
        "ready", /* req_pc */
        "ready" /* responder_pc */
    );

    /* Chunk 1: offset=0, get 32 bytes, 48 remainder */
    tla_trace_req_send_get_mel(0, 32, 0, 0, 0, 0, "waiting");
    tla_trace_resp_receive_and_send_mel(32, 48, 32, 80, 78);
    tla_trace_req_receive_mel_response(32, 48, 32, 32, 48, 80, "ready");

    /* Chunk 2: offset=32, get 32 bytes, 16 remainder */
    tla_trace_req_send_get_mel(32, 32, 32, 32, 48, 80, "waiting");
    tla_trace_resp_receive_and_send_mel(32, 16, 32, 80, 78);
    tla_trace_req_receive_mel_response(32, 16, 64, 64, 16, 80, "ready");

    /* Chunk 3: offset=64, get 16 bytes, 0 remainder */
    tla_trace_req_send_get_mel(64, 32, 64, 64, 16, 80, "waiting");
    tla_trace_resp_receive_and_send_mel(16, 0, 16, 80, 78);
    tla_trace_req_receive_mel_response(16, 0, 80, 80, 0, 80, "done");

    tla_trace_shutdown();
    printf("  Generated trace: traces/scenario_three_chunk.ndjson\n");
}

/* Get traces directory from environment or use default */
const char *get_traces_dir(void) {
    const char *env = getenv("TRACES_DIR");
    if (env != NULL) {
        return env;
    }
    return "./traces";
}

/* Build full trace file path */
void build_trace_path(char *buffer, size_t size, const char *basename) {
    const char *traces_dir = get_traces_dir();
    snprintf(buffer, size, "%s/%s", traces_dir, basename);
}

int main(void) {
    char trace_path[256];

    printf("=== MEL Protocol Trace Generation ===\n\n");

    build_trace_path(trace_path, sizeof(trace_path), "scenario_single_chunk.ndjson");
    printf("Traces directory: %s\n", get_traces_dir());
    printf("First trace: %s\n\n", trace_path);

    test_scenario_single_chunk();
    test_scenario_multi_chunk();
    test_scenario_error_invalid_offset();
    test_scenario_three_chunk();

    printf("\n=== Trace Generation Complete ===\n");
    return 0;
}
