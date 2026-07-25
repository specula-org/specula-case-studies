# Instrumentation Specification

Mapping between TLA+ spec actions and source code locations for trace generation.

## Section 1: Trace Event Schema

### Common Event Envelope

Every trace event is an NDJSON object with this structure:

```json
{
  "event_type": "string",
  "timestamp": 0,
  "node_id": "req" | "rsp",
  "state_snapshot": {
    "pc": "string",
    "session_state": "IDLE" | "HANDSHAKING" | "ESTABLISHED",
    "allocated_ids": [0, ...],
    "version_negotiated": boolean
  },
  "message_fields": {
    "req_session_id": 0,
    "rsp_session_id": 0,
    "opaque_length": 0,
    "context_length": 0,
    ...
  }
}
```

### State Fields Mapping

| TLA+ Variable | Implementation Location | Getter/Field |
|---|---|---|
| `requester_session_state` | libspdm context | `spdm_context->session_state[session_id]` |
| `responder_session_state` | libspdm context | `spdm_context->session_state[session_id]` |
| `requester_allocated_ids` | libspdm context | `spdm_context->psk_session_count`, `spdm_context->session_info[...]` |
| `version_negotiation_state` | session_info struct | `session_info->secured_message_version` |
| `opaque_max_bounds_enforced` | Message field | `spdm_response->opaque_length` |

### Message Fields Mapping

| TLA+ Field | Implementation Source |
|---|---|
| `req_session_id` | `spdm_request->req_session_id` (PSK_EXCHANGE) |
| `rsp_session_id` | `spdm_response->rsp_session_id` (PSK_EXCHANGE_RSP) |
| `opaque_length` | `spdm_request->opaque_length` or `spdm_response->opaque_length` |
| `context_length` | `spdm_request->context_length` or `spdm_response->context_length` |
| `opaque_data` | presence of opaque data in message |
| `context_data` | presence of context data in message |
| `version_negotiated` | result of version selection processing |

---

## Section 2: Action-to-Code Mapping

### Action 1: RequesterSendPskExchange

**Spec action name**: `RequesterSendPskExchange`

**Code location**: `library/spdm_requester_lib/libspdm_req_psk_exchange.c:121-236`
- Line 199: Session ID allocation (`req_session_id = libspdm_allocate_req_session_id(...)`)
- Lines 205-230: Algorithm validation
- Lines 244-271: Request building (opaque_length, context_length setup)
- Line 318-323: Message transmission

**Trigger point**: After `libspdm_acquire_sender_buffer()` completes (line 233)

**Trace event name**: `RequesterSendPskExchange`

**Fields to capture**:
- `state_snapshot`:
  - `pc`: "sent_psk_exchange"
  - `allocated_ids`: Set of allocated session IDs
  - `session_state`: IDLE
- `message_fields`:
  - `req_session_id`: `req_session_id` (allocated value)
  - `opaque_length`: `spdm_request->opaque_length`
  - `context_length`: `spdm_request->context_length`
  - `opaque_data`: TRUE if built/provided
  - `context_data`: TRUE if present

**Non-obvious details**:
- Allocation at line 199 must be captured to track session ID pool
- Algorithm validation (lines 205-230) performs multiple early returns; these are error paths and should be captured as separate trace events if they occur
- Context is generated randomly (line 287) if not provided; this is acceptable randomness for the model

---

### Action 2: ResponderRecvPskExchange

**Spec action name**: `ResponderRecvPskExchange`

**Code location**: `library/spdm_responder_lib/libspdm_rsp_psk_exchange_rsp.c:75-209`
- Lines 233-245: Size validation checks
- Lines 238-241: Opaque/context size consistency check (implicit, not explicit max-bound)
- Line 274: Opaque data parsing begins

**Trigger point**: After message reception (`libspdm_receive_spdm_response()` completes, around line 337-339 in requester code) and before parsing (line 105-245 in responder code)

**Trace event name**: `ResponderRecvPskExchange`

**Fields to capture**:
- `state_snapshot`:
  - `pc`: "recv_psk_exchange"
  - `session_state`: IDLE
  - `opaque_length_checked`: Whether explicit bounds check was performed
  - `context_length_checked`: Whether bounds check was performed
- `message_fields`:
  - `req_session_id`: Extracted from request
  - `opaque_length`: `spdm_request->opaque_length` (from received message)
  - `context_length`: `spdm_request->context_length` (from received message)
  - `psk_hint_length`: `spdm_request->psk_hint_length`

**Non-obvious details**:
- **CRITICAL FOR FAMILY 1**: Capture whether explicit bounds check at lines 238-241 was performed. Note: this check is implicit (size-flow calculation), NOT an explicit `if (opaque_length > SPDM_MAX_OPAQUE_DATA_SIZE) return ERROR`. Instrument AFTER line 241 to record whether bounds were implicitly checked.
- Error responses (lines 234-270) are alternative paths and should be traced separately

---

### Action 3: ResponderSendPskExchangeRsp

**Spec action name**: `ResponderSendPskExchangeRsp`

**Code location**: `library/spdm_responder_lib/libspdm_rsp_psk_exchange_rsp.c:274-350` (opaque handling), response building

**Trigger point**: Before `libspdm_send_spdm_response()` or after response building complete

**Trace event name**: `ResponderSendPskExchangeRsp`

**Fields to capture**:
- `state_snapshot`:
  - `pc`: "sent_psk_exchange_rsp"
  - `session_state`: HANDSHAKING (after sending)
  - `version_negotiated`: Whether version was negotiated
- `message_fields`:
  - `rsp_session_id`: Generated responder session ID
  - `opaque_length`: Length of responder opaque data
  - `context_length`: Length of context in response
  - `version_negotiated`: TRUE if opaque data contains version selection
  - `use_default_opaque`: Whether default version data was used (line 294)

**Non-obvious details**:
- Lines 287-297: Hook invocation `libspdm_psk_exchange_rsp_opaque_data()` determines whether custom or default opaque data is used. Capture `use_default_opaque` flag.
- Opaque data format is version-dependent; capture both the length and whether it contains valid version selection data

---

### Action 4: RequesterRecvPskExchangeRsp

**Spec action name**: `RequesterRecvPskExchangeRsp`

**Code location**: `library/spdm_requester_lib/libspdm_req_psk_exchange.c:327-477`
- Lines 425-428: **Explicit max-bound check** on opaque_length (FAMILY 1 KEY LOCATION)
- Lines 402-407: Version selection data processing
- Lines 430-442: Context length validation based on capability flags
- Lines 471-477: Session assignment (deallocation of allocated ID)

**Trigger point**: After `libspdm_receive_spdm_response()` completes

**Trace event name**: `RequesterRecvPskExchangeRsp`

**Fields to capture**:
- `state_snapshot`:
  - `pc`: "received_psk_exchange_rsp"
  - `session_state`: HANDSHAKING (after assignment)
  - `allocated_ids`: Updated (ID removed from allocated, added to freed)
  - `opaque_length_checked`: Explicit bounds check result (line 425)
  - `version_agreement`: Version from responder opaque data
- `message_fields`:
  - `rsp_session_id`: From response
  - `opaque_length`: From response (value that was checked at line 425)
  - `context_length`: From response
  - `opaque_data_valid`: Whether opaque data was successfully parsed (lines 402-407)

**Non-obvious details**:
- **CRITICAL FOR FAMILY 1**: Line 425 performs explicit bounds check `if (spdm_response->opaque_length > SPDM_MAX_OPAQUE_DATA_SIZE)`. This is the ASYMMETRY vs responder side. Capture the check result and the value being checked.
- Lines 471-477: Session assignment occurs here; capture state before (allocated_ids) and after (allocated_ids freed, session established)
- Early error returns (lines 340-407) should be traced as separate events before final success

---

### Action 5: RequesterSendPskFinish

**Spec action name**: `RequesterSendPskFinish`

**Code location**: `library/spdm_requester_lib/libspdm_req_psk_finish.c:~140-170` (estimated, based on structure)

**Trigger point**: After state validation and before message send

**Trace event name**: `RequesterSendPskFinish`

**Fields to capture**:
- `state_snapshot`:
  - `pc`: "sent_psk_finish"
  - `session_state`: HANDSHAKING
  - `session_id`: Active session ID
- `message_fields`:
  - `session_id`: Session ID in FINISH request
  - `opaque_length`: Length of opaque data in FINISH (may be 0)

**Non-obvious details**:
- Line 163 (estimated): State check `if (session_state != LIBSPDM_SESSION_STATE_HANDSHAKING)` is enforced. Capture that this check passed.

---

### Action 6: ResponderRecvPskFinish

**Spec action name**: `ResponderRecvPskFinish`

**Code location**: `library/spdm_responder_lib/libspdm_rsp_psk_finish_rsp.c:~140-180` (estimated)

**Trigger point**: After message reception and size validation

**Trace event name**: `ResponderRecvPskFinish`

**Fields to capture**:
- `state_snapshot`:
  - `pc`: "recv_psk_finish"
  - `session_state`: HANDSHAKING
- `message_fields`:
  - `session_id`: From request
  - `opaque_length`: From request (may be checked at line 171-182 per brief)

**Non-obvious details**:
- Lines 171-182: Check for opaque_length bounds. Capture whether this check was performed (FAMILY 1).
- State validation at line 160 must pass (`session_state == LIBSPDM_SESSION_STATE_HANDSHAKING`)

---

### Action 7: ResponderSendPskFinishRsp

**Spec action name**: `ResponderSendPskFinishRsp`

**Code location**: `library/spdm_responder_lib/libspdm_rsp_psk_finish_rsp.c:~200+` (response building and send)

**Trigger point**: Before sending response

**Trace event name**: `ResponderSendPskFinishRsp`

**Fields to capture**:
- `state_snapshot`:
  - `pc`: "sent_psk_finish_rsp"
  - `session_state`: ESTABLISHED (after sending)
  - `session_id`: Session ID

---

### Action 8: RequesterRecvPskFinishRsp

**Spec action name**: `RequesterRecvPskFinishRsp`

**Code location**: `library/spdm_requester_lib/libspdm_req_psk_finish.c:~290+` (receive and validation)
- Lines 292-295: **Explicit max-bound check** on opaque_length (FAMILY 1 KEY LOCATION)

**Trigger point**: After reception and validation

**Trace event name**: `RequesterRecvPskFinishRsp`

**Fields to capture**:
- `state_snapshot`:
  - `pc`: "established"
  - `session_state`: ESTABLISHED
  - `opaque_length_checked`: Bounds check result (line 292)
- `message_fields`:
  - `session_id`: From response
  - `opaque_length`: From response (value checked at line 292)

**Non-obvious details**:
- **CRITICAL FOR FAMILY 1**: Line 292-295 performs explicit bounds check. Capture this.

---

## Section 3: Special Considerations

### Session ID Tracking (Family 2)

**Challenge**: Session ID allocation and deallocation are spread across multiple functions with error paths. The leak occurs when `libspdm_free_session_id()` is not called on early returns (lines 213, 218, 224, 228, 235 in libspdm_req_psk_exchange.c).

**Instrumentation strategy**:
1. Instrument line 199 (allocation): Emit event with `allocated_ids` before and after
2. Instrument each early return (lines 213, 218, 224, 228, 235): Emit event with `freed_ids` updated (or NOT updated if buggy path)
3. Instrument line 472-477 (assignment): Emit event with `allocated_ids` after deallocation

**Events to generate**:
- `SessionIdAllocated`: Capture `allocated_ids` after allocation
- `SessionIdFreed`: Capture `freed_ids` after deallocation
- `SessionIdAssigned`: Capture transition from allocated to assigned
- `ErrorWithoutFree`: Capture error return WITHOUT deallocation (traces the bug)
- `ErrorWithFree`: Capture error return WITH deallocation (correct behavior)

### Version Negotiation (Family 3)

**Challenge**: Version negotiation happens via opaque data processing. Responder may skip version data (hook returns false), and requester must handle both default and custom versions.

**Instrumentation strategy**:
1. Instrument line 287 (hook call): Emit event indicating whether hook succeeded
2. Instrument line 402-407 (requester processes version): Emit event with extracted version
3. Track `secured_message_version` variable in both requester and responder state snapshots

**Events to generate**:
- `OpaqueDataHookCalled`: Capture hook result (lines 287-297)
- `VersionSelectionProcessed`: Capture extracted version from opaque data (lines 402-407)

### Opaque Length Checks (Family 1)

**Challenge**: Two explicit checks (requester lines 425, 292) vs implicit checks (responder lines 238-241).

**Instrumentation strategy**:
1. Instrument lines 425, 292: Emit event indicating bounds check result
2. Instrument lines 238-241 (responder): Emit event for implicit size-flow check

**Markers to instrument**:
- Requester side: Explicit `if (opaque_length > SPDM_MAX_OPAQUE_DATA_SIZE) return ERROR` at lines 425, 292
- Responder side: Size flow check at lines 238-241 (implicit, check `request_size < ...`)

### Concurrent/Async Considerations

**Single-threaded note**: libspdm PSK exchange is single-threaded (requester and responder are separate processes/threads). Traces must show interleaved send/receive pairs.

**Message ordering**: Implement message delivery in order (FIFO); do not reorder messages in traces.

---

## Trace Validation Checklist

Before running trace validation (`Trace.tla`), verify:

1. [x] Every spec action has at least one trace event type
2. [x] Every trace event maps to exactly one spec action
3. [x] State snapshot fields match TLA+ variables (pc, session_state, allocated_ids, version_negotiated)
4. [x] Message fields match TLA+ message structure (req_session_id, rsp_session_id, opaque_length, etc.)
5. [x] Explicit bounds checks are captured (Family 1: lines 425, 292, 238-241)
6. [x] Allocation/deallocation events are paired (Family 2)
7. [x] Version agreement state is captured (Family 3)
8. [x] State transitions respect handshake preconditions (Family 5)
9. [x] Context length is captured (Family 4)
10. [x] Trace events are in causal order (send before receive)

---

## Implementation Guidance

### Instrumentation Framework

Suggested approach:
1. Create a shadow struct `trace_state_t` in spdm_context to mirror TLA+ state
2. Create `emit_trace_event()` function that serializes events to NDJSON
3. Instrument key functions with macro calls:
   ```c
   TRACE_EVENT("RequesterSendPskExchange", [
       .req_session_id = req_session_id,
       .opaque_length = spdm_request->opaque_length,
       ...
   ]);
   ```
4. Route all events to a single file (`../traces/trace.ndjson`)

### Test Scenarios

Recommended scenarios to capture:
1. **Happy path**: Full PSK_EXCHANGE → PSK_FINISH → ESTABLISHED
2. **Algorithm validation error**: Early return at line 213-228
3. **Oversized opaque**: Send opaque_length > MAX and verify bounds checks
4. **Version mismatch**: Responder sends incompatible version selection
5. **Context bounds violation**: Send context_length > MAX and verify requester check

---
