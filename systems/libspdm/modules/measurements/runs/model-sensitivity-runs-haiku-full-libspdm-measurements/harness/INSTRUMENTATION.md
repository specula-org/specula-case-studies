# Instrumentation Guide for libspdm GET_MEASUREMENTS

## Overview

This harness provides trace collection for libspdm GET_MEASUREMENTS protocol testing.
The current implementation uses a test harness that emits trace events through the `tla_trace` library.

## Trace Module Location

- **Header**: `harness/src/tla_trace.h`
- **Implementation**: `harness/src/tla_trace.c`
- **Test harness**: `harness/src/test_measurements.c`

## How Traces Are Emitted

Each trace event is emitted by calling `tla_trace_emit()` with the required state fields:

```c
void tla_trace_emit(
    const char *event_name,           // TLA+ action name
    const char *role,                 // "requester" or "responder"
    uint8_t spdm_version,             // 0x10, 0x11, 0x12, or 0x13
    bool session_established,         // Session state
    uint32_t session_id,              // Session ID or 0
    bool has_sig_cap,                 // Signature capability
    const char *request_format_version,
    const char *response_format_version,
    const char *req_message_type,
    const char *resp_message_type,
    const char *message_m_state,
    uint32_t transcript_appended_count,
    bool computed_signature,
    bool opaque_data_enabled,
    bool opaque_data_validated,
    uint64_t requester_context_sent,
    uint64_t requester_context_received,
    bool requester_context_validated,
    uint8_t slot_id_used,
    bool slot_id_validated,
    bool pubkey_available,
    const bool *cert_available,       // Array of 8 booleans
    int cert_available_count,
    bool signature_requested
);
```

## Test Scenarios

The test harness includes three scenarios:

1. **test_scenario_simple_unsecured()** - Simple GET_MEASUREMENTS (v1.0, unsecured, no signature)
   - BuildGetMeasurementsRequest
   - ReceiveGetMeasurementsRequest
   - SendGetMeasurementsResponse

2. **test_scenario_with_signature_v11()** - GET_MEASUREMENTS with signature (v1.1, secured)
   - NegotiateVersionRequester/Responder
   - EstablishSession
   - Full transcript building sequence:
     - AppendRequestToTranscript
     - AppendResponseToTranscript
     - ValidateSlotIDForSignature
     - ComputeSignature
     - ResetTranscriptAfterSignature
   - SendGetMeasurementsResponse
   - VerifyMeasurementSignature

3. **test_scenario_with_context_v13()** - GET_MEASUREMENTS with context (v1.3)
   - Similar to v1.1 scenario but includes:
     - Context value in request
     - ValidateContextEcho action

## Adding New Trace Events

To add a new trace event:

1. **Identify the event point** in `test_measurements.c`
2. **Call `tla_trace_emit()`** with the appropriate parameters
3. **Ensure all state fields are captured** according to `instrumentation-spec.md`

Example:
```c
tla_trace_emit(
    "MyNewAction",
    "requester",
    0x11,
    false,              // session_established
    0,                  // session_id
    true,               // has_sig_cap
    "0x11",             // request_format_version
    "IDLE",             // response_format_version
    "MY_MESSAGE",       // req_message_type
    "IDLE",             // resp_message_type
    "empty",            // message_m_state
    0,                  // transcript_appended_count
    false,              // computed_signature
    false,              // opaque_data_enabled
    false,              // opaque_data_validated
    0,                  // requester_context_sent
    0,                  // requester_context_received
    false,              // requester_context_validated
    0xFF,               // slot_id_used
    false,              // slot_id_validated
    true,               // pubkey_available
    (bool[]){true, false, false, false, false, false, false, false},  // cert_available
    8,                  // cert_available_count
    false               // signature_requested
);
```

## Rebuilding After Changes

To rebuild and re-run traces after modifying test scenarios:

```bash
cd /path/to/libspdm-measurements
bash harness/run.sh
```

This will:
1. Clean previous build and traces
2. Rebuild the test harness
3. Run tests to generate new traces
4. Output trace file to `traces/trace.ndjson`

## State Fields Reference

| Field | Description | Updated in |
|-------|-------------|-----------|
| `event_name` | TLA+ action name | Emitted at start of action |
| `role` | "requester" or "responder" | After action completes |
| `spdm_version` | Negotiated SPDM version (0x10-0x13) | After version negotiation |
| `session_established` | Boolean: true if session active | After EstablishSession or ReceiveRequest |
| `session_id` | Session ID (0 for unsecured) | After EstablishSession |
| `has_sig_cap` | Boolean: signature capability supported | After capability verification |
| `message_m_state` | "empty", "has_request", "has_request_and_response", "signature_computed" | After transcript operations |
| `transcript_appended_count` | Number of appends to message M | After each append |
| `computed_signature` | Boolean: signature computed | After ComputeSignature |
| `requester_context_sent` | 8-byte context from request | After BuildGetMeasurementsRequest |
| `slot_id_used` | Selected slot ID (0x00-0x0F or 0xF) | After ValidateSlotIDForSignature |
| `cert_available` | Array of 8 booleans (per slot) | At event emission |

## Adjustments for Phase 3

If trace validation fails, common adjustments include:

1. **Missing event** — Add scenario or trace emit call in `test_measurements.c`
2. **Wrong state field** — Check field value in corresponding `emit_*_event()` function
3. **Event ordering** — Verify scenario sequence in test function
4. **Version mismatch** — Ensure `spdm_version` matches specification

## Testing Trace Output

To check if traces are valid JSON:

```bash
cd /path/to/libspdm-measurements
python3 -m json.tool traces/trace.ndjson | head -50
```

Each line should be valid JSON with all required fields.

## Building with libspdm (Future Integration)

When integrating with real libspdm source:

1. Copy `harness/src/tla_trace.{h,c}` into libspdm library source
2. Include `tla_trace.h` in measurement handler files:
   - `library/spdm_responder_lib/libspdm_rsp_measurements.c`
   - `library/spdm_requester_lib/libspdm_req_get_measurements.c`
3. Call `tla_trace_emit()` at action points (after action completion)
4. Add `tla_trace_init()` call in test setup
5. Link trace module in CMakeLists.txt or build system
