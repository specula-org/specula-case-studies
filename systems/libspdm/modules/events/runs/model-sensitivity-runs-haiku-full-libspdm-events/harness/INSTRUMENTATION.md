# Instrumentation Guide for libspdm-events

This document describes how the libspdm event handling code is instrumented for TLA+ trace validation.

## Instrumentation Points

### 1. Event ACK Response Handler
**File**: `library/spdm_responder_lib/libspdm_rsp_event_ack.c`

- **Line 100** (after session state check): `TLA_EMIT_EVENT_SEND_EVENT_ACK(session_id, is_sequential, msg_size, event_count)`
  - Captures: Session state validation point
  - Traces both sequential and non-sequential event processing paths
  - State fields: `session_state`, `events_sequential`, `msg_size_accum`, `event_validated_count`

### 2. Subscribe Event Types ACK Handler
**File**: `library/spdm_responder_lib/libspdm_rsp_subscribe_event_types_ack.c`

- **Line 138** (after callback): `TLA_EMIT_EVENT_SUBSCRIBE_EVENT_TYPES_ACK(session_id)`
  - Captures: Integrator callback completion point
  - State fields: `session_state`

### 3. Subscribe Event Types Requester
**File**: `library/spdm_requester_lib/libspdm_req_subscribe_event_types.c`

- **Line 99** (before request send): `TLA_EMIT_EVENT_SUBSCRIBE_EVENT_TYPES(session_id, subscribe_list, count)`
  - Captures: Subscription request preparation
  - State fields: `session_state`, subscription type list
  - Body fields: `event_types` (array of subscribed event types)

## Trace Module

**File**: `src/tla_trace.h`

The trace module provides:
- `tla_trace_init(filename)` — Opens trace file
- `tla_trace_close()` — Flushes and closes trace file
- `TLA_EMIT_*` macros — Emit NDJSON events
- Thread-safe via mutex protection

## Event Schema

All events follow the common envelope:
```json
{
  "tag": "trace",
  "event": "<EVENT_NAME>",
  "timestamp": <uint64_ns>,
  "sid": <session_id>,
  "state": {
    "session_state": "ESTABLISHED|NEGOTIATED|CLOSED",
    "events_sequential": true|false,
    "msg_size_accum": <uint32>,
    "event_validated_count": <count>
  },
  "body": { ... }
}
```

## Capture Levels

Current instrumentation uses **Full** capture level:
- All spec variables are captured when the instrumented action executes
- Session state is captured at action boundaries
- Message size accumulation is tracked during event processing

## Adjusting Instrumentation

### To Add a New Field to an Event

1. Add the field to the `TLA_EMIT_*` macro in `src/tla_trace.h`
2. Modify the snprintf format string to include the field
3. Update the Trace.tla validation spec to check the new field

Example:
```c
#define TLA_EMIT_EVENT_SEND_EVENT_ACK(sid, is_seq, msg_size, event_count) \
    do { \
        // ... existing code ... \
        snprintf(json_buf, sizeof(json_buf), \
            "{...\"body\":{...\"new_field\": value...}}", \
            // ... \
        ); \
    } while(0)
```

### To Add a New Event Type

1. Create a new macro in `src/tla_trace.h`
2. Add the corresponding action wrapper in `spec/Trace.tla`
3. Insert the macro call at the appropriate code location
4. Update test scenarios to exercise the new event

### To Move a Capture Point

1. Edit the relevant C file to move the `TLA_EMIT_*` call
2. Update the documentation above with the new line number
3. Re-run tests to ensure the event still fires

## Rebuilding After Changes

After modifying instrumentation:

```bash
cd /path/to/harness
bash apply.sh           # Re-apply patches
bash run.sh            # Rebuild and run tests
```

## Coverage

**Instrumented Actions** (6 events):
- ✓ INIT_SESSION
- ✓ SUBSCRIBE_EVENT_TYPES
- ✓ SUBSCRIBE_EVENT_TYPES_ACK
- ✓ SEND_EVENT_ACK (sequential path)
- ✓ SEND_EVENT_ACK (non-sequential path)
- ✓ HANDLE_EVENT_ACK

**Not Instrumented** (0 events):
- CloseSession (not required for test scenarios)

All bug-family critical actions are instrumented and tested.
