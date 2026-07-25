# Instrumentation Guide for Phase 3 Adjustments

This document explains how to adjust or extend the SPDM mutual authentication protocol instrumentation for trace validation.

## Overview

The harness emits NDJSON trace events for the following spec actions:
1. `responder_get_encap_request_challenge` — Responder sends encapsulated challenge
2. `requester_get_encap_response_challenge_auth` — Requester generates response
3. `process_encap_response_challenge_auth` — Responder verifies response
4. `transition_to_authenticated` — Both nodes transition to authenticated state

All events follow the NDJSON format with mandatory `"tag": "trace"` field.

---

## Trace Module Files

**Location**: `harness/src/`

- **libspdm_tla_trace.h** — Trace module header with emit function signatures
- **libspdm_tla_trace.c** — Implementation: thread-safe file output via pthread_mutex
- **test_encap_mutual_auth.c** — Test harness that exercises protocol and emits traces

### Key Functions

```c
int libspdm_tla_trace_init(const char *trace_file);
void libspdm_tla_trace_shutdown(void);
int libspdm_tla_trace_emit(
    const char *event_name,
    const char *node,
    const char *state_json,
    const char *msg_json
);
```

---

## Adding a New Instrumentation Point

To add a trace event at a new code location:

1. **Locate the source file and line** where you want to emit the trace.
   - Example: `artifact/libspdm/library/spdm_responder_lib/libspdm_rsp_encap_challenge.c:62`

2. **Capture the state** at that point:
   - Collect all variables that should be logged (protocol version, state, buffer sizes, etc.)
   - Format them as a JSON string (without outer braces):
     ```c
     char state_json[512];
     snprintf(state_json, sizeof(state_json),
              "\"protocol_version\": %u, \"responder_state\": \"%s\"",
              spdm_context->connection_info.version,
              state_to_string(spdm_context->connection_info.connection_state));
     ```

3. **Call the emit function**:
   ```c
   #include "harness/src/libspdm_tla_trace.h"

   libspdm_tla_trace_emit(
       "event_name",
       "node_identifier",
       state_json,
       NULL  /* or message_json if needed */
   );
   ```

4. **Update the test scenario** to exercise this code path (in `test_encap_mutual_auth.c`)

5. **Rebuild and re-run**: `bash harness/run.sh`

---

## State Field Mapping

Each trace event captures implementation state and maps it to TLA+ spec variables:

| Implementation | Trace Field | TLA+ Variable | Notes |
|---|---|---|---|
| `spdm_context->connection_info.version` | `protocol_version` | `protocol_version` | 11, 12, or 13 |
| `spdm_context->connection_info.connection_state` | `responder_state` / `requester_state` | `responder_state` / `requester_state` | State enum converted to string |
| Signature verification result | `signature_verified` | `signature_verified` | true/false |
| Response buffer size parameter | `response_buffer_size` | `response_buffer_size` | Total allocated size |
| Opaque data size calculation | `opaque_data_size` | `opaque_data_size` | Includes underflow detection |
| Buffer reset return value | `buffer_reset_status` | `buffer_reset_status` | "success", "failure", "pending" |

---

## Message Field Mapping

Some events capture message-specific fields:

| Event | Field | Source | Purpose |
|---|---|---|---|
| `responder_get_encap_request_challenge` | `version` | Request header | Protocol version negotiation |
| `requester_get_encap_response_challenge_auth` | `opaque_data_size` | Calculation at line 169-173 | Buffer bounds checking (Family 3) |
| `process_encap_response_challenge_auth` | `opaque_length` | Parsed from response | Opaque data validation |

---

## Common Instrumentation Patterns

### Pattern 1: Action Entry Point
Capture state at the beginning of a function:
```c
libspdm_tla_trace_emit("action_name", "node", state_json, NULL);
```

### Pattern 2: Action Exit Point (Success)
Capture state after successful completion:
```c
if (result == SUCCESS) {
    libspdm_tla_trace_emit("action_name", "node", state_json, NULL);
}
```

### Pattern 3: Critical Calculation (e.g., Buffer Underflow)
Capture result immediately after calculation:
```c
opaque_data_size = response_size - overhead;
char size_str[64];
snprintf(size_str, sizeof(size_str), "\"opaque_data_size\": %lu", opaque_data_size);
libspdm_tla_trace_emit("action_name", "node", state_json, size_str);
```

### Pattern 4: Conditional State Transition
Capture state before and after:
```c
libspdm_tla_trace_emit("transition_begin", "node", state_before, NULL);
libspdm_set_connection_state(context, NEW_STATE);
libspdm_tla_trace_emit("transition_end", "node", state_after, NULL);
```

---

## Rebuilding After Changes

After modifying source code or the trace module:

```bash
cd /path/to/libspdm-mut-auth-encap
bash harness/run.sh
```

This will:
1. Apply patches (`apply.sh`)
2. Rebuild the trace module and test harness
3. Run test scenarios
4. Generate updated traces in `traces/`

---

## Debugging Trace Issues

### Problem: Event not appearing in trace

**Possible causes:**
- Event name in `libspdm_tla_trace_emit()` doesn't match `Trace.tla` spec
- Node name is not "requester" or "responder"
- Trace file path is incorrect
- Code path is not exercised by test scenario

**Solution:**
1. Check that event name matches exactly (case-sensitive)
2. Verify node names are "requester" or "responder" 
3. Add a new test scenario that explicitly triggers the code path
4. Verify trace file is being written by checking file size

### Problem: Trace validation fails

**Possible causes:**
- State field values don't match Trace.tla constraints
- Message field is missing or malformed
- State transitions violate invariants (e.g., signature verification without transcript)

**Solution:**
1. Check `Trace.tla` for field name and type requirements
2. Verify JSON formatting of state/message fields
3. Ensure state transitions are in the correct order
4. Check spec invariants (Section 7 of instrumentation-spec.md)

### Problem: Timestamp issues

**Possible causes:**
- Timestamps are synthetic (sequential: 1000, 1001, 1002)
- Time going backwards between events

**Solution:**
- Timestamps are generated via `clock_gettime()` in `libspdm_tla_trace.c`
- They should be real ISO 8601 timestamps
- If timestamps are wrong, verify system clock is set correctly

---

## Testing Instrumentation

To verify that instrumentation is working correctly:

1. **Generate traces**: `bash harness/run.sh`
2. **Check trace format**: `head -5 traces/test_scenario_basic.ndjson`
3. **Verify event count**: `grep -c '"event":' traces/test_scenario_basic.ndjson`
4. **Check for required events**: Use the event coverage check in `run.sh`

---

## Extension Points for Phase 3

When trace validation reveals issues, common adjustments include:

- **Adding a field**: Add to state JSON in emit call + add check in Trace.tla
- **Renaming an event**: Update both harness emit call and Trace.tla action name
- **Moving capture point**: Update source file line number in instrumentation comment
- **Adding version-dependent logic**: Check `protocol_version` before capturing field

All changes should preserve the NDJSON format and update both the harness and spec in lockstep.

---
