# Instrumentation Spec — libspdm SPDM 1.3 Event Subscription

## Section 1: Trace Event Schema

### Event Envelope

Every trace event is a single NDJSON line:

```json
{
  "event": "<action-name>",
  "params": { ... },
  "post": { ... }
}
```

### State Fields (captured in `post` at every event)

| Field name | C source | TLA+ variable | Type |
|-----------|---------|--------------|------|
| `session_state` | `libspdm_secured_message_get_session_state(session_info->secured_message_context)` | `session_state` | string: `"NOT_STARTED"` \| `"HANDSHAKE"` \| `"ESTABLISHED"` |
| `response_state` | `spdm_context->response_state` | `response_state` | string: `"NORMAL"` \| `"PROCESSING_ENCAP"` |
| `subscription_state` | shadow field set by `libspdm_event_subscribe` HAL wrapper | `subscription_state` | string: `"SUB_NONE"` \| `"SUB_ALL"` \| `"SUB_LIST"` |
| `event_all_policy` | `session_info->session_policy & SPDM_KEY_EXCHANGE_REQUEST_SESSION_POLICY_EVENT_ALL_POLICY` | `event_all_policy` | boolean |
| `subscribe_types_sent` | shadow field (set on first SUBSCRIBE_EVENT_TYPES) | `subscribe_types_sent` | boolean |
| `encap_event_in_flight` | `spdm_context->encap_context.request_op_code_sequence[0] == SPDM_SEND_EVENT && spdm_context->response_state == PROCESSING_ENCAP` | `encap_event_in_flight` | boolean |
| `direct_send_active` | shadow field (set in HandleSendEvent harness) | `direct_send_active` | boolean |
| `last_send_event_response` | shadow field (set from response code in HandleSendEvent) | `last_send_event_response` | string: `"OK"` \| `"VERSION_MISMATCH"` \| `"REQUEST_IN_FLIGHT"` \| `"NONE"` |

**Note on shadow fields**: `subscription_state`, `subscribe_types_sent`, `direct_send_active`, and `last_send_event_response` are not directly readable from a single `libspdm_context_t` field. The harness must maintain these as test-local variables updated at each probe point.

### String Encoding for `session_state`

```c
static const char *session_state_str(libspdm_session_state_t s) {
    switch (s) {
        case LIBSPDM_SESSION_STATE_NOT_STARTED: return "NOT_STARTED";
        case LIBSPDM_SESSION_STATE_HANDSHAKING: return "HANDSHAKE";
        case LIBSPDM_SESSION_STATE_ESTABLISHED: return "ESTABLISHED";
        default: return "UNKNOWN";
    }
}
```

### String Encoding for `response_state`

```c
static const char *response_state_str(libspdm_response_state_t s) {
    switch (s) {
        case LIBSPDM_RESPONSE_STATE_NORMAL:            return "NORMAL";
        case LIBSPDM_RESPONSE_STATE_PROCESSING_ENCAP:  return "PROCESSING_ENCAP";
        default: return "OTHER";
    }
}
```

---

## Section 2: Action-to-Code Mapping

### Action: `HandleKeyExchange`

| Field | Value |
|-------|-------|
| Spec action | `HandleKeyExchange(with_event_all)` |
| Code location | `library/spdm_responder_lib/libspdm_rsp_key_exchange.c:798-817` |
| Trigger point | After `libspdm_set_session_state(... LIBSPDM_SESSION_STATE_HANDSHAKING)` at line 817 |
| Trace event name | `"HandleKeyExchange"` |
| Params captured | `params.with_event_all` = `(spdm_request->session_policy & SPDM_KEY_EXCHANGE_REQUEST_SESSION_POLICY_EVENT_ALL_POLICY) != 0` |
| Post-state fields | `session_state`, `subscription_state`, `event_all_policy`, `subscribe_types_sent` |
| Notes | `subscription_state` reflects what `libspdm_event_subscribe` was called with at line 803. If the call fails, the function returns error before reaching the probe point — no event emitted on error paths. |

---

### Action: `HandleFinish`

| Field | Value |
|-------|-------|
| Spec action | `HandleFinish` |
| Code location | `library/spdm_responder_lib/libspdm_rsp_finish.c` — after `libspdm_set_session_state(... LIBSPDM_SESSION_STATE_ESTABLISHED)` |
| Trigger point | After session state is set to ESTABLISHED |
| Trace event name | `"HandleFinish"` |
| Params captured | (none) |
| Post-state fields | `session_state` |
| Notes | If HANDSHAKE completes via PSK_FINISH instead of FINISH, instrument that function too at the same ESTABLISHED transition. |

---

### Action: `HandleSubscribeEventTypes`

| Field | Value |
|-------|-------|
| Spec action | `HandleSubscribeEventTypes(subscribe_none)` |
| Code location | `library/spdm_responder_lib/libspdm_rsp_subscribe_event_types_ack.c:121-136` |
| Trigger point | After `libspdm_event_subscribe(...)` returns successfully (before constructing response) |
| Trace event name | `"HandleSubscribeEventTypes"` |
| Params captured | `params.subscribe_none` = `(subscribe_event_group_count == 0)` |
| Post-state fields | `subscription_state`, `subscribe_types_sent` |
| Notes | `subscribe_types_sent` shadow field must be set to `true` at this probe point. The `subscription_state` shadow field maps from the `subscribe_type` local variable: `LIBSPDM_EVENT_SUBSCRIBE_NONE→"SUB_NONE"`, `LIBSPDM_EVENT_SUBSCRIBE_LIST→"SUB_LIST"`. |

---

### Action: `HandleSendEventVersionMatch`

| Field | Value |
|-------|-------|
| Spec action | `HandleSendEventVersionMatch` |
| Code location | `library/spdm_responder_lib/libspdm_rsp_event_ack.c:49-54` |
| Trigger point | At line 49 (the `response_state != NORMAL` check), when versions have already matched (lines 37, 44 passed) |
| Trace event name | `"HandleSendEventVersionMatch"` |
| Params captured | (none — version matching is implicit in choosing this action) |
| Post-state fields | `direct_send_active`, `last_send_event_response`, `response_state` |
| Notes | `direct_send_active` shadow = `true`. `last_send_event_response` shadow = `"REQUEST_IN_FLIGHT"` if response_state was PROCESSING_ENCAP at probe point, else `"OK"`. Harness must capture `spdm_context->response_state` BEFORE the check fires to determine which path was taken. |

---

### Action: `HandleSendEventVersionMismatch`

| Field | Value |
|-------|-------|
| Spec action | `HandleSendEventVersionMismatch` |
| Code location | `library/spdm_responder_lib/libspdm_rsp_event_ack.c:44-48` |
| Trigger point | At the return point inside the version mismatch branch (line 45-47), before returning |
| Trace event name | `"HandleSendEventVersionMismatch"` |
| Params captured | (none) |
| Post-state fields | `direct_send_active`, `last_send_event_response`, `response_state` |
| Notes | `direct_send_active` shadow = `true`. `last_send_event_response` shadow = `"VERSION_MISMATCH"`. This is the bug-triggering path: `response_state` may be `PROCESSING_ENCAP` here. Capture `response_state` in post to expose the invariant violation. |

---

### Action: `HandleSendEventComplete`

| Field | Value |
|-------|-------|
| Spec action | `HandleSendEventComplete` |
| Code location | Harness-level: after the caller of `libspdm_get_response_event_ack()` receives the response |
| Trigger point | After response has been sent to requester |
| Trace event name | `"HandleSendEventComplete"` |
| Params captured | (none) |
| Post-state fields | `direct_send_active` |
| Notes | `direct_send_active` shadow = `false`. This is a harness-level event emitted by the test scaffold when the SEND_EVENT exchange is complete. |

---

### Action: `InitEncapSendEvent`

| Field | Value |
|-------|-------|
| Spec action | `InitEncapSendEvent` |
| Code location | `library/spdm_responder_lib/libspdm_rsp_encap_response.c:259` |
| Trigger point | After `context->response_state = LIBSPDM_RESPONSE_STATE_PROCESSING_ENCAP` at line 259 |
| Trace event name | `"InitEncapSendEvent"` |
| Params captured | (none) |
| Post-state fields | `response_state`, `encap_event_in_flight` |
| Notes | `encap_event_in_flight` shadow = `true` at this point. `response_state` from `spdm_context->response_state`. |

---

### Action: `HandleEncapSendEvent`

| Field | Value |
|-------|-------|
| Spec action | `HandleEncapSendEvent` |
| Code location | `library/spdm_responder_lib/libspdm_rsp_encap_send_event.c:51-54` |
| Trigger point | After `libspdm_generate_event_list(...)` returns successfully (event list populated) |
| Trace event name | `"HandleEncapSendEvent"` |
| Params captured | (none) |
| Post-state fields | `response_state`, `encap_event_in_flight`, `subscription_state` |
| Notes | Capturing `subscription_state` here is critical for Family 3 validation — it shows whether the event was generated with an active or expired subscription. If `subscription_state = "SUB_NONE"` here, the invariant violation is observable. |

---

### Action: `ProcessEncapEventAck`

| Field | Value |
|-------|-------|
| Spec action | `ProcessEncapEventAck` |
| Code location | `library/spdm_responder_lib/libspdm_rsp_encap_send_event.c:117` |
| Trigger point | After `*need_continue = false` at line 117, before returning |
| Trace event name | `"ProcessEncapEventAck"` |
| Params captured | (none) |
| Post-state fields | `response_state`, `encap_event_in_flight` |
| Notes | `encap_event_in_flight` shadow = `false`. `response_state` is cleared to NORMAL by the encap dispatch caller after this function returns. If the harness captures `response_state` from the caller context after the clear, emit `"NORMAL"`. If only available inside the function (before caller clears it), emit the pre-clear value and document. |

---

### Action: `TerminateSession`

| Field | Value |
|-------|-------|
| Spec action | `TerminateSession` |
| Code location | `library/spdm_common_lib/libspdm_com_session.c` — `libspdm_free_session_id()` or equivalent |
| Trigger point | After session state is reset to NOT_STARTED |
| Trace event name | `"TerminateSession"` |
| Params captured | (none) |
| Post-state fields | `session_state`, `response_state`, `subscription_state` |
| Notes | All shadow fields must be reset to initial values (`direct_send_active=false`, `encap_event_in_flight=false`, `subscribe_types_sent=false`, `last_send_event_response="NONE"`, `event_all_policy=false`). |

---

## Section 3: Special Considerations

### 3.1 Shadow Fields

The following state is not directly readable from `libspdm_context_t` as a single field and must be maintained by the harness as test-local shadow variables:

| Shadow field | Reset event | Set event |
|-------------|------------|-----------|
| `subscription_state` | `TerminateSession`, `HandleKeyExchange` (if no EVENT_ALL_POLICY) | `HandleKeyExchange` (if EVENT_ALL_POLICY → `SUB_ALL`), `HandleSubscribeEventTypes` |
| `subscribe_types_sent` | `TerminateSession`, `HandleKeyExchange` | `HandleSubscribeEventTypes` |
| `direct_send_active` | `TerminateSession`, `HandleSendEventComplete` | `HandleSendEventVersionMatch`, `HandleSendEventVersionMismatch` |
| `last_send_event_response` | `TerminateSession` | `HandleSendEventVersionMatch`, `HandleSendEventVersionMismatch` |
| `encap_event_in_flight` | `TerminateSession`, `ProcessEncapEventAck` | `InitEncapSendEvent` |

### 3.2 `subscription_state` Access

`libspdm_event_subscribe` is an integrator HAL callback (declared in `include/hal/library/eventlib.h`). The harness must intercept the HAL call to observe what subscription type is being set. Options:

1. **Wrap the HAL callback**: the test registers a wrapper that records the last `subscribe_type` argument before forwarding.
2. **Probe after the call**: in `libspdm_rsp_subscribe_event_types_ack.c:131` (after `libspdm_event_subscribe` returns), capture the local `subscribe_type` variable.

Option 2 is simpler for C probes.

### 3.3 `HandleSendEventVersionMismatch` Trigger Design

To trigger the version-mismatch path for Family 1 bug-hunting scenarios, the test must send a SEND_EVENT request with `header.spdm_version` set to a value different from `libspdm_get_connection_version(spdm_context)`. This requires test-level message crafting or a mock transport layer that injects a malformed version field.

### 3.4 `response_state` Timing for `ProcessEncapEventAck`

`libspdm_process_encap_response_event_ack` sets `need_continue = false` but does NOT clear `response_state`. The caller (`libspdm_get_response_encapsulated_response_ack` or equivalent encap dispatcher) clears `response_state` to NORMAL after `need_continue` returns false. Capture `response_state` in the caller after the clear (post-ACK) for correct post-state matching.

### 3.5 Single-Threaded Serialization

libspdm is single-threaded. The "race" between encap SEND_EVENT (Family 1, 3) and a direct SEND_EVENT or SUBSCRIBE_EVENT_TYPES is a sequential interleaving scenario, not a true concurrent race. The test must craft scenarios where:
1. `InitEncapSendEvent` is called (sets PROCESSING_ENCAP).
2. A direct SEND_EVENT or SUBSCRIBE_EVENT_TYPES arrives BEFORE `ProcessEncapEventAck` completes.
3. These can be triggered by returning from the encap response handler and then injecting a new request.

### 3.6 Trace File Format

Each line is a self-contained JSON object:

```json
{"event":"HandleKeyExchange","params":{"with_event_all":true},"post":{"session_state":"HANDSHAKE","response_state":"NORMAL","subscription_state":"SUB_ALL","event_all_policy":true,"subscribe_types_sent":false,"encap_event_in_flight":false,"direct_send_active":false,"last_send_event_response":"NONE"}}
{"event":"HandleFinish","params":{},"post":{"session_state":"ESTABLISHED","response_state":"NORMAL","subscription_state":"SUB_ALL","event_all_policy":true,"subscribe_types_sent":false,"encap_event_in_flight":false,"direct_send_active":false,"last_send_event_response":"NONE"}}
{"event":"InitEncapSendEvent","params":{},"post":{"session_state":"ESTABLISHED","response_state":"PROCESSING_ENCAP","subscription_state":"SUB_ALL","event_all_policy":true,"subscribe_types_sent":false,"encap_event_in_flight":true,"direct_send_active":false,"last_send_event_response":"NONE"}}
```
