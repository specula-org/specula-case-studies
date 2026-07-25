/*
 * Simple test harness to exercise libspdm GET_MEASUREMENTS flow
 * with trace event emission
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include "tla_trace.h"

/*
 * Mock trace event emission for testing
 * In a real scenario, these would be called from within libspdm
 */

/* Helper to emit requester trace events */
void emit_requester_event(
    const char *event_name,
    uint8_t spdm_version,
    bool session_established,
    uint32_t session_id,
    bool has_sig_cap,
    const char *request_format_version,
    uint64_t requester_context_sent)
{
    bool cert_available[8] = {true, false, false, false, false, false, false, false};

    tla_trace_emit(
        event_name,
        "requester",
        spdm_version,
        session_established,
        session_id,
        has_sig_cap,
        request_format_version,
        "IDLE",
        "GET_MEASUREMENTS",
        "IDLE",
        "empty",
        0,
        false,
        spdm_version >= 0x12,
        false,
        requester_context_sent,
        0,
        false,
        0xFF,
        false,
        true,
        cert_available,
        8,
        true
    );
}

/* Helper to emit responder trace events */
void emit_responder_event(
    const char *event_name,
    uint8_t spdm_version,
    bool session_established,
    uint32_t session_id,
    bool has_sig_cap,
    const char *message_m_state,
    uint32_t transcript_appended_count,
    uint8_t slot_id_used)
{
    bool cert_available[8] = {true, false, false, false, false, false, false, false};

    tla_trace_emit(
        event_name,
        "responder",
        spdm_version,
        session_established,
        session_id,
        has_sig_cap,
        "0x10",
        "0x10",
        "GET_MEASUREMENTS",
        "MEASUREMENTS",
        message_m_state,
        transcript_appended_count,
        strcmp(message_m_state, "signature_computed") == 0,
        spdm_version >= 0x12,
        spdm_version >= 0x12,
        0,
        0,
        false,
        slot_id_used,
        true,
        true,
        cert_available,
        8,
        true
    );
}

/* Test scenario 1: Simple GET_MEASUREMENTS exchange (unsecured, no signature) */
void test_scenario_simple_unsecured(void)
{
    fprintf(stderr, "Running scenario: simple unsecured GET_MEASUREMENTS\n");

    /* Requester sends GET_MEASUREMENTS request */
    emit_requester_event("BuildGetMeasurementsRequest", 0x10, false, 0, false, "0x10", 0);

    /* Responder receives request */
    emit_responder_event("ReceiveGetMeasurementsRequest", 0x10, false, 0, false, "empty", 0, 0xFF);

    /* Responder sends response */
    emit_responder_event("SendGetMeasurementsResponse", 0x10, false, 0, false, "empty", 0, 0xFF);
}

/* Test scenario 2: GET_MEASUREMENTS with signature (v1.1, secured) */
void test_scenario_with_signature_v11(void)
{
    fprintf(stderr, "Running scenario: GET_MEASUREMENTS with signature (v1.1, secured)\n");

    /* Requester sends version negotiation */
    emit_requester_event("NegotiateVersionRequester", 0x11, false, 0, true, "0x11", 0);

    /* Responder receives version negotiation */
    emit_responder_event("NegotiateVersionResponder", 0x11, false, 0, true, "empty", 0, 0xFF);

    /* Responder establishes session */
    emit_responder_event("EstablishSession", 0x11, true, 1, true, "empty", 0, 0xFF);

    /* Requester builds GET_MEASUREMENTS request with signature */
    emit_requester_event("BuildGetMeasurementsRequest", 0x11, true, 1, true, "0x11", 0);

    /* Responder receives request */
    emit_responder_event("ReceiveGetMeasurementsRequest", 0x11, true, 1, true, "empty", 0, 0xFF);

    /* Responder appends request to transcript */
    emit_responder_event("AppendRequestToTranscript", 0x11, true, 1, true, "has_request", 1, 0xFF);

    /* Responder appends response to transcript */
    emit_responder_event("AppendResponseToTranscript", 0x11, true, 1, true, "has_request_and_response", 2, 0xFF);

    /* Responder validates slot ID for signature */
    emit_responder_event("ValidateSlotIDForSignature", 0x11, true, 1, true, "has_request_and_response", 2, 0);

    /* Responder computes signature */
    emit_responder_event("ComputeSignature", 0x11, true, 1, true, "signature_computed", 2, 0);

    /* Responder resets transcript */
    emit_responder_event("ResetTranscriptAfterSignature", 0x11, true, 1, true, "empty", 0, 0);

    /* Responder sends response */
    emit_responder_event("SendGetMeasurementsResponse", 0x11, true, 1, true, "empty", 0, 0);

    /* Requester validates context echo (for v1.3+, this is a no-op for v1.1) */

    /* Requester verifies signature */
    emit_requester_event("VerifyMeasurementSignature", 0x11, true, 1, true, "0x11", 0);
}

/* Test scenario 3: GET_MEASUREMENTS with context (v1.3) */
void test_scenario_with_context_v13(void)
{
    fprintf(stderr, "Running scenario: GET_MEASUREMENTS with context (v1.3)\n");

    /* Requester sends version negotiation */
    emit_requester_event("NegotiateVersionRequester", 0x13, false, 0, true, "0x13", 0);

    /* Responder receives version negotiation */
    emit_responder_event("NegotiateVersionResponder", 0x13, false, 0, true, "empty", 0, 0xFF);

    /* Requester builds GET_MEASUREMENTS request with context */
    uint64_t context = 0x123456789ABCDEF0ULL;
    emit_requester_event("BuildGetMeasurementsRequest", 0x13, false, 0, true, "0x13", context);

    /* Responder receives request */
    emit_responder_event("ReceiveGetMeasurementsRequest", 0x13, false, 0, true, "empty", 0, 0xFF);

    /* Responder appends request to transcript */
    emit_responder_event("AppendRequestToTranscript", 0x13, false, 0, true, "has_request", 1, 0xFF);

    /* Responder appends response to transcript */
    emit_responder_event("AppendResponseToTranscript", 0x13, false, 0, true, "has_request_and_response", 2, 0xFF);

    /* Responder validates slot ID for signature */
    emit_responder_event("ValidateSlotIDForSignature", 0x13, false, 0, true, "has_request_and_response", 2, 0xF);

    /* Responder computes signature */
    emit_responder_event("ComputeSignature", 0x13, false, 0, true, "signature_computed", 2, 0xF);

    /* Responder resets transcript */
    emit_responder_event("ResetTranscriptAfterSignature", 0x13, false, 0, true, "empty", 0, 0xF);

    /* Responder sends response with context echo */
    emit_responder_event("SendGetMeasurementsResponse", 0x13, false, 0, true, "empty", 0, 0xF);

    /* Requester validates context echo */
    emit_requester_event("ValidateContextEcho", 0x13, false, 0, true, "0x13", context);

    /* Requester verifies signature */
    emit_requester_event("VerifyMeasurementSignature", 0x13, false, 0, true, "0x13", context);
}

int main(int argc, char *argv[])
{
    const char *trace_file = argc > 1 ? argv[1] : "../traces/trace.ndjson";

    fprintf(stderr, "Initializing trace system: %s\n", trace_file);
    tla_trace_init(trace_file);

    /* Run test scenarios */
    test_scenario_simple_unsecured();
    test_scenario_with_signature_v11();
    test_scenario_with_context_v13();

    /* Close trace file */
    tla_trace_close();

    fprintf(stderr, "Trace collection complete: %s\n", trace_file);
    return 0;
}
