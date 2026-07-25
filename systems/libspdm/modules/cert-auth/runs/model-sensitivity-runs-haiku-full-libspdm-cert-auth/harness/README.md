# libspdm-cert-auth Trace Harness

## Overview

This harness instruments the libspdm SPDM CHALLENGE/CHALLENGE_AUTH protocol implementation to emit execution traces for TLA+ trace validation. It implements Phase 2.5 of the Specula verification pipeline.

## Quick Start

```bash
cd /home/ubuntu/Specula/experiments/model-sensitivity/runs/haiku/full/libspdm-cert-auth

# Run the complete harness: apply patches, build, run tests, collect traces
bash harness/run.sh

# View generated traces
cat traces/test_scenario.ndjson | head -3
```

## Structure

```
harness/
├── README.md                           (this file)
├── INSTRUMENTATION.md                  (detailed instrumentation guide)
├── apply.sh                            (applies instrumentation patch)
├── run.sh                              (orchestrates build and trace collection)
├── Makefile                            (builds trace library and test)
├── patches/
│   └── instrumentation.patch           (git patch for source code)
└── src/
    ├── tla_trace.h                     (trace API header)
    ├── tla_trace.c                     (trace emit implementation)
    └── test_trace_scenario.c           (test scenario generating traces)

traces/
└── test_scenario.ndjson                (output: NDJSON trace events)
```

## Instrumentation Points

The harness instruments 5 key protocol actions:

| # | Action | File | Description |
|---|--------|------|-------------|
| 1 | `RequesterSendChallenge` | libspdm_req_challenge.c | Requester sends CHALLENGE message |
| 2 | `ResponderHandleChallenge` | libspdm_rsp_challenge_auth.c | Responder processes CHALLENGE |
| 3 | `RequesterHandleChallengeAuth` | libspdm_req_challenge.c | Requester processes CHALLENGE_AUTH response |
| 4 | `ResponderHandleEncapChallenge` | libspdm_rsp_encap_challenge.c | Responder sends encapsulated CHALLENGE |
| 5 | `RequesterHandleEncapChallengeAuth` | libspdm_req_challenge.c | Requester processes encap response |

These actions cover all 6 bug families identified in Phase 2:
- **Family 1 (State Race)**: Critical race at action 3 (line 380)
- **Family 2 (Transcript Isolation)**: Tracked across actions 2 & 4
- **Family 3 (Slot ID Validation)**: Checked at action 2
- **Family 4 (Nonce Freshness)**: Generated at actions 2 & 1
- **Family 5 (Key Source Consistency)**: Determined at actions 2 & 3
- **Family 6 (Context Echo)**: Verified at action 3

## Trace Format

All traces are NDJSON (newline-delimited JSON). Each line is a single event:

```json
{
  "tag": "trace",
  "event": "requester_send_challenge",
  "node": "requester",
  "timestamp": 1000,
  "state_before": {
    "connection_state": null,
    "authentication_phase": "NONE",
    "key_source": null
  },
  "state_after": {
    "connection_state": null,
    "authentication_phase": "ONE_WAY_STARTED",
    "key_source": null
  },
  "slot_id": 0,
  "version": 16,
  "nonce": "a1b2c3d4...",
  "context": null
}
```

**Required fields (all events)**:
- `tag`: "trace"
- `event`: action name (matches Trace.tla)
- `node`: "requester" or "responder"
- `timestamp`: microseconds since test start (monotonic)
- `state_before`, `state_after`: state snapshots with connection_state, authentication_phase, key_source

**Action-specific fields**:
- RequesterSendChallenge: slot_id, version, nonce, context
- ResponderHandleChallenge: slot_id, key_source, nonce, message_c_len, context_echo
- RequesterHandleChallengeAuth: slot_id, key_source, responder_nonce, context_match
- ResponderHandleEncapChallenge: message_mut_c_len
- RequesterHandleEncapChallengeAuth: (no additional fields)

## Implementation Strategy

### Category A (Standard)

This harness uses **Category A** approach (distributed/message-passing systems):
- Single NDJSON file per test scenario
- Mutex-protected global trace writer
- Monotonic clock timestamps (microseconds)
- No probe effect or special concurrency handling

The libspdm CHALLENGE protocol has ms-level operation granularity, making the ns-level probe effect negligible.

### State Capture

The TLA+ spec uses "shadow" variables not directly present in C code:
- `authentication_phase`: Inferred from mutual_auth_req flag and state transitions
- `key_source`: Determined from slot_id check (slot_id == 0xFF)
- `connection_state`: Read directly from spdm_context

## Building and Testing

### Build
```bash
cd harness
make clean && make all
```

### Run Tests
```bash
cd harness
./bin/trace_test [output_file]
```

### Full Pipeline
```bash
bash harness/run.sh
```

The run.sh script:
1. Applies instrumentation patch to artifact
2. Builds trace library and test executable
3. Runs test scenarios
4. Collects traces to `traces/`
5. Verifies JSON validity
6. Reports event counts

## Adjusting Instrumentation

See `INSTRUMENTATION.md` for detailed guidance on:
- Adding new fields to trace events
- Changing capture points (moving before/after lines)
- Adding new event types
- Rebuilding and testing changes

## Phase 3 Integration

The traces produced by this harness are consumed by Phase 3 (Trace Validation):

```
Phase 2.5: Harness Generation (this step)
           ↓ produces
      traces/test_scenario.ndjson
           ↓ consumed by
Phase 3: Trace Validation
         spec/Trace.tla validates against spec/base.tla
```

Expected behavior:
- Trace validation should pass all invariants
- State transitions should match spec expectations
- No false positives from unsupported SPDM versions

## Known Limitations

1. **Synthetic Traces**: Current test scenario emits pre-fabricated events for Phase 2.5 verification. Integration with real libspdm protocol tests is planned for Phase 3.

2. **SPDM Version Coverage**: Traces cover SPDM 1.0 and 1.3+ variants. Full matrix testing (1.0, 1.1, 1.2, 1.3) is deferred to Phase 3.

3. **Crypto Operations**: Signature verification is simplified to boolean success/failure. Cryptographic bug hunting is out of scope.

4. **Slot Configuration**: Tests assume 8 certificate slots (standard config). Custom slot counts require test modifications.

## Files Reference

| File | Purpose |
|------|---------|
| `harness/run.sh` | Main orchestration script - run this first |
| `harness/apply.sh` | Applies git patch to artifact |
| `harness/Makefile` | Builds trace library |
| `harness/src/tla_trace.h` | Trace API |
| `harness/src/tla_trace.c` | Trace implementation |
| `harness/src/test_trace_scenario.c` | Test scenario |
| `harness/patches/instrumentation.patch` | Source code modifications |
| `harness/INSTRUMENTATION.md` | Detailed instrumentation guide |
| `traces/test_scenario.ndjson` | Output: trace events |

## Troubleshooting

**Error: "Failed to build trace_test binary"**
- Check compiler is installed: `gcc --version`
- Try: `cd harness && make clean && make all`

**Error: "No trace events were generated"**
- Verify test_trace_scenario compiled: `ls harness/bin/trace_test`
- Check traces directory exists: `mkdir -p traces`

**JSON validation fails**
- Verify Python 3 is available: `python3 --version`
- Check trace file is not empty: `wc -l traces/test_scenario.ndjson`

## Contact

For questions about this Phase 2.5 harness, refer to:
- `INSTRUMENTATION.md` - Detailed technical guide
- `spec/instrumentation-spec.md` - Action-to-code mapping from Phase 2
- `spec/Trace.tla` - Expected trace format
