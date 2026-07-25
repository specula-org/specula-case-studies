#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>

/* Minimal trace test without full libspdm dependency */
#include "tla_trace.h"

/*
 * Test scenario 1: Simple 2-chunk transfer
 * - ChunkSendInit with first chunk
 * - ChunkSendContinuation with second (final) chunk
 */
void test_scenario_two_chunk_transfer(void)
{
    printf("Running test scenario 1: Two-chunk transfer\n");

    /* ChunkSendInit event */
    tla_trace_chunk_send_init(
        512,      /* large_message_size */
        1024,     /* large_message_capacity */
        256,      /* chunk_size */
        true,     /* send_active */
        false,    /* get_active */
        true,     /* large_message_valid */
        true      /* seq_no_wrap_error (SPDM 1.2/1.3) */
    );

    /* ChunkSendContinuation event */
    tla_trace_chunk_send_continuation(
        1,        /* seq_no */
        512,      /* bytes_transferred */
        256,      /* chunk_size */
        512,      /* large_message_size */
        1024,     /* large_message_capacity */
        true,     /* send_active */
        false,    /* get_active */
        true,     /* large_message_valid */
        true      /* seq_no_wrap_error */
    );

    printf("Test scenario 1 completed\n\n");
}

/*
 * Test scenario 2: Interruption during transfer
 * - ChunkSendInit with first chunk
 * - ReceiveInterruption (non-chunk command received)
 */
void test_scenario_interruption(void)
{
    printf("Running test scenario 2: Interruption during transfer\n");

    /* ChunkSendInit event */
    tla_trace_chunk_send_init(
        1024,     /* large_message_size */
        2048,     /* large_message_capacity */
        512,      /* chunk_size */
        true,     /* send_active */
        false,    /* get_active */
        true,     /* large_message_valid */
        true      /* seq_no_wrap_error */
    );

    /* ReceiveInterruption event - non-chunk command during transfer */
    tla_trace_receive_interruption(
        "OTHER",  /* cmd_type */
        true,     /* send_active before clear */
        false,    /* get_active */
        0,        /* seq_no */
        512,      /* bytes_transferred */
        1024,     /* large_message_size */
        true,     /* large_message_valid */
        true      /* seq_no_wrap_error */
    );

    printf("Test scenario 2 completed\n\n");
}

/*
 * Test scenario 3: Error during reassembly
 * - ChunkSendInit with first chunk
 * - ErrorDuringReassembly (error detected, state cleared)
 */
void test_scenario_error_during_reassembly(void)
{
    printf("Running test scenario 3: Error during reassembly\n");

    /* ChunkSendInit event */
    tla_trace_chunk_send_init(
        768,      /* large_message_size */
        1536,     /* large_message_capacity */
        256,      /* chunk_size */
        true,     /* send_active */
        false,    /* get_active */
        true,     /* large_message_valid */
        false     /* seq_no_wrap_error (SPDM 1.4+) */
    );

    /* ErrorDuringReassembly event */
    tla_trace_error_during_reassembly(
        false,    /* send_active after clear */
        false,    /* get_active */
        0,        /* large_message_size after clear */
        false,    /* large_message_valid - false on error */
        false     /* seq_no_wrap_error */
    );

    printf("Test scenario 3 completed\n\n");
}

/*
 * Test scenario 4: Three-chunk transfer (multiple continuations)
 */
void test_scenario_three_chunk_transfer(void)
{
    printf("Running test scenario 4: Three-chunk transfer\n");

    /* ChunkSendInit event */
    tla_trace_chunk_send_init(
        768,      /* large_message_size */
        1536,     /* large_message_capacity */
        256,      /* chunk_size */
        true,     /* send_active */
        false,    /* get_active */
        true,     /* large_message_valid */
        true      /* seq_no_wrap_error */
    );

    /* First ChunkSendContinuation */
    tla_trace_chunk_send_continuation(
        1,        /* seq_no */
        512,      /* bytes_transferred */
        256,      /* chunk_size */
        768,      /* large_message_size */
        1536,     /* large_message_capacity */
        true,     /* send_active */
        false,    /* get_active */
        true,     /* large_message_valid */
        true      /* seq_no_wrap_error */
    );

    /* Second ChunkSendContinuation */
    tla_trace_chunk_send_continuation(
        2,        /* seq_no */
        768,      /* bytes_transferred */
        256,      /* chunk_size */
        768,      /* large_message_size */
        1536,     /* large_message_capacity */
        true,     /* send_active */
        false,    /* get_active */
        true,     /* large_message_valid */
        true      /* seq_no_wrap_error */
    );

    printf("Test scenario 4 completed\n\n");
}

int main(int argc, char *argv[])
{
    const char *trace_file = "../traces/trace.ndjson";

    if (argc > 1) {
        trace_file = argv[1];
    }

    printf("Initializing trace module with file: %s\n", trace_file);
    tla_trace_init(trace_file);

    /* Run test scenarios */
    test_scenario_two_chunk_transfer();
    test_scenario_interruption();
    test_scenario_error_during_reassembly();
    test_scenario_three_chunk_transfer();

    printf("Shutting down trace module\n");
    tla_trace_shutdown();

    printf("Test harness completed successfully\n");
    return 0;
}
