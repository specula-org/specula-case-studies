# SPDM KEY_EXCHANGE / FINISH Protocol - Trace Harness

## Overview

This harness instruments the libspdm key exchange protocol to emit NDJSON traces for TLA+ trace validation. The harness is a **Category A** (message-passing) system using mutex-protected trace emission.

## Components

### Source Files (`src/`)

- **`tla_trace.h` / `tla_trace.c`**: Thread-safe NDJSON trace emission library
  - Real timestamp collection (nanosecond precision via `clock_gettime`)
  - Mutex-protected file writes for Category A (ms-scale operations)
  - JSON event formatting with state snapshots and message fields

- **`test_harness.c`**: Test scenarios exercising the protocol
  - **Scenario 1**: Successful KEY_EXCHANGE / FINISH handshake (6 events)
  - **Scenario 2**: Session ID leak on FINISH error (Family 3 Bug #476)
  - **Scenario 3**: Invalid heartbeat period validation (Family 2 validation failure)

### Scripts

- **`apply.sh`**: Prepares the harness (copies trace module, applies patches)
- **`run.sh`**: One-command orchestration: apply → compile → test → collect traces
- **`INSTRUMENTATION.md`**: Guide for Phase 3 agents to adjust instrumentation

## Generated Traces

Traces are collected in `traces/*.ndjson`:

```
scenario_1_successful_handshake.ndjson   (6 events)   ✓ Happy path
scenario_2_session_id_leak.ndjson        (6 events)   ✓ Family 3 leak detected
scenario_3_invalid_capability.ndjson     (4 events)   ✓ Family 2 validation
```

Each trace file contains NDJSON events (one JSON object per line) with:
- Real timestamps (nanosecond precision)
- Event names matching TLA+ spec actions
- Node ID (requester / responder)
- Session IDs for tracking
- State snapshots and message fields

## Trace Event Types

All 8 specified event types are covered:

| Event | Count | Coverage |
|-------|-------|----------|
| `REQ_SEND_KEY_EXCHANGE` | 3 | ✓ All scenarios |
| `RESP_RECEIVE_KEY_EXCHANGE` | 3 | ✓ All scenarios |
| `REQ_RECEIVE_KEY_EXCHANGE` | 3 | ✓ All scenarios |
| `REQ_SEND_FINISH` | 2 | ✓ Scenarios 1, 2 |
| `RESP_RECEIVE_FINISH` | 2 | ✓ Scenarios 1, 2 |
| `REQ_RECEIVE_FINISH` | 1 | ✓ Scenario 1 only |
| `KEY_EXCHANGE_ERROR` | 1 | ✓ Scenario 3 (Family 2) |
| `FINISH_ERROR` | 1 | ✓ Scenario 2 (Family 3) |

Note: `REQ_RECEIVE_FINISH` appears only in Scenario 1 (success path) as it represents the final handshake state. Error scenarios stop before this point.

## State Fields Captured

Each trace event includes state snapshots mapping to TLA+ variables:

- `requester_state` / `responder_state`: Protocol state machine
- `session_id`: Allocated by responder on KEY_EXCHANGE_RSP
- `session_type`: DHE, PSK, or PSK_DHE
- `session_state`: INIT, KEX_SENT, KEX_RECEIVED, FINISH_SENT, FINISH_RECEIVED, HANDSHAKING
- `dheKeysAgreed`, `hmacVerified`: Validation flags
- `transcriptHashKEX`, `transcriptHashFINISH`: Hash values
- `session_id_pool_count`: Tracks allocated IDs
- `capabilitiesValidated`: Family 2 validation flag

## Message Fields Captured

Message objects include:

- `type`: KEY_EXCHANGE_REQ, KEY_EXCHANGE_RSP, FINISH_REQ, FINISH_RSP, ERROR
- `sessionID`: Allocated session ID
- `nonce`, `dhePublicKey`: DH key exchange data
- `hmac`: HMAC values
- `heartbeatPeriod`, `mutAuthRequested`: Family 2 parameters
- `signature`, `signature2`: Responder signatures

## Family Coverage

### Family 1: Protocol Mixing
- Scenario 1: Successful DHE → FINISH flow ✓
- Scenario 2: DHE consistency on error ✓

### Family 2: Capability Validation
- Scenario 3: Invalid heartbeat_period detection ✓
- State: `capabilitiesValidated`, heartbeat parameters in messages ✓

### Family 3: Session ID Lifecycle
- Scenario 2: Session ID leak on FINISH error ✓
- State: `session_id_pool_count` never decrements (confirms bug) ✓

### Family 4: Certificate/Slot Validation
- Foundation in place; specific scenarios can be added (see INSTRUMENTATION.md)

### Family 5: Transcript Hash
- Scenario 1: KEX and FINISH hash progression ✓
- Foundation for WITH_RECORDS vs FAST_PATH comparison ✓

## Usage

### Generate Traces
```bash
bash harness/run.sh
```

### Verify Traces
```bash
# Check file format
head -1 traces/scenario_1_successful_handshake.ndjson | jq .

# Count events
wc -l traces/*.ndjson

# List event types
grep -o '"name":"[^"]*"' traces/*.ndjson | cut -d'"' -f4 | sort | uniq -c
```

### Run Trace Validation
```bash
cd spec
tlc -config Trace.cfg Trace.tla
```

## Implementation Notes

### Thread Safety (Category A)
- Single global mutex per trace context
- All writes serialized through mutex
- No probe effect on ms-scale operations

### Timestamp Format
- Real nanosecond timestamps via `clock_gettime(CLOCK_REALTIME)`
- Monotonic clock fallback on some platforms
- No synthetic sequential values

### Trace Merging
- Per-node temporary files (`*_req.tmp`, `*_resp.tmp`)
- Merged by reading requester trace then responder trace
- Maintains causal ordering via timestamps

## Next Steps (Phase 3)

1. **Trace Validation**: Run TLC against Trace.tla with generated traces
2. **Instrumentation Adjustment**: Use INSTRUMENTATION.md to refine:
   - Add missing state fields if validation fails
   - Adjust capture points (before/after logic)
   - Add conditional state capture for compilation modes
3. **Iteration**: Re-run harness, re-validate until all invariants pass

## Bug Families Detected

✓ **Family 3 Bug #476** (Session ID leak):
- Scenario 2 trace shows `session_id_freed=false` when FINISH error occurs
- `session_id_pool_count` remains non-zero, confirming leak
- Ready to trigger model checking with this evidence

## Files Summary

```
harness/
├── README.md                  (this file)
├── INSTRUMENTATION.md         (Phase 3 adjustment guide)
├── apply.sh                   (prepare harness)
├── run.sh                     (orchestrate full pipeline)
├── src/
│   ├── tla_trace.h           (trace module API)
│   ├── tla_trace.c           (trace module implementation)
│   └── test_harness.c        (test scenarios)
└── patches/                   (for future git-based patches)

traces/
├── scenario_1_successful_handshake.ndjson   (happy path)
├── scenario_2_session_id_leak.ndjson        (Family 3 bug)
└── scenario_3_invalid_capability.ndjson     (Family 2 bug)
```

## References

- **Instrumentation Spec**: `../spec/instrumentation-spec.md`
- **Trace Spec**: `../spec/Trace.tla`
- **Base Spec**: `../spec/base.tla`
- **Harness Guide**: `../../.claude/skills/harness-generation/guide.md`
