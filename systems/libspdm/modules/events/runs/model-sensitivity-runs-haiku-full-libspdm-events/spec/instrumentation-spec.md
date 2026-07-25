# Instrumentation Specification for libspdm-events

This document maps TLA+ spec actions to source code locations and specifies which state fields must be captured in traces for validation.

## Section 1: Trace Event Schema

### Common Event Envelope

Every trace event is a JSON object with the following structure:

```json
{
  "event": "EVENT_NAME",
  "timestamp": <uint64>,
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

### State Fields (Captured at Every Event)

| Spec Variable | Implementation Field | Type | Notes |
|---|---|---|---|
| `session_state[sid]` | `session->state` or equiv | enum | Maps to: LIBSPDM_SESSION_STATE_ESTABLISHED (1), LIBSPDM_SESSION_STATE_NEGOTIATED (0), custom CLOSED (2) |
| `events_sequential` | Derived from event loop structure | bool | True if event IDs are sequential, false otherwise |
| `msg_size_accum` | `calculated_request_size` | uint32 | Accumulated size during event parsing loop |
| `event_validated[i]` | Per-event validation state | bool | True if event[i] passed DMTF type validation |

### Message Fields (Event-Specific)

| Event Type | Field | Source Code | Type |
|---|---|---|---|
| SUBSCRIBE_EVENT_TYPES | `event_types` | Request body | set of uint16 |
| SEND_EVENT_ACK | `event_list` | Response body | array of event records |
| SEND_EVENT_ACK | `is_sequential` | Computed from event IDs | bool |

---

## Section 2: Action-to-Code Mapping

### 1. InitSession

**Spec Action**: `InitSession(sid)`

**Code Location**: `libspdm_secured_message_get_session_state()` → session state change

**Implementation**: Session establishment typically happens in `libspdm_handle_request_and_response()` or similar orchestration. Insert hook at:
- File: `library/spdm_cmnlib_lib/libspdm_support.c` or equivalent
- Line: ~400-500 (session init routine, exact line varies)
- Trigger: After session state transitions to LIBSPDM_SESSION_STATE_ESTABLISHED
- Event Name: `INIT_SESSION`
- Fields to Capture:
  - `sid` (session ID)
  - `session_state[sid]` (should be "ESTABLISHED")
- Notes: May be implicit (session enters ESTABLISHED state during handshake). If no explicit init point, instrument the first SUBSCRIBE or SEND_EVENT after state becomes ESTABLISHED.

### 2. CloseSession

**Spec Action**: `CloseSession(sid)`

**Code Location**: Session cleanup / error handling

**Implementation**: Insert hook when session state transitions to closed:
- File: `library/spdm_cmnlib_lib/libspdm_support.c` or error path
- Line: ~TBD (session close routine)
- Trigger: Session state set to closed/invalid
- Event Name: `CLOSE_SESSION`
- Fields to Capture:
  - `sid`
  - `session_state[sid]` (should be "CLOSED")
- Notes: Not required if sessions don't close during test scenarios. Mark as optional.

### 3. ReqSubscribeEventTypes

**Spec Action**: `ReqSubscribeEventTypes(sid, types)`

**Code Location**: `libspdm_req_subscribe_event_types()` or similar

**Implementation**: Requester prepares and sends subscription request
- File: `library/spdm_requester_lib/libspdm_req_subscribe_event_types.c` (or nearest equivalent)
- Line: ~40-60 (request preparation)
- Trigger: Before request is sent to responder
- Event Name: `SUBSCRIBE_EVENT_TYPES`
- Fields to Capture:
  - `sid`
  - `event_types[]` (bitmap or array of requested event types)
  - `session_state[sid]` (should be "ESTABLISHED")
- Notes: Capture the exact subscription types being requested; these map to the spec's `types` parameter.

### 4. RespSubscribeEventTypesAck

**Spec Action**: `RespSubscribeEventTypesAck(sid)`

**Code Location**: `libspdm_get_response_subscribe_event_types_ack()`

**Implementation**: Responder processes subscription request and calls integrator callback
- File: `library/spdm_responder_lib/libspdm_rsp_subscribe_event_types_ack.c`
- Lines: 71-98 (state check), 131-137 (callback invocation)
- Trigger: Before callback returns (lines 131-137)
- Event Name: `SUBSCRIBE_EVENT_TYPES_ACK`
- Fields to Capture:
  - `sid`
  - `session_state[sid]` (should still be "ESTABLISHED" at lines 93-98 check)
  - `integrator_subscribed_types[sid]` (the state set by integrator callback)
- Notes: This is the key family 3 and family 5 instrumentation point. Capture state at TWO points:
  1. After the session state check (lines 93-98) → "state_at_check"
  2. After callback returns (lines 131-137) → "state_after_callback"
  Compare to detect race conditions.

### 5. RespSendEventAckSeq

**Spec Action**: `RespSendEventAckSeq(sid, event_list)`

**Code Location**: `libspdm_get_response_event_ack()` sequential path

**Implementation**: Responder sends events with sequential IDs
- File: `library/spdm_responder_lib/libspdm_rsp_event_ack.c`
- Lines: 222-227 (sequential processing loop)
- Trigger: After event list validation, before/after events are sent
- Event Name: `SEND_EVENT_ACK`
- Fields to Capture:
  - `sid`
  - `event_list[]` (all event records with: instance_id, detail_len, registry_id, data)
  - `is_sequential = true`
  - `session_state[sid]` (should be "ESTABLISHED" at line 93 check)
  - `msg_size_accum` (accumulated size from lines 188-190)
  - `event_validated[]` (validation state for each DMTF event)
- Notes: 
  - Sequential path identified by: event IDs are consecutive (id[i+1] = id[i] + 1)
  - Capture size accumulation BEFORE overflow check at line 194
  - Capture validation state for each DMTF event (line 175-180 calls)

### 6. RespSendEventAckNonSeq

**Spec Action**: `RespSendEventAckNonSeq(sid, event_list)`

**Code Location**: `libspdm_get_response_event_ack()` non-sequential path

**Implementation**: Responder sends events with non-sequential IDs
- File: `library/spdm_responder_lib/libspdm_rsp_event_ack.c`
- Lines: 228-244 (non-sequential processing loop with `libspdm_find_event_instance_id` calls)
- Trigger: After event list validation, before/after events are sent
- Event Name: `SEND_EVENT_ACK`
- Fields to Capture:
  - `sid`
  - `event_list[]` (all event records)
  - `is_sequential = false`
  - `session_state[sid]` (should be "ESTABLISHED" at line 93 check)
  - `msg_size_accum` (accumulated size from lines 188-190)
  - `event_validated[]`
  - `lookup_iterations[]` (optional: count of searches per event in lines 237-240)
- Notes:
  - Non-sequential path identified by: event IDs are NOT consecutive
  - Each event is searched using `libspdm_find_event_instance_id` (line 237) — O(n) per event = O(n²) total
  - Capture event_id_map formation to verify search succeeded
  - Family 1 key instrumentation point: both paths must be captured to find path-specific bugs

### 7. ReqHandleEventAck

**Spec Action**: `ReqHandleEventAck(sid)`

**Code Location**: `libspdm_get_encap_response_event_ack()`

**Implementation**: Requester receives event ack message
- File: `library/spdm_requester_lib/libspdm_req_get_event.c` or equivalent
- Line: ~TBD (message parsing)
- Trigger: After receiving EVENT_ACK message, before processing events
- Event Name: `HANDLE_EVENT_ACK`
- Fields to Capture:
  - `sid`
  - `session_state[sid]`
  - `event_count` (number of events received)
- Notes: Simpler than responder path. Just confirm message is received and events are in a valid state.

---

## Section 3: Special Considerations

### Granularity and Timing

The spec models event processing as two phases (Family 3):
1. **Validation phase** (atomic): Lines 93-98 check session state
2. **Processing phase** (can be interrupted): Lines 131-137+ invokes callback, lines 218-245 processes events

**Instrumentation must capture both phases**:
- State snapshot at validation (lines 93-98)
- State snapshot after processing (lines 137, 244)
- This enables detecting race conditions where session closes between the two snapshots

### Integer Overflow Tracking (Family 2)

Family 2 requires capturing `msg_size_accum` at two points:
1. **Before accumulation**: Value before the loop at line 119
2. **After accumulation (pre-validation)**: Value after loop at line 190, before check at line 194
3. **After validation**: Value after check at line 194

If overflow occurs invisibly (wraps around), we want to detect it. Instrument all three points:

```c
// Line 119 (before loop)
TRACE_MSG_SIZE_ACCUM_BEFORE(calculated_request_size);

// Line 189-190 (in accumulation loop)
calculated_request_size += event_detail_len;
TRACE_MSG_SIZE_ACCUM_DURING(calculated_request_size, event_detail_len);

// Line 194 (after validation)
if (request_size != calculated_request_accum) ...
TRACE_MSG_SIZE_ACCUM_AFTER(calculated_request_size);
```

### Validation Coupling (Family 4)

DMTF event validation (`libspdm_validate_dmtf_event_type`) is called at line 175-180 **only if** `registry_id == SPDM_REGISTRY_ID_DMTF`. Instrument both:

1. **At validation call (line 177)**:
   ```c
   if (registry_id == SPDM_REGISTRY_ID_DMTF) {
       TRACE_DMTF_VALIDATION_START(i, event_type);
       status = libspdm_validate_dmtf_event_type(...);
       TRACE_DMTF_VALIDATION_END(i, status);
   }
   ```

2. **At events sent (line 245+)**:
   Capture which events were validated (for Family 4 invariant check)

### Subscription State Divergence (Family 5)

The integrator's `libspdm_event_subscribe` callback is called at line 136 but its internal state is opaque to the library. To model state divergence, capture:

1. **Before callback (line 131)**:
   - Library's view: `subscribed_types[sid]` (empty until callback returns)

2. **After callback (line 137)**:
   - Integrator's view: captured from callback result or integrator interface

3. **At event generation**:
   - Which events were generated (should match integrator's subscriptions, not library's)

### Traces Format

Traces are stored as newline-delimited JSON (NDJSON):

```json
{"event":"INIT_SESSION","timestamp":1000,"sid":1,"state":{"session_state":"ESTABLISHED","events_sequential":false,"msg_size_accum":0},"body":{}}
{"event":"SUBSCRIBE_EVENT_TYPES","timestamp":2000,"sid":1,"state":{"session_state":"ESTABLISHED"},"body":{"event_types":[1,2,3]}}
{"event":"SEND_EVENT_ACK","timestamp":3000,"sid":1,"state":{"session_state":"ESTABLISHED","events_sequential":true,"msg_size_accum":450,"event_validated_count":3},"body":{"event_list":[{"instance_id":1,"detail_len":100},{"instance_id":2,"detail_len":150}],"is_sequential":true}}
```

---

## Section 4: Reference Pointers

### Source Files

| File | Purpose | Lines of Interest |
|---|---|---|
| `library/spdm_responder_lib/libspdm_rsp_event_ack.c` | Event ACK responder handler | 71-260 |
| `library/spdm_responder_lib/libspdm_rsp_subscribe_event_types_ack.c` | Subscription handler | 71-152 |
| `library/spdm_requester_lib/libspdm_req_subscribe_event_types.c` | Subscription requester | 1-100 |
| `library/spdm_requester_lib/libspdm_req_get_event.c` | Event requester handler | 1-150 |
| `library/spdm_common_lib/libspdm_com_event.c` | Shared event utilities | 11-73 |
| `include/hal/library/eventlib.h` | Integrator callbacks | 36-79 |

### Callback Interfaces

Integrator callbacks must be instrumented to capture their side effects:

| Callback | Location | Purpose |
|---|---|---|
| `libspdm_event_subscribe` | `eventlib.h:72` | Subscribe/unsubscribe events |
| `libspdm_generate_event_list` | `eventlib.h:78` | Generate pending events |
| `libspdm_event_get_types` | `eventlib.h:79` | Query subscription state |

Instrument callback entry and exit to capture:
- Arguments passed in
- Return value
- Side effects (state changes in integrator-owned structures)

---

## Implementation Notes

1. **Trace collection happens in instrumented tests**, not production code.
2. **Use wrapper macros** to make instrumentation points easy to identify and remove.
3. **Timestamp all events** for ordering verification.
4. **Capture state snapshots** at each action boundary.
5. **Test the traces** by running them through Trace.tla to validate spec-implementation consistency.

