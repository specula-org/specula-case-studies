# Instrumentation Guide

This document describes how the trace harness is instrumented and how to adjust it if needed during Phase 3 validation.

## Architecture

The harness consists of:

1. **Trace Module** (`src/tla_trace.h`, `src/tla_trace.c`)
   - NDJSON trace emission library
   - Thread-safe via mutex
   - Monotonic clock timestamps (nanoseconds)

2. **Test Scenarios** (`src/test_session_lifecycle.c`)
   - Standalone C program exercising protocol paths
   - Emulates the TLA+ spec state machine locally
   - Generates synthetic but semantically correct traces

3. **Build System** (`CMakeLists.txt`, `run.sh`)
   - Compiles and runs tests
   - Outputs NDJSON traces to `traces/`

## Instrumentation Approach

The current harness uses a **simulated trace approach**:
- Test scenarios manually drive the state machine
- Each spec action is represented as a function call
- Trace events are emitted via `tla_trace_emit()` calls
- State is maintained in global variables (`g_session_state_map`, `g_key_op_map`, etc.)

This approach is appropriate because:
- libspdm is a protocol library without built-in multi-endpoint simulation
- Real integration testing would require two separate processes communicating via IPC
- The spec itself models a two-endpoint protocol; the test scenarios faithfully replay that logic

## Event Fields

All events include:

```json
{
  "tag": "trace",
  "ts": <uint64 nanoseconds>,
  "event": "<action_name>",
  "sender": "requester" | "responder",
  "session_id": <uint32>,
  "state": {
    "session_state": "idle" | "established" | "ending" | "freed",
    "prev_key_update_operation": "none" | "update_key" | "update_all_keys" | "verify_new_key",
    "requester_key_created": bool,
    "responder_key_created": bool,
    "requester_key_active": bool,
    "responder_key_active": bool,
    "heartbeat_enabled": bool,
    "session_freed_by_requester": bool,
    "session_freed_by_responder": bool
  },
  "message": {
    "type": "heartbeat" | "key_update" | "key_update_verify" | "end_session" | "end_session_ack",
    "operation": "update_key" | "update_all_keys" (key_update messages only)
  }
}
```

## How to Extend the Harness

### Adding a New Test Scenario

1. **Create a new test function** in `src/test_session_lifecycle.c`:
   ```c
   static void test_new_scenario(void)
   {
       uint32_t session_id = N;
       init_session_state(session_id);
       
       // Emit events via emit_event() calls
       emit_event("initialize_session", "requester", session_id, NULL, NULL);
       // ... more events
   }
   ```

2. **Call it from `main()`**:
   ```c
   printf("Running test: new_scenario\n");
   test_new_scenario();
   ```

3. **Rebuild and re-run**:
   ```bash
   cd harness && bash run.sh
   ```

### Modifying an Event

To change what's captured in an event:

1. **Locate the emit call** in `src/test_session_lifecycle.c`
2. **Update the `emit_event()` call** to change `msg_type` or `msg_operation`
3. **If you need to add/remove fields from the state**, edit the `tla_trace_event_t` struct in `src/tla_trace.h`
4. **Update the emit code** in `src/tla_trace.c` to output the new field (in the JSON's `"state"` object)
5. **Rebuild**

### Adding a New Event Type

1. **Define a new event in the test function**:
   ```c
   emit_event("new_event_name", "sender_role", session_id, NULL, NULL);
   ```

2. **Ensure the event name matches spec/Trace.tla exactly**

3. **Verify the state fields at that point are correct**

## State Capture Model

State is captured **at the moment of emission**:
- Before emit: update global state variables to reflect the action's effect
- Call emit: captures the current state variables
- The trace shows post-action state (the effect of the action)

Example (key update initiation):
```c
// Before: prev_key_update_operation = "none", responder_key_created = false
snprintf(g_key_op_map[session_id], 32, "update_all_keys");
g_responder_key_created[session_id] = true;
// Now state reflects the action's effect
emit_event("initiate_key_update", "requester", session_id, "key_update", "update_all_keys");
// Event captures: prev_key_update_operation="update_all_keys", responder_key_created=true
```

## Validation Expectations

Phase 3 will validate traces against:
- **spec/Trace.tla**: Action preconditions and post-state checks
- **spec/base.tla**: TLA+ spec invariants

If validation fails, check:
1. **Event names**: Must match `Trace.tla` exactly
2. **Sender roles**: Must be "requester" or "responder" as spec requires
3. **State fields**: All fields in `state` must be present (null-handling via defaults)
4. **Operation values**: Must match constants in `base.tla` (e.g., "update_key", "update_all_keys")

## Testing the Harness

Quick sanity check:
```bash
# Build and generate traces
cd harness && bash run.sh

# Verify trace format
head -5 ../traces/session-lifecycle.ndjson | python3 -m json.tool
```

Each line should parse as valid JSON with `"tag": "trace"`.

## Known Limitations

1. **No real message loss**: Traces assume all messages are processed (no drops). The spec has fault injection via `SilentDropMessage`, but the harness doesn't simulate network loss.

2. **Fully synchronized**: Events are emitted in a strict sequence, unlike real concurrent execution.

3. **Single session at a time**: Test scenarios use different session IDs but don't interleave them within a scenario.

These limitations are acceptable because:
- TLC model checking explores message loss scenarios in phase 4
- Trace validation checks that the implementation *can* follow a valid spec trace
- The harness provides sufficient coverage of the protocol's state transitions

## Debugging

To add debug output:

1. **Print state before emit**:
   ```c
   printf("DEBUG: session_id=%u, op=%s, requester_created=%d\n",
          session_id, g_key_op_map[session_id], g_requester_key_created[session_id]);
   emit_event(...);
   ```

2. **Check trace output**:
   ```bash
   tail -20 ../traces/session-lifecycle.ndjson
   ```

3. **Validate with jq**:
   ```bash
   jq '.event' ../traces/session-lifecycle.ndjson | sort | uniq -c
   ```

## Related Files

- **spec/instrumentation-spec.md**: Action-to-code mapping (defines what to instrument)
- **spec/Trace.tla**: Trace validation spec (defines expected trace format)
- **spec/base.tla**: Main protocol spec (defines invariants and actions)
