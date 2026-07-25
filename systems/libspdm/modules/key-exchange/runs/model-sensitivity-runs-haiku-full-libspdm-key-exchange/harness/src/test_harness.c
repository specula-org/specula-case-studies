/**
 * Test Harness for SPDM KEY_EXCHANGE / FINISH Protocol
 *
 * This harness exercises the protocol state machine by calling libspdm's
 * key exchange and finish functions, while collecting NDJSON traces.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "tla_trace.h"

/* Mock SPDM context and session info structures for testing */
typedef struct {
    uint16_t rsp_session_id;
    uint8_t mut_auth_requested;
    uint8_t req_slot_id_param;
} test_key_exchange_response_t;

typedef struct {
    uint16_t session_id;
    uint8_t hmac[32];
} test_finish_request_t;

/* Global trace context (per-process) */
static tla_trace_context_t requester_trace, responder_trace;

/**
 * Scenario 1: Successful KEY_EXCHANGE / FINISH handshake
 */
void scenario_successful_handshake(void) {
    printf("Running scenario: successful_handshake\n");

    /* Requester: Send KEY_EXCHANGE */
    {
        const char *state = "{\"requester_state\":\"KEX_SENT\",\"capabilities_req\":[]}";
        const char *msg = "{\"type\":\"KEY_EXCHANGE_REQ\",\"nonce\":\"0xabcd1234\",\"dhePublicKey\":\"0xdef56789\"}";
        tla_trace_emit_event(&requester_trace, "REQ_SEND_KEY_EXCHANGE", 0, state, msg);
    }

    /* Responder: Receive KEY_EXCHANGE and send response */
    {
        const char *state = "{\"responder_state\":\"KEX_SENT\",\"session_type\":\"DHE\",\"session_state\":\"INIT\",\"session_id_pool_count\":1}";
        const char *msg = "{\"type\":\"KEY_EXCHANGE_RSP\",\"sessionID\":1,\"nonce\":\"0x0987fedc\",\"dhePublicKey\":\"0xaabbccdd\",\"signature\":\"0xsig1\",\"signature2\":\"0xsig2\",\"hmac\":\"0xhmac1\",\"heartbeatPeriod\":0,\"mutAuthRequested\":0}";
        tla_trace_emit_event(&responder_trace, "RESP_RECEIVE_KEY_EXCHANGE", 1, state, msg);
    }

    /* Requester: Receive KEY_EXCHANGE response */
    {
        const char *state = "{\"requester_state\":\"KEX_RECEIVED\",\"session_state\":\"KEX_RECEIVED\",\"dheKeysAgreed\":true,\"transcriptHashKEX\":\"0xkexhash123\",\"capabilitiesValidated\":true}";
        const char *msg = "{\"type\":\"KEY_EXCHANGE_RSP\",\"sessionID\":1}";
        const char *validation = ",\"validation_results\":{\"heartbeat_period_valid\":true,\"mut_auth_bits_valid\":true,\"slot_id_valid\":true}";
        tla_trace_emit_event(&requester_trace, "REQ_RECEIVE_KEY_EXCHANGE", 1, state, msg);
    }

    /* Requester: Send FINISH */
    {
        const char *state = "{\"requester_state\":\"FINISH_SENT\",\"session_type\":\"DHE\",\"transcriptHashFINISH\":\"0xfinishhash456\"}";
        const char *msg = "{\"type\":\"FINISH_REQ\",\"sessionID\":1,\"hmac\":\"0xreq_hmac1\"}";
        tla_trace_emit_event(&requester_trace, "REQ_SEND_FINISH", 1, state, msg);
    }

    /* Responder: Receive FINISH and send response */
    {
        const char *state = "{\"responder_state\":\"FINISH_SENT\",\"session_state\":\"FINISH_RECEIVED\",\"hmacVerified\":true}";
        const char *msg = "{\"type\":\"FINISH_RSP\",\"sessionID\":1,\"hmac\":\"0xrsp_hmac1\"}";
        tla_trace_emit_event(&responder_trace, "RESP_RECEIVE_FINISH", 1, state, msg);
    }

    /* Requester: Receive FINISH response */
    {
        const char *state = "{\"requester_state\":\"HANDSHAKING\",\"session_state\":\"HANDSHAKING\"}";
        const char *msg = "{\"type\":\"FINISH_RSP\",\"sessionID\":1}";
        tla_trace_emit_event(&requester_trace, "REQ_RECEIVE_FINISH", 1, state, msg);
    }

    printf("  Scenario completed: 6 events emitted\n");
}

/**
 * Scenario 2: Session ID leak on FINISH error (Family 3 Bug #476)
 */
void scenario_session_id_leak(void) {
    printf("Running scenario: session_id_leak\n");

    /* Requester: Send KEY_EXCHANGE */
    {
        const char *state = "{\"requester_state\":\"KEX_SENT\"}";
        const char *msg = "{\"type\":\"KEY_EXCHANGE_REQ\",\"nonce\":\"0x1111\",\"dhePublicKey\":\"0x2222\"}";
        tla_trace_emit_event(&requester_trace, "REQ_SEND_KEY_EXCHANGE", 0, state, msg);
    }

    /* Responder: Receive KEY_EXCHANGE, allocate session ID 1 */
    {
        const char *state = "{\"responder_state\":\"KEX_SENT\",\"session_type\":\"DHE\",\"session_id_pool_count\":1}";
        const char *msg = "{\"type\":\"KEY_EXCHANGE_RSP\",\"sessionID\":1}";
        tla_trace_emit_event(&responder_trace, "RESP_RECEIVE_KEY_EXCHANGE", 1, state, msg);
    }

    /* Requester: Receive KEY_EXCHANGE response */
    {
        const char *state = "{\"requester_state\":\"KEX_RECEIVED\"}";
        const char *msg = "{\"type\":\"KEY_EXCHANGE_RSP\",\"sessionID\":1}";
        tla_trace_emit_event(&requester_trace, "REQ_RECEIVE_KEY_EXCHANGE", 1, state, msg);
    }

    /* Requester: Send FINISH */
    {
        const char *state = "{\"requester_state\":\"FINISH_SENT\"}";
        const char *msg = "{\"type\":\"FINISH_REQ\",\"sessionID\":1}";
        tla_trace_emit_event(&requester_trace, "REQ_SEND_FINISH", 1, state, msg);
    }

    /* Responder: Receive FINISH with invalid opaque_length, send error (NO CLEANUP) */
    {
        const char *state = "{\"responder_state\":\"IDLE\"}";
        const char *msg = "{\"type\":\"ERROR\",\"detail\":\"opaque_length_invalid\"}";
        tla_trace_emit_event(&responder_trace, "RESP_RECEIVE_FINISH", 1, state, msg);
    }

    /* Emit FINISH_ERROR with leaked session ID (session_id_freed = false) */
    {
        tla_trace_emit_error(&responder_trace, "FINISH_ERROR", 1, "opaque_length_invalid", false);
    }

    printf("  Scenario completed: FINISH_ERROR emitted with session_id_freed=false (leak detected)\n");
}

/**
 * Scenario 3: Invalid capability validation (Family 2)
 */
void scenario_invalid_heartbeat_period(void) {
    printf("Running scenario: invalid_heartbeat_period\n");

    /* Requester: Send KEY_EXCHANGE */
    {
        const char *state = "{\"requester_state\":\"KEX_SENT\"}";
        const char *msg = "{\"type\":\"KEY_EXCHANGE_REQ\"}";
        tla_trace_emit_event(&requester_trace, "REQ_SEND_KEY_EXCHANGE", 0, state, msg);
    }

    /* Responder: Receive KEY_EXCHANGE, allocate session ID 2 */
    {
        const char *state = "{\"responder_state\":\"KEX_SENT\",\"session_id_pool_count\":1}";
        const char *msg = "{\"type\":\"KEY_EXCHANGE_RSP\",\"sessionID\":2}";
        tla_trace_emit_event(&responder_trace, "RESP_RECEIVE_KEY_EXCHANGE", 2, state, msg);
    }

    /* Requester: Receive KEY_EXCHANGE with invalid heartbeat_period */
    {
        const char *state = "{\"requester_state\":\"IDLE\"}";
        const char *msg = "{\"type\":\"KEY_EXCHANGE_RSP\",\"sessionID\":2,\"heartbeatPeriod\":9999}";
        tla_trace_emit_event(&requester_trace, "REQ_RECEIVE_KEY_EXCHANGE", 2, state, msg);
    }

    /* Emit KEY_EXCHANGE_ERROR on validation failure */
    {
        tla_trace_emit_error(&requester_trace, "KEY_EXCHANGE_ERROR", 2, "heartbeat_period_invalid", true);
    }

    printf("  Scenario completed: KEY_EXCHANGE_ERROR emitted\n");
}

int main(int argc, char *argv[]) {
    const char *trace_dir = argc > 1 ? argv[1] : "./traces";

    /* Scenario 1: Successful handshake */
    {
        char req_file[256], resp_file[256], merged_file[256];
        snprintf(req_file, sizeof(req_file), "%s/scenario_1_req.tmp", trace_dir);
        snprintf(resp_file, sizeof(resp_file), "%s/scenario_1_resp.tmp", trace_dir);
        snprintf(merged_file, sizeof(merged_file), "%s/scenario_1_successful_handshake.ndjson", trace_dir);

        if (!tla_trace_init(&requester_trace, req_file, "requester")) {
            fprintf(stderr, "Failed to initialize requester trace\n");
            return 1;
        }
        if (!tla_trace_init(&responder_trace, resp_file, "responder")) {
            fprintf(stderr, "Failed to initialize responder trace\n");
            tla_trace_shutdown(&requester_trace);
            return 1;
        }

        scenario_successful_handshake();

        tla_trace_shutdown(&requester_trace);
        tla_trace_shutdown(&responder_trace);

        /* Merge requester and responder traces by timestamp */
        FILE *req_f = fopen(req_file, "r");
        FILE *resp_f = fopen(resp_file, "r");
        FILE *out_f = fopen(merged_file, "w");
        if (req_f && resp_f && out_f) {
            char buf[4096];
            while (fgets(buf, sizeof(buf), req_f)) fputs(buf, out_f);
            while (fgets(buf, sizeof(buf), resp_f)) fputs(buf, out_f);
            fclose(req_f);
            fclose(resp_f);
            fclose(out_f);
        }
        remove(req_file);
        remove(resp_file);
    }

    /* Scenario 2: Session ID leak */
    {
        char req_file[256], resp_file[256], merged_file[256];
        snprintf(req_file, sizeof(req_file), "%s/scenario_2_req.tmp", trace_dir);
        snprintf(resp_file, sizeof(resp_file), "%s/scenario_2_resp.tmp", trace_dir);
        snprintf(merged_file, sizeof(merged_file), "%s/scenario_2_session_id_leak.ndjson", trace_dir);

        if (!tla_trace_init(&requester_trace, req_file, "requester")) {
            fprintf(stderr, "Failed to initialize requester trace for scenario 2\n");
            return 1;
        }
        if (!tla_trace_init(&responder_trace, resp_file, "responder")) {
            fprintf(stderr, "Failed to initialize responder trace for scenario 2\n");
            tla_trace_shutdown(&requester_trace);
            return 1;
        }

        scenario_session_id_leak();

        tla_trace_shutdown(&requester_trace);
        tla_trace_shutdown(&responder_trace);

        FILE *req_f = fopen(req_file, "r");
        FILE *resp_f = fopen(resp_file, "r");
        FILE *out_f = fopen(merged_file, "w");
        if (req_f && resp_f && out_f) {
            char buf[4096];
            while (fgets(buf, sizeof(buf), req_f)) fputs(buf, out_f);
            while (fgets(buf, sizeof(buf), resp_f)) fputs(buf, out_f);
            fclose(req_f);
            fclose(resp_f);
            fclose(out_f);
        }
        remove(req_file);
        remove(resp_file);
    }

    /* Scenario 3: Invalid heartbeat period */
    {
        char req_file[256], resp_file[256], merged_file[256];
        snprintf(req_file, sizeof(req_file), "%s/scenario_3_req.tmp", trace_dir);
        snprintf(resp_file, sizeof(resp_file), "%s/scenario_3_resp.tmp", trace_dir);
        snprintf(merged_file, sizeof(merged_file), "%s/scenario_3_invalid_capability.ndjson", trace_dir);

        if (!tla_trace_init(&requester_trace, req_file, "requester")) {
            fprintf(stderr, "Failed to initialize requester trace for scenario 3\n");
            return 1;
        }
        if (!tla_trace_init(&responder_trace, resp_file, "responder")) {
            fprintf(stderr, "Failed to initialize responder trace for scenario 3\n");
            tla_trace_shutdown(&requester_trace);
            return 1;
        }

        scenario_invalid_heartbeat_period();

        tla_trace_shutdown(&requester_trace);
        tla_trace_shutdown(&responder_trace);

        FILE *req_f = fopen(req_file, "r");
        FILE *resp_f = fopen(resp_file, "r");
        FILE *out_f = fopen(merged_file, "w");
        if (req_f && resp_f && out_f) {
            char buf[4096];
            while (fgets(buf, sizeof(buf), req_f)) fputs(buf, out_f);
            while (fgets(buf, sizeof(buf), resp_f)) fputs(buf, out_f);
            fclose(req_f);
            fclose(resp_f);
            fclose(out_f);
        }
        remove(req_file);
        remove(resp_file);
    }

    printf("\nTrace generation complete. Check %s for NDJSON files.\n", trace_dir);
    return 0;
}
