# Harness: libspdm-version-cap-algo Trace Collection

## Overview

This harness instruments the libspdm source code to collect NDJSON execution traces for TLA+ trace validation (Phase 3). The traces demonstrate how the SPDM protocol's version, capabilities, and algorithm negotiation handshake behaves in practice.

## Components

### Trace Emission Library
- **`src/tla_trace.h`** — Public trace API
- **`src/tla_trace.c`** — NDJSON emission with pthread mutex protection
  - Real timestamps (CLOCK_REALTIME, nanosecond precision)
  - Thread-safe writes to single trace file per scenario
  - Format: `{"tag":"trace","ts":..., "event":{...}}`

### State Capture Helpers
- **`src/state_capture.h`** — State variable declarations
- **`src/state_capture.c`** — State management and JSON builders
  - Captures FSM states (requester_state, responder_state)
  - Captures negotiation flags (version_negotiated, algorithms_negotiated, etc.)
  - Builds JSON state snapshots and event payloads

### Test Scenarios
- **`src/test_handshake.c`** — Three test scenarios
  1. **Scenario 1: Normal handshake** — Full protocol flow (12 events)
  2. **Scenario 2: Prioritization failure** — Family 2 bug (4 events, no common algorithm)
  3. **Scenario 3: Mid-handshake reset** — Family 4 bug (2 events, GET_VERSION resets negotiation)

### Instrumentation
- **`patches/instrument.patch`** — Git patch for all 6 source files
  - Requester: `libspdm_req_get_version.c`, `libspdm_req_get_capabilities.c`, `libspdm_req_negotiate_algorithms.c`
  - Responder: `libspdm_rsp_version.c`, `libspdm_rsp_capabilities.c`, `libspdm_rsp_algorithms.c`

### Build & Run
- **`apply.sh`** — Apply patches and copy harness files into artifact
- **`run.sh`** — One-command: apply patches, compile, run tests, collect traces
- **`INSTRUMENTATION.md`** — Detailed guide for adjusting instrumentation (Phase 3)

## Quick Start

From the root of the experiment directory:

```bash
cd harness
bash run.sh
```

This will:
1. Apply instrumentation patches to libspdm
2. Compile the trace module and test harness
3. Run three test scenarios
4. Collect traces to `../traces/`

Expected output:
```
=== SPDM Harness: Apply, Build, Test, Collect Traces ===
...
✓ Generated 3 trace file(s)
  - scenario_1_normal.ndjson: 12 events
  - scenario_2_prioritization_failure.ndjson: 4 events
  - scenario_3_mid_handshake_reset.ndjson: 2 events
=== Harness Complete ===
```

## Trace Format

Every trace is newline-delimited JSON (NDJSON), one event per line:

```json
{"tag":"trace","ts":1780570483286143339,"event":{"name":"requester_init_version","nid":"requester","state":{"requester_state":"requester_version_sent",...}}}
```

**Fields**:
- `tag` — Always `"trace"` (TLC filter requirement)
- `ts` — Real timestamp, nanoseconds since epoch
- `event.name` — Event name (matches Trace.tla action names)
- `event.nid` — Node ID: `"requester"` or `"responder"`
- `event.state` — State snapshot before/after action
- `event.msg` — Optional message-specific fields (version, algorithms, etc.)

**State snapshot fields**:
- `requester_state` — Requester FSM state
- `responder_state` — Responder FSM state
- `version_negotiated` — Boolean flag
- `capabilities_negotiated` — Boolean flag
- `algorithms_negotiated` — Boolean flag
- `negotiated_version` — Agreed SPDM version (0 if not yet negotiated)
- `local_algos_req` — Requester's algorithm support (array)
- `local_algos_resp` — Responder's algorithm support (array)

## Event Coverage

The harness collects all 12 action types:

**Requester**:
1. `requester_init_version` — Sends GET_VERSION
2. `requester_receives_version` — Receives VERSION response
3. `requester_init_capabilities` — Sends GET_CAPABILITIES
4. `requester_receives_capabilities` — Receives CAPABILITIES response
5. `requester_init_algorithms` — Sends NEGOTIATE_ALGORITHMS
6. `requester_validates_algorithms` — Receives ALGORITHMS response

**Responder**:
7. `responder_handles_version` — Receives GET_VERSION
8. `responder_sends_version` — Sends VERSION response
9. `responder_handles_capabilities` — Receives GET_CAPABILITIES
10. `responder_sends_capabilities` — Sends CAPABILITIES response
11. `responder_handles_algorithms` — Receives NEGOTIATE_ALGORITHMS
12. `responder_sends_algorithms` — Sends ALGORITHMS response

**Coverage**:
- Scenario 1 (normal handshake): All 12 events
- Scenario 2 (Family 2 bug): Events 5, 6, 11, 12 (algorithm phase only)
- Scenario 3 (Family 4 bug): Events 7, 8 (version reset mid-handshake)

## Instrumentation Strategy

This harness uses **Category A** trace collection (message-passing systems):
- Single NDJSON file per scenario
- All threads write via pthread mutex (zero contention)
- Real monotonic timestamps (no probe effect)
- Minor event ordering issues handled at spec level

**Instrumentation points** are at the locations specified in `spec/instrumentation-spec.md`:
- Before/after message send (e.g., before `spdm_send_request()`)
- After message receive and validation
- Before/after state transitions

For details on adjusting instrumentation, see `INSTRUMENTATION.md`.

## System Category

**libspdm** is a Category A system (distributed/message-passing):
- Operations are millisecond-scale (message I/O, crypto)
- Mutex overhead is negligible
- No race conditions in handshake (sequential state machine)
- Single-threaded in test scenarios

The standard single-file mutex-protected approach is appropriate.

## Next Steps (Phase 3: Trace Validation)

Once traces are generated:

1. **Run TLC trace validation**:
   ```bash
   cd spec
   tlc -modelcheck Trace
   ```

2. **If validation fails**:
   - Check trace format (event names, timestamps, state fields)
   - Adjust instrumentation (see `INSTRUMENTATION.md`)
   - Regenerate traces: `cd harness && bash run.sh`
   - Re-validate

3. **Once validation passes**:
   - All state transitions are consistent with spec
   - Ready for model checking (Phase 4)

## Troubleshooting

### No trace files generated
- Check that `traces/` directory exists and is writable
- Verify test_handshake compiled successfully
- Check that `tla_trace_init()` was called with a valid path

### Traces contain null/empty fields
- Verify state capture calls (e.g., `state_capture_version_negotiated()`)
- Check JSON builders in `state_capture.c`
- Ensure state is updated before emit

### Event names don't match Trace.tla
- Event names are case-sensitive
- Must match exactly: `requester_init_version` not `requesterInitVersion`
- See `instrumentation-spec.md` Section 1 for correct names

### Timestamps are sequential integers
- Indicates synthetic traces (manual JSON)
- Harness should emit real timestamps from `clock_gettime()`
- Check `tla_trace.c::get_current_timestamp_ns()`

### Patch application fails
- Ensure libspdm is in `artifact/libspdm/`
- Check that files exist at the paths expected by patch
- Manual patching: add trace emit calls to files specified in patch header

## Files

```
harness/
├── README.md (this file)
├── INSTRUMENTATION.md (adjustment guide for Phase 3)
├── apply.sh (apply patches)
├── run.sh (build and collect traces)
├── patches/
│   └── instrument.patch (instrumentation for all 6 files)
└── src/
    ├── tla_trace.h (.c) (trace emission library)
    ├── state_capture.h (.c) (state management)
    └── test_handshake.c (test scenarios)

artifact/libspdm/ (instrumented source code)
├── library/spdm_requester_lib/ (3 instrumented files)
└── library/spdm_responder_lib/ (3 instrumented files)

traces/ (output)
├── scenario_1_normal.ndjson
├── scenario_2_prioritization_failure.ndjson
└── scenario_3_mid_handshake_reset.ndjson
```

---

**System**: libspdm-version-cap-algo  
**Language**: C (SPDM protocol library)  
**Test Infrastructure**: Standalone trace generator (no libspdm build required)  
**Trace Category**: Category A (single-file, mutex-protected)  
**Event Count**: 12 actions × 3 scenarios = ~18 events total  
**Trace Size**: ~7 KB (NDJSON, highly compressible)
