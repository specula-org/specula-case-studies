# libspdm-psk-exchange Trace Harness

This harness instruments the libspdm library's PSK exchange protocol implementation to collect execution traces for TLA+ trace validation (Phase 3).

## Overview

The harness:
1. **Instruments source code** - Adds trace emit calls at key protocol actions
2. **Builds test scenarios** - Exercises the protocol with different code paths
3. **Collects NDJSON traces** - Generates structured event logs for validation
4. **Validates output** - Verifies traces match the expected schema

## Quick Start

```bash
bash harness/run.sh
```

This executes:
1. Applies instrumentation patches to `artifact/libspdm/`
2. Compiles the trace module and test scenarios
3. Runs all test scenarios to collect traces
4. Verifies traces were generated in `traces/`

## Files

### Source Code
- `src/tla_trace.h` - Trace module header (data structures)
- `src/tla_trace.c` - Trace emission implementation (NDJSON writing)
- `src/test_psk_exchange.c` - Basic trace initialization test
- `src/test_scenarios.c` - Comprehensive test scenarios

### Configuration
- `apply.sh` - Applies instrumentation patches
- `run.sh` - Main execution script (builds and runs tests)
- `INSTRUMENTATION.md` - Technical guide for modifying instrumentation

### Output
- `../traces/*.ndjson` - Generated NDJSON trace files
  - `scenario_happy_path.ndjson` - Full PSK exchange protocol
  - `scenario_bounds.ndjson` - Opaque length bounds validation
  - `scenario_session_ids.ndjson` - Session ID allocation tracking
  - `test_init.ndjson` - Basic initialization test

## Architecture

### Trace Emission
The trace module (`tla_trace.c`) provides thread-safe NDJSON emission:
- `tla_trace_init(file)` - Opens trace file
- `tla_trace_emit(...)` - Writes one event (thread-safe via mutex)
- `tla_trace_shutdown()` - Flushes and closes file

### Trace Schema
Each event is valid NDJSON with:
```json
{
  "tag": "trace",
  "ts": <nanosecond timestamp>,
  "event": {
    "name": "<ActionName>",
    "nid": "<node_id>",
    "state": { ... },
    "msg": { ... }
  }
}
```

### Instrumentation Points
The harness instruments these PSK exchange actions:
1. **RequesterSendPskExchange** - Requester sends PSK_EXCHANGE message
2. **ResponderRecvPskExchange** - Responder receives and validates message
3. **ResponderSendPskExchangeRsp** - Responder sends PSK_EXCHANGE_RSP
4. **RequesterRecvPskExchangeRsp** - Requester receives response

### Source Code Modifications
Files modified in `artifact/libspdm/`:
- `library/spdm_requester_lib/libspdm_req_psk_exchange.c` (2 trace points)
- `library/spdm_responder_lib/libspdm_rsp_psk_exchange_rsp.c` (2 trace points)

See `INSTRUMENTATION.md` for exact line numbers and how to modify.

## Test Scenarios

### Scenario 1: Happy Path
Tests successful PSK exchange:
- Requester allocates session ID and sends PSK_EXCHANGE
- Responder receives, validates, and responds
- Requester receives response and establishes session
- 4 trace events covering the full handshake

### Scenario 2: Opaque Data Bounds
Tests opaque length validation (Family 1 bug focus):
- Exercises implicit bounds checking in responder
- Sends valid opaque data and verifies checks pass
- 2 trace events: send and receive

### Scenario 3: Session ID Tracking
Tests session ID allocation (Family 2 bug focus):
- Allocates multiple session IDs
- Tracks allocated_ids array through multiple requests
- 2 trace events showing ID allocation progression

## Output Format

Each scenario generates a separate trace file with NDJSON events:

```bash
$ ls -lh traces/
-rw-rw-r-- scenario_happy_path.ndjson     512 bytes (4 events)
-rw-rw-r-- scenario_bounds.ndjson        256 bytes (2 events)
-rw-rw-r-- scenario_session_ids.ndjson   320 bytes (2 events)
-rw-rw-r-- test_init.ndjson              141 bytes (1 event)
```

Validate with jq:
```bash
jq . traces/scenario_happy_path.ndjson | head -30
```

## Key Fields Captured

### State Snapshot
- `pc` - Program counter label (e.g., "sent_psk_exchange")
- `session_state` - Session state (IDLE, HANDSHAKING, ESTABLISHED)
- `allocated_ids` - Array of allocated session IDs
- `version_negotiated` - Whether version was negotiated
- `opaque_length_checked` - Whether bounds check passed
- `context_length_checked` - Whether context validation passed

### Message Fields
- `req_session_id` - Requester's allocated session ID
- `rsp_session_id` - Responder's allocated session ID
- `opaque_length` - Size of opaque data
- `context_length` - Size of context data
- `psk_hint_length` - Size of PSK hint
- `opaque_data` - Boolean: opaque data present
- `context_data` - Boolean: context data present
- `version_negotiated` - Boolean: version in opaque data
- `use_default_opaque` - Boolean: used default version data
- `opaque_data_valid` - Boolean: opaque data parsed successfully
- `session_id` - Combined session ID after assignment

## Extending the Harness

### Add a New Test Scenario
1. Edit `src/test_scenarios.c` and add a new scenario function
2. Update `main()` to handle the new scenario name
3. Recompile: `bash run.sh` (or manually run gcc)
4. Run: `src/test_scenarios <new_scenario> traces/new.ndjson`

### Add Instrumentation Points
1. Identify the code location in `artifact/libspdm/`
2. Add `#include "../../../harness/src/tla_trace.h"` if not already present
3. Add a `tla_trace_emit()` call with the appropriate fields
4. Copy the change to `artifact_patched/` and reapply patches

### Modify Captured Fields
1. Edit `src/tla_trace.h` to add fields to the struct
2. Update `src/tla_trace.c` to emit the new fields in JSON
3. Update instrumentation points to populate the new fields
4. Recompile and test

## Troubleshooting

### No traces generated
- Check `traces/` directory is writable
- Verify `tla_trace_init()` is called in test
- Ensure `tla_trace_shutdown()` is called to flush
- Check for compilation errors (should see in output)

### Wrong event counts
- Verify test scenarios complete (check for timeout)
- Check stderr for trace module errors
- Verify trace file is being written (not opening as read-only)

### Missing fields in traces
- Verify source code instrumentation was applied correctly:
  ```bash
  grep -n "tla_trace_emit" artifact/libspdm/library/spdm_requester_lib/*.c
  ```
- Check that msg_fields struct is fully populated before emit
- Verify fields match those expected by Trace.tla schema

### JSON validation
All traces must be valid NDJSON (one JSON object per line):
```bash
jq empty traces/*.ndjson
```

## Next Steps: Phase 3 (Trace Validation)

The Phase 3 agent will:
1. Load the NDJSON traces from `traces/`
2. Run TLC model checking with `Trace.tla`
3. Validate that implementation behavior matches spec
4. Report any violations or bugs found

For Phase 3 to succeed:
- ✓ All required events must be traced
- ✓ Event names must match `Trace.tla` exactly
- ✓ State fields must be populated correctly
- ✓ Messages fields must be accurate
- ✓ Timestamps must be real (not synthetic)

Current coverage:
- ✓ RequesterSendPskExchange
- ✓ ResponderRecvPskExchange
- ✓ ResponderSendPskExchangeRsp
- ✓ RequesterRecvPskExchangeRsp
- ⏳ RequesterSendPskFinish (not yet instrumented)
- ⏳ ResponderRecvPskFinish (not yet instrumented)
- ⏳ ResponderSendPskFinishRsp (not yet instrumented)
- ⏳ RequesterRecvPskFinishRsp (not yet instrumented)

## See Also

- `INSTRUMENTATION.md` - Technical details on instrumentation points
- `/spec/instrumentation-spec.md` - Phase 2 spec (action-to-code mapping)
- `/spec/Trace.tla` - Phase 3 validation spec
- `/spec/base.tla` - Base protocol specification

