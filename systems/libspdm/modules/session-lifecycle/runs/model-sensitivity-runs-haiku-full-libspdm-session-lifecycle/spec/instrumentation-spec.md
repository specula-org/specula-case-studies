# Instrumentation Spec: libspdm-session-lifecycle

Mapping of TLA+ spec actions to source code locations for trace generation.

## Section 1: Trace Event Schema

### Event Envelope

Every trace event is a JSON object with:

```json
{
  "event": "<event_name>",
  "timestamp": <integer>,
  "session_id": "<session_id>",
  "sender": "<requester|responder>",
  "state": { ... },
  "message": { ... }
}
```

### State Fields

Captured at every event. Maps from implementation to TLA+:

| Implementation | TLA+ Variable | Type | Notes |
|---|---|---|---|
| `session_state[sid]` | `session_state[sid]` | string | idle, established, ending, freed |
| `prev_key_update_operation[sid]` | `prev_key_update_operation[sid]` | string | none, update_key, update_all_keys, verify_new_key |
| `requester_key_created[sid]` | `requester_key_created[sid]` | bool | Key created at requester |
| `responder_key_created[sid]` | `responder_key_created[sid]` | bool | Key created at responder |
| `requester_key_active[sid]` | `requester_key_active[sid]` | bool | Key activated at requester |
| `responder_key_active[sid]` | `responder_key_active[sid]` | bool | Key activated at responder |
| `heartbeat_enabled[sid]` | `heartbeat_enabled[sid]` | bool | Heartbeat configured |

### Message Fields

Captured when messages are sent. Maps from implementation to TLA+:

| Message Type | Implementation | TLA+ Field | Type | Notes |
|---|---|---|---|---|
| heartbeat | libspdm_req_heartbeat.c | type | "heartbeat" | Heartbeat request |
| key_update | libspdm_req_key_update.c | type, operation | "key_update", op | Key update request |
| key_update_verify | libspdm_req_key_update.c | type | "key_update_verify" | Verify request |
| end_session | libspdm_req_end_session.c | type | "end_session" | End session request |
| end_session_ack | libspdm_rsp_end_session_ack.c | type | "end_session_ack" | End session ACK |

---

## Section 2: Action-to-Code Mapping

### 1. InitializeSession

- **Spec action name**: `InitializeSession(sid)`
- **Code location**: `libspdm_com_context_data_session.c:9-39` (session init)
- **Trigger point**: After session initialization, when `session_state = ESTABLISHED`
- **Trace event name**: `initialize_session`
- **Fields captured**:
  - state: `session_state[sid]`, `heartbeat_enabled[sid]`
  - message: none
- **Notes**: Marks the point where requester establishes a session. Responder should mirror this state.

### 2. RespondToSessionInit

- **Spec action name**: `RespondToSessionInit(sid)`
- **Code location**: `libspdm_com_context_data_session.c:9-39` (responder side)
- **Trigger point**: After responder accepts session
- **Trace event name**: `respond_to_session_init`
- **Fields captured**:
  - state: `session_state[sid]`, `heartbeat_enabled[sid]`
  - message: none
- **Notes**: Responder side acknowledgment of session establishment.

### 3. SendHeartbeat

- **Spec action name**: `SendHeartbeat(sid)`
- **Code location**: `libspdm_req_heartbeat.c:63-90` (requester sends heartbeat)
- **Trigger point**: Before message send, after precondition checks (line 63-65)
- **Trace event name**: `send_heartbeat`
- **Fields captured**:
  - state: `session_state[sid]`, `heartbeat_enabled[sid]`
  - message: type="heartbeat", session_id=sid
- **Notes**: Captures heartbeat request. Must verify heartbeat_enabled is TRUE.

### 4. ReceiveHeartbeat

- **Spec action name**: `ReceiveHeartbeat(sid)`
- **Code location**: `libspdm_rsp_heartbeat.c:99-110` (responder handles heartbeat)
- **Trigger point**: After responder processes heartbeat (after line 99-103 checks)
- **Trace event name**: `receive_heartbeat`
- **Fields captured**:
  - state: `session_state[sid]`, `heartbeat_enabled[sid]`
  - message: type="heartbeat" (consumed)
- **Notes**: Responder-side heartbeat handling. Check heartbeat_enabled = TRUE.

### 5. InitiateKeyUpdate

- **Spec action name**: `InitiateKeyUpdate(sid, op)`
- **Code locations**: 
  - `libspdm_req_key_update.c:95-99` (operation type selection)
  - `libspdm_req_key_update.c:111-122` (requester pre-creates responder key)
- **Trigger point**: After requester creates responder key (line 111-122), before sending request
- **Trace event name**: `initiate_key_update`
- **Fields captured**:
  - state: `prev_key_update_operation[sid]`, `responder_key_created[sid]`, `session_state[sid]`
  - message: type="key_update", operation=op, session_id=sid
- **Notes**: Critical point for Family 1 bug. Capture the moment responder key is created **before** ACK received.

### 6. HandleKeyUpdate

- **Spec action name**: `HandleKeyUpdate(sid, op)`
- **Code location**: `libspdm_rsp_key_update_ack.c:108-146` (responder handles key update)
- **Trigger point**: After state machine validation (line 108-116 consttime check), before key creation
- **Trace event name**: `handle_key_update`
- **Fields captured**:
  - state: `prev_key_update_operation[sid]`, `requester_key_created[sid]`, `responder_key_created[sid]`
  - message: type="key_update", operation=op (consumed)
- **Notes**: Family 2 critical point. Captures state machine validation and key creation on responder side.

### 7. SendKeyUpdateVerify

- **Spec action name**: `SendKeyUpdateVerify(sid)`
- **Code location**: `libspdm_req_key_update.c:184-195` (requester sends VERIFY after UPDATE ACK)
- **Trigger point**: After requester receives UPDATE ACK and activates responder key
- **Trace event name**: `send_key_update_verify`
- **Fields captured**:
  - state: `prev_key_update_operation[sid]`, `responder_key_active[sid]`, `session_state[sid]`
  - message: type="key_update_verify", session_id=sid
- **Notes**: Family 1 critical point. Activation happens after ACK received.

### 8. HandleKeyUpdateVerify

- **Spec action name**: `HandleKeyUpdateVerify(sid)`
- **Code location**: `libspdm_rsp_key_update_ack.c:194-199` (responder verifies key update)
- **Trigger point**: After responder checks prev_key_update_operation (line 194-199)
- **Trace event name**: `handle_key_update_verify`
- **Fields captured**:
  - state: `prev_key_update_operation[sid]`, `requester_key_active[sid]`, `session_state[sid]`
  - message: type="key_update_verify" (consumed)
- **Notes**: Completes key update cycle. Activates requester key on responder side.

### 9. InitiateEndSession

- **Spec action name**: `InitiateEndSession(sid)`
- **Code location**: `libspdm_req_end_session.c:70-120` (requester sends END_SESSION)
- **Trigger point**: Before END_SESSION message sent
- **Trace event name**: `initiate_end_session`
- **Fields captured**:
  - state: `session_state[sid]`
  - message: type="end_session", session_id=sid
- **Notes**: Requester initiates session termination.

### 10. RespondToEndSession

- **Spec action name**: `RespondToEndSession(sid)`
- **Code location**: `libspdm_get_response_end_session.c` (responder receives END_SESSION)
- **Trigger point**: After responder receives and processes END_SESSION
- **Trace event name**: `respond_to_end_session`
- **Fields captured**:
  - state: `session_state[sid]`
  - message: type="end_session" (consumed)
- **Notes**: Responder acknowledges end session request.

### 11. SendEndSessionAck

- **Spec action name**: `SendEndSessionAck(sid)`
- **Code location**: `libspdm_rsp_end_session_ack.c:89-107` (responder sends ACK)
- **Trigger point**: Before sending END_SESSION_ACK
- **Trace event name**: `send_end_session_ack`
- **Fields captured**:
  - state: `session_state[sid]`, `session_freed_by_responder[sid]`
  - message: type="end_session_ack", session_id=sid
- **Notes**: Family 4 critical point. Responder frees session here.

### 12. ReceiveEndSessionAck

- **Spec action name**: `ReceiveEndSessionAck(sid)`
- **Code location**: `libspdm_req_end_session.c:136-141` (requester receives ACK, frees session)
- **Trigger point**: After requester receives END_SESSION_ACK and frees session
- **Trace event name**: `receive_end_session_ack`
- **Fields captured**:
  - state: `session_freed_by_requester[sid]`
  - message: type="end_session_ack" (consumed)
- **Notes**: Family 4 critical point. If this ACK is lost, requester frees but responder doesn't.

### 13. FinalizeSessionCleanup

- **Spec action name**: `FinalizeSessionCleanup(sid)`
- **Code location**: `libspdm_com_context_data_session.c` (final cleanup state)
- **Trigger point**: When both sides have freed, transition to FREED state
- **Trace event name**: `finalize_session_cleanup`
- **Fields captured**:
  - state: `session_state[sid]`, `session_freed_by_requester[sid]`, `session_freed_by_responder[sid]`
  - message: none
- **Notes**: Final state after cleanup complete. Not necessarily instrumented; can be inferred from prior events.

---

## Section 3: Special Considerations

### 3.1 State Capture Timing

State is captured **after** the action completes, reflecting the new state post-action. This ensures the trace shows the effect of the action.

### 3.2 Message Capture Timing

Messages are captured when **sent**, before they can be lost or consumed. This allows the trace to show the full message sequence.

### 3.3 Key Update State Machine (Family 2)

The `prev_key_update_operation` field must be captured to validate state machine transitions:
- NONE → UPDATE_KEY or UPDATE_ALL_KEYS (via HandleKeyUpdate)
- UPDATE_KEY or UPDATE_ALL_KEYS → VERIFY_NEW_KEY (via HandleKeyUpdateVerify)
- VERIFY_NEW_KEY → NONE (completion)

### 3.4 Key Activation Order (Family 1)

Capture both `responder_key_created` and `responder_key_active` separately to expose the divergence window:
- `responder_key_created = TRUE` when InitiateKeyUpdate fires (requester side, before ACK)
- `responder_key_active = TRUE` when SendKeyUpdateVerify fires (after ACK received)

On responder side:
- Both created and activated when HandleKeyUpdateVerify fires

### 3.5 Session Cleanup (Family 4)

Track `session_freed_by_requester` and `session_freed_by_responder` separately to detect asymmetric cleanup:
- `session_freed_by_requester = TRUE` when ReceiveEndSessionAck fires
- `session_freed_by_responder = TRUE` when SendEndSessionAck fires

If END_SESSION_ACK is lost, requester frees but responder doesn't — this asymmetry should be visible in traces.

### 3.6 Heartbeat Configuration (Family 5)

`heartbeat_enabled` is set to TRUE during session initialization. If a test intentionally sets it to FALSE, heartbeat operations should fail precondition checks (CanSendHeartbeat).

### 3.7 Session IDs

Use `session_id` consistently across all events to track session state transitions. Session IDs should be reusable after cleanup (FREED state).

### 3.8 Bootstrap State

The initial trace event should be `initialize_session`, which sets `session_state = ESTABLISHED` and `heartbeat_enabled = TRUE`. The base spec assumes this is the first action.

---

## Validation Checklist

Before trace validation:

- [ ] Every spec action has a corresponding trace event name
- [ ] Every trace event is emitted at the correct code location
- [ ] State fields are captured after action completion
- [ ] Message fields include: type, operation (if applicable), session_id
- [ ] Family 1 (divergence): Both `key_created` and `key_active` captured separately
- [ ] Family 2 (state machine): `prev_key_update_operation` transitions captured
- [ ] Family 4 (cleanup): Both `freed_by_requester` and `freed_by_responder` tracked
- [ ] Family 5 (heartbeat): `heartbeat_enabled` and `session_state` always consistent

