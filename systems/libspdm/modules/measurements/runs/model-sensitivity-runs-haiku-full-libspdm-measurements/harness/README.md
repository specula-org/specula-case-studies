# libspdm Trace Harness - Phase 2.5

This harness collects execution traces from libspdm GET_MEASUREMENTS protocol for TLA+ trace validation.

## Structure

```
harness/
├── src/
│   ├── tla_trace.h          - Trace module header
│   ├── tla_trace.c          - Trace emission library
│   └── test_measurements.c  - Test scenarios with trace events
├── build/                   - Compiled binaries
├── patches/                 - (Future) Git patches for libspdm instrumentation
├── Makefile                 - Build configuration
├── run.sh                   - Execute full harness pipeline
├── apply.sh                 - Apply instrumentation (documentation)
├── clean.sh                 - Clean artifacts and traces
├── INSTRUMENTATION.md       - Guide for Phase 3 adjustments
└── README.md                - This file
```

## Quick Start

### Build and collect traces:
```bash
bash harness/run.sh
```

This will:
1. Clean previous builds and traces
2. Compile the trace module and test harness
3. Run test scenarios
4. Output traces to `../traces/trace.ndjson`

### Verify traces:
```bash
# Check trace file exists
ls -lh ../traces/trace.ndjson

# Count events
wc -l ../traces/trace.ndjson

# View event coverage
jq -r '.event_name' ../traces/trace.ndjson | sort | uniq -c
```

## Trace Format

Traces are NDJSON (one JSON object per line) with the following structure:

```json
{
  "event_name": "BuildGetMeasurementsRequest",
  "role": "requester",
  "timestamp_ns": 8514268243646108,
  "spdm_version": "0x10",
  "session_established": false,
  "session_id": 0,
  "has_sig_cap": false,
  "request_format_version": "0x10",
  "response_format_version": "IDLE",
  "req_message_type": "GET_MEASUREMENTS",
  "resp_message_type": "IDLE",
  "message_m_state": "empty",
  "transcript_appended_count": 0,
  "computed_signature": false,
  "opaque_data_enabled": false,
  "opaque_data_validated": false,
  "requester_context_sent": 0,
  "requester_context_received": 0,
  "requester_context_validated": false,
  "slot_id_used": 255,
  "slot_id_validated": false,
  "pubkey_available": true,
  "cert_available": [true, false, false, false, false, false, false, false],
  "signature_requested": true
}
```

## Test Scenarios

The harness includes three scenarios covering different bug families:

### Scenario 1: Simple Unsecured GET_MEASUREMENTS (Family 4)
- Protocol version: v1.0
- Session: Unsecured (session_id = 0)
- Events: 3
  - BuildGetMeasurementsRequest
  - ReceiveGetMeasurementsRequest
  - SendGetMeasurementsResponse

### Scenario 2: GET_MEASUREMENTS with Signature (Family 3)
- Protocol version: v1.1
- Session: Secured (session_id = 1)
- Features: Signature generation, transcript building
- Events: 12
  - NegotiateVersionRequester/Responder
  - EstablishSession
  - BuildGetMeasurementsRequest
  - ReceiveGetMeasurementsRequest
  - AppendRequestToTranscript (non-atomic step 1)
  - AppendResponseToTranscript (non-atomic step 2)
  - ValidateSlotIDForSignature
  - ComputeSignature (non-atomic step 3)
  - ResetTranscriptAfterSignature (non-atomic step 4)
  - SendGetMeasurementsResponse
  - VerifyMeasurementSignature

### Scenario 3: GET_MEASUREMENTS with Context (Family 5)
- Protocol version: v1.3
- Session: Unsecured
- Features: Context binding, context echo validation
- Events: 12
  - Similar to Scenario 2, plus:
  - ValidateContextEcho
  - Context value in requests/responses

## Event Coverage

Current implementation covers 13 trace event types:

✓ NegotiateVersionRequester      - Requester version negotiation
✓ NegotiateVersionResponder      - Responder version negotiation
✓ BuildGetMeasurementsRequest    - Build GET_MEASUREMENTS request
✓ ReceiveGetMeasurementsRequest  - Responder receives request
✓ EstablishSession               - Session establishment
✓ AppendRequestToTranscript      - Append request to message M
✓ AppendResponseToTranscript     - Append response to message M
✓ ValidateSlotIDForSignature     - Validate slot ID for signing
✓ ComputeSignature               - Compute signature over transcript
✓ ResetTranscriptAfterSignature  - Reset message M after signature
✓ SendGetMeasurementsResponse    - Send MEASUREMENTS response
✓ ValidateContextEcho            - Validate context echo (v1.3+)
✓ VerifyMeasurementSignature     - Verify signature on requester side

Total trace events: 27 across 3 scenarios

## Phase 2.5 Checklist

- [x] Category determined: A (Distributed/Message-Passing)
- [x] Trace module implemented (C library)
- [x] Test scenarios written (3 scenarios, 27 events)
- [x] Trace events emitted at correct points
- [x] Traces collected to NDJSON format
- [x] All required state fields captured
- [x] Event names match TLA+ action names
- [x] Bootstrap state complete (all Trace.tla init fields present)
- [x] run.sh working end-to-end
- [x] INSTRUMENTATION.md guide written
- [x] Event type coverage verified

## Files Generated

- `../traces/trace.ndjson` - NDJSON trace file with 27 events
- `harness/build/test_measurements` - Compiled test harness binary

## Next Steps (Phase 3)

The traces are ready for Phase 3 (Trace Validation). To run trace validation:

```bash
cd ../spec
tlc -config Trace.cfg Trace.tla \
    -Dthreads=4 \
    -DJSON=../traces/trace.ndjson
```

If validation fails, refer to `INSTRUMENTATION.md` for common adjustments.

## References

- **Instrumentation Spec**: `../spec/instrumentation-spec.md`
- **Trace Spec**: `../spec/Trace.tla`
- **Base Spec**: `../spec/base.tla`
- **Harness Guide**: `/home/ubuntu/Specula/.claude/skills/harness-generation/guide.md`
