# Instrumentation Spec: libspdm PSK Exchange

Action-to-code mapping for harness generation.
Each spec action requires exactly one trace event type.

---

## Section 1: Trace Event Schema

### Event envelope (every event)

```json
{
  "event":           "<action name>",
  "role":            "requester" | "responder",
  "session_id":      <uint32>,
  "session_state":   "NOT_STARTED" | "HANDSHAKING" | "ESTABLISHED"
}
```

### State fields (captured at every event)

| JSON field            | Implementation source                                    | TLA+ variable               |
|-----------------------|----------------------------------------------------------|-----------------------------|
| `session_state`       | `spdm_context->session_info[i].session_state`            | `req_state.session_state` / `rsp_state.session_state` |
| `session_version`     | `session_info->secured_message_context->secured_message_version` | `req_state.session_version` / `rsp_state.session_version` |
| `hmac_verified`       | flag set after `libspdm_verify_psk_exchange_rsp_hmac()`  | `req_state.hmac_verified`   |
| `has_opaque`          | `spdm_request->opaque_length != 0`                       | `req_has_opaque` / `rsp_has_opaque` |
| `negotiated_version`  | `session_info->secured_message_context->secured_message_version` immediately after version extraction | `rsp_negotiated_version` / `req_negotiated_version` |

### Version constant mapping (C → TLA+)

| C value                              | TLA+ constant |
|--------------------------------------|---------------|
| `0` (uninitialized default)          | `V_NONE`      |
| `SPDM_MESSAGE_VERSION_11` or valid   | `V_VALID`     |
| any other non-zero version           | `V_ALT`       |

---

## Section 2: Action-to-Code Mapping

### 1. `SendPskExchange`

- **Spec action**: `SendPskExchange(with_opaque)`
- **Code location**: `library/spdm_requester_lib/libspdm_req_psk_exchange.c`
  - Trigger: after `libspdm_send_spdm_request()` returns `LIBSPDM_STATUS_SUCCESS`
  - Approx. line: end of send block in `libspdm_try_send_receive_psk_exchange()`
- **Trigger point**: after message is sent
- **Trace event name**: `"SendPskExchange"`
- **Fields to capture**:
  - `role`: `"requester"`
  - `session_id`: `spdm_request->req_session_id`
  - `has_opaque`: `spdm_request->opaque_length != 0` → bool
  - `session_state`: requester session state
  - `session_version`: `V_NONE` (not yet set at send time)
  - `hmac_verified`: `false`
- **Notes**: `has_opaque` is the key field for Family 1 detection. Must be captured from the outgoing request buffer before it is freed.

---

### 2. `GetResponsePskExchange`

- **Spec action**: `GetResponsePskExchange`
- **Code location**: `library/spdm_responder_lib/libspdm_rsp_psk_exchange_rsp.c`
  - Trigger: after `libspdm_assign_session_id()` returns (line ~371), i.e., after session is allocated with `secured_message_version`
- **Trigger point**: after line 371, before sending response
- **Trace event name**: `"GetResponsePskExchange"`
- **Fields to capture**:
  - `role`: `"responder"`
  - `session_id`: newly assigned session ID
  - `session_state`: `HANDSHAKING`
  - `session_version`: `session_info->secured_message_context->secured_message_version` (call-2 value, line ~317)
  - `has_opaque`: `spdm_request->opaque_length != 0` → bool
  - `negotiated_version`: same as `session_version` (captured after call 2 but before call 3)
- **Notes**:
  - Capture `negotiated_version` **after** call 2 (line 317) and **before** call 3 (line 432) to distinguish the two.
  - If possible, add a second capture point at line 432 (after call 3) with `event = "FinalOpaqueWrite"` and field `final_opaque_version`. This enables Family 2 trace validation.
  - `libspdm_rsp_psk_exchange_rsp.c:272` — default `secured_message_version = 0` is observable when `has_opaque = false`.

---

### 3. `FinalOpaqueWrite` (optional, Family 2)

- **Spec action**: n/a (sub-step within `GetResponsePskExchange`)
- **Code location**: `library/spdm_responder_lib/libspdm_rsp_psk_exchange_rsp.c`
  - Trigger: immediately after third callback invocation (line ~432)
- **Trigger point**: after call 3 writes to `ptr`
- **Trace event name**: `"FinalOpaqueWrite"`
- **Fields to capture**:
  - `role`: `"responder"`
  - `final_opaque_version`: version embedded in actual response opaque data
- **Notes**: This event enables comparing call-2 version (session_version) vs call-3 version (final_opaque_version). A divergence between these fields is the Family 2 violation trigger. This event is consumed by a silent action in `Trace.tla` (no corresponding wrapper — see Section 3 note).

---

### 4. `RecvPskExchangeRsp`

- **Spec action**: `RecvPskExchangeRsp`
- **Code location**: `library/spdm_requester_lib/libspdm_req_psk_exchange.c`
  - Trigger: after HMAC verification succeeds and `secured_message_version` is extracted from response
- **Trigger point**: after `libspdm_verify_psk_exchange_rsp_hmac()` succeeds, before session state update
- **Trace event name**: `"RecvPskExchangeRsp"`
- **Fields to capture**:
  - `role`: `"requester"`
  - `session_id`: from `spdm_response->rsp_session_id`
  - `session_state`: post-action state (`HANDSHAKING` or `ESTABLISHED`)
  - `session_version`: `session_info->secured_message_context->secured_message_version` (extracted from call-3 opaque in response)
  - `negotiated_version`: same as `session_version` (requester's view of version)
  - `hmac_verified`: `true`
- **Notes**: `session_version` here is the call-3 value embedded in the PSK_EXCHANGE_RSP. If this differs from the responder's call-2 value, `VersionAgreement` will be violated.

---

### 5. `SendPskFinish`

- **Spec action**: `SendPskFinish`
- **Code location**: `library/spdm_requester_lib/libspdm_req_psk_finish.c`
  - Trigger: after `libspdm_send_spdm_request()` in `libspdm_try_send_receive_psk_finish()`
- **Trigger point**: after send
- **Trace event name**: `"SendPskFinish"`
- **Fields to capture**:
  - `role`: `"requester"`
  - `session_id`
  - `session_state`: `HANDSHAKING`
  - `session_version`: current (unchanged)
  - `hmac_verified`: `true`

---

### 6. `GetResponsePskFinish`

- **Spec action**: `GetResponsePskFinish`
- **Code location**: `library/spdm_responder_lib/libspdm_rsp_psk_finish_rsp.c`
  - Trigger: after HMAC verify and before sending PSK_FINISH_RSP, inside `libspdm_get_response_psk_finish()`
  - Dispatch-layer transition: `libspdm_rsp_receive_send.c:764-827`
- **Trigger point**: after session state set to `SESSION_ESTABLISHED` in dispatch layer
- **Trace event name**: `"GetResponsePskFinish"`
- **Fields to capture**:
  - `role`: `"responder"`
  - `session_id`
  - `session_state`: `ESTABLISHED`
  - `session_version`: unchanged from `GetResponsePskExchange` capture

---

### 7. `RecvPskFinishRsp`

- **Spec action**: `RecvPskFinishRsp`
- **Code location**: `library/spdm_requester_lib/libspdm_req_psk_finish.c`
  - Trigger: after receiving PSK_FINISH_RSP and session transitioned to ESTABLISHED
- **Trigger point**: after session state set to `SESSION_ESTABLISHED`
- **Trace event name**: `"RecvPskFinishRsp"`
- **Fields to capture**:
  - `role`: `"requester"`
  - `session_id`
  - `session_state`: `ESTABLISHED`
  - `session_version`: unchanged
  - `hmac_verified`: `true`

---

## Section 3: Special Considerations

### 3.1 Opaque callback triple-call (Family 2)

The `GetResponsePskExchange` instrumentation point is at line ~371 (after call 2, before call 3). The `FinalOpaqueWrite` instrumentation point is at line ~432 (after call 3). These two events together allow the harness to observe a version divergence.

In `Trace.tla`, `FinalOpaqueWrite` is consumed by a **silent action** (not a wrapper) because it does not advance the spec state machine — it only updates `opaque_call_results[OPAQUE_CALL_FINAL]`. A silent action fires it while `l` is positioned on this event, validates `opaque_call_results[OPAQUE_CALL_FINAL] = logline.final_opaque_version`, then advances `l`.

### 3.2 Session state source

The responder's session state transition to `ESTABLISHED` happens in the **dispatch layer** (`libspdm_rsp_receive_send.c:764-827`), not inside `libspdm_get_response_psk_finish()` itself. The `GetResponsePskFinish` trace event must be emitted from the dispatch layer after the state transition, not from inside the response builder.

### 3.3 `secured_message_version` accessor

The field is nested at:
```c
spdm_context->session_info[session_index]
    .secured_message_context->secured_message_version
```
Access via `libspdm_secured_message_context_data.c:30-43` (`libspdm_secured_message_set_session_state`). Note that `libspdm_secured_message_set_session_state(ESTABLISHED)` **clears handshake keys** (`libspdm_secmes_context_data.c:30-43`) — capture `secured_message_version` **before** this call to avoid a use-after-clear.

### 3.4 Version constant normalization

libspdm uses integer version codes. The harness should map these to `V_NONE`, `V_VALID`, `V_ALT` as follows:
- `0` → `"V_NONE"`
- The version matching the negotiated DSP0277 version in the opaque data → `"V_VALID"`
- Any other non-zero version → `"V_ALT"`

This mapping is applied in the harness before writing the NDJSON trace. Do not emit raw integer version codes.

### 3.5 Single-session scope

libspdm supports multiple concurrent sessions. The trace harness should only instrument the single PSK session under test (filter by `req_session_id` or array index). Multi-session traces are outside this spec's scope.
