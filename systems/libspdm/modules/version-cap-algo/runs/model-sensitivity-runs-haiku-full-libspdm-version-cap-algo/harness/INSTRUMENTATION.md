# Instrumentation Guide for libspdm-version-cap-algo

## Overview

This document explains how the libspdm source code is instrumented for trace collection and how to adjust the instrumentation if needed during Phase 3 (Trace Validation).

## Instrumentation Points

The following table shows where each trace event is emitted in the source code:

| Event Name | File | Approximate Line | Emission Point | State Capture |
|-----------|------|-----------------|-----------------|---------------|
| `requester_init_version` | `library/spdm_requester_lib/libspdm_req_get_version.c` | ~80 | After message construction, before send | `requester_state` → "requester_version_sent" |
| `requester_receives_version` | `library/spdm_requester_lib/libspdm_req_get_version.c` | ~175 | After version validation, before state update | `version_negotiated` → true, `negotiated_version`, `requester_state` |
| `requester_init_capabilities` | `library/spdm_requester_lib/libspdm_req_get_capabilities.c` | ~95 | After message construction, before send | Standard state snapshot |
| `requester_receives_capabilities` | `library/spdm_requester_lib/libspdm_req_get_capabilities.c` | ~155 | After CAPABILITIES received, before state update | `capabilities_negotiated` → true, `requester_state` |
| `requester_init_algorithms` | `library/spdm_requester_lib/libspdm_req_negotiate_algorithms.c` | ~225 | After message construction, before send | `proposed_algos` array, `requester_state` |
| `requester_validates_algorithms` | `library/spdm_requester_lib/libspdm_req_negotiate_algorithms.c` | ~561 | After validation logic, before state update | `algorithms_negotiated` flag, `agreed_algos`, `requester_state` |
| `responder_handles_version` | `library/spdm_responder_lib/libspdm_rsp_version.c` | ~80 | After GET_VERSION received, before reset | Standard state snapshot |
| `responder_sends_version` | `library/spdm_responder_lib/libspdm_rsp_version.c` | ~120 | After response construction, before send | `version_negotiated` → true, `negotiated_version`, `responder_state` |
| `responder_handles_capabilities` | `library/spdm_responder_lib/libspdm_rsp_capabilities.c` | ~203 | After GET_CAPABILITIES received | Standard state snapshot |
| `responder_sends_capabilities` | `library/spdm_responder_lib/libspdm_rsp_capabilities.c` | ~361 | After response construction, before send | `responder_state` |
| `responder_handles_algorithms` | `library/spdm_responder_lib/libspdm_rsp_algorithms.c` | ~625 | After algorithm parsing, before assignment | `proposed_algos` array, `prioritization_failed` flag |
| `responder_sends_algorithms` | `library/spdm_responder_lib/libspdm_rsp_algorithms.c` | ~768 | After response construction, before send | `agreed_algos`, `responder_state` |

## Trace Module Architecture

### Files

- **`harness/src/tla_trace.h`** — Main trace emission API
  - `tla_trace_init(filename)` — Open trace file
  - `tla_trace_emit(event)` — Emit a single NDJSON event
  - `tla_trace_shutdown()` — Flush and close

- **`harness/src/tla_trace.c`** — Implementation
  - Uses POSIX `pthread_mutex` for thread safety
  - Real timestamps via `clock_gettime(CLOCK_REALTIME, ...)`
  - NDJSON format with `"tag": "trace"` envelope

- **`harness/src/state_capture.h`** — State snapshot helpers
  - `state_capture_*()` functions — Set captured state variables
  - `build_state_json()` — Serialize state to JSON
  - `build_event_json_*()` — Build event-specific JSON objects

- **`harness/src/state_capture.c`** — State management
  - Global state variables (requester_state, responder_state, etc.)
  - JSON serialization helpers

## How to Add a New Field to an Event

### Example: Add `connection_info.version` to `requester_receives_version`

1. **Update state capture** (`harness/src/state_capture.h`):
   ```c
   void state_capture_some_field(int value);
   ```

2. **Implement state capture** (`harness/src/state_capture.c`):
   ```c
   int capture_some_field = 0;
   void state_capture_some_field(int value) {
       capture_some_field = value;
   }
   ```

3. **Update JSON builder** to include the new field in `build_state_json()`:
   ```c
   snprintf(buf, 1024,
            "{...,\"some_field\":%d,...}",
            ..., capture_some_field, ...);
   ```

4. **Call the capture function** at the instrumentation point:
   ```c
   state_capture_some_field(connection_info.version);
   state_json = build_state_json();
   tla_trace_event_t evt = {..., .state_json = state_json};
   tla_trace_emit(&evt);
   free(state_json);
   ```

## How to Add a New Event Type

### Example: Add `requester_error` event

1. **Define event name** in instrumentation spec (e.g., `"requester_error"`)

2. **Add instrumentation point** in source code:
   ```c
   state_capture_requester_state("some_state");
   char *state_json = build_state_json();
   tla_trace_event_t evt = {
       .event = "requester_error",
       .node_id = "requester",
       .state_json = state_json,
       .msg_json = NULL
   };
   tla_trace_emit(&evt);
   free(state_json);
   ```

3. **Update Trace.tla** to handle the new event (see `Trace.tla` for action wrapper pattern)

## How to Move an Instrumentation Point

If an event is being emitted at the wrong location (e.g., before vs. after a state update):

1. **Remove the old emit call** from its current location
2. **Add the new emit call** at the correct location
3. **Update the instrumentation spec** to document the new location
4. **Rebuild**: `cd harness && bash run.sh`

## How to Change State Capture Scope

The spec defines three capture levels:

- **Full** — All spec variables (version, algorithms, capabilities flags, etc.)
- **Weak** — Only term, role, or minimal state (for async threads)
- **Specialized** — Subset specific to the action

Current implementation uses **Full** capture at all points. To downgrade to **Weak** (if needed):

1. **Edit `build_state_json()`** to omit certain fields
2. **Document in this file** which fields are omitted and why
3. **Update Trace.tla** validator to match (e.g., use `ValidatePostStateWeak`)

Example:
```c
char *build_state_json(void) {
    char *buf = malloc(1024);
    snprintf(buf, 1024,
             "{\"requester_state\":\"%s\",\"responder_state\":\"%s\"}",
             capture_requester_state ? capture_requester_state : "unknown",
             capture_responder_state ? capture_responder_state : "unknown");
    return buf;
}
```

## How to Rebuild After Changes

1. **Edit** the source files (harness/src/*.c or library/*.c)
2. **Regenerate patches** (if using git):
   ```bash
   cd artifact/libspdm
   git diff > ../../harness/patches/instrument.patch
   ```
3. **Run the harness**:
   ```bash
   cd harness && bash run.sh
   ```

## Trace File Format

Every trace file is NDJSON (one JSON object per line):

```json
{"tag":"trace","ts":1234567890123456789,"event":{"name":"requester_init_version","nid":"requester","state":{"requester_state":"requester_version_sent",...}}}
{"tag":"trace","ts":1234567890123456890,"event":{"name":"requester_receives_version","nid":"requester","state":{...},"msg":{"version":16}}}
```

Fields:
- `tag` — Always `"trace"` for TLC filtering
- `ts` — Unix nanoseconds (from `clock_gettime`)
- `event.name` — Event name from Trace.tla
- `event.nid` — Node ID: "requester" or "responder"
- `event.state` — State snapshot JSON
- `event.msg` — Optional message-specific fields

## Common Issues and Fixes

### Issue: "tag" field missing from trace
**Fix**: All events MUST include `"tag":"trace"`. Check `tla_trace.c` line that emits the tag.

### Issue: Timestamps are sequential integers
**Fix**: Timestamps must be real (from `clock_gettime`). Check that events are emitted at actual code points, not synthetic.

### Issue: Event name mismatch with Trace.tla
**Fix**: Event names must match exactly (case-sensitive). Compare `event.name` in trace with `IsEvent(...)` predicates in Trace.tla.

### Issue: State field missing or null
**Fix**: Verify state capture call before emit. Example: if `negotiated_version` is missing, ensure `state_capture_negotiated_version()` was called.

## Testing Instrumentation

After rebuilding:

1. **Check trace generation**:
   ```bash
   ls -lh traces/*.ndjson
   ```

2. **Spot-check trace content**:
   ```bash
   head -5 traces/scenario_1_normal.ndjson | jq .
   ```

3. **Validate event types**:
   ```bash
   cat traces/scenario_1_normal.ndjson | jq -r '.event.name' | sort | uniq
   ```

4. **Run trace validation** (Phase 3):
   ```bash
   cd spec && tlc -modelcheck Trace
   ```

---

For more details on trace validation, see `/path/to/spec/Trace.tla`.
