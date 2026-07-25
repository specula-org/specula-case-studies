# Instrumentation Spec: libspdm CHALLENGE Auth

Maps each `Trace.tla` action wrapper to its source code location, trigger point, emitted event name, and captured fields.

---

## Section 1: Trace Event Schema

### Event Envelope (every event)

```json
{
  "event": "<event_name>",
  "node":  "requester" | "responder",
  "connection_state": "<state_string>"
}
```

`connection_state` is captured **after** the state transition completes, except where noted. Map implementation enum values to strings:

| Enum value | String |
|---|---|
| `LIBSPDM_CONNECTION_STATE_NOT_STARTED` | `"NOT_STARTED"` |
| `LIBSPDM_CONNECTION_STATE_AFTER_VERSION` | `"AFTER_VERSION"` |
| `LIBSPDM_CONNECTION_STATE_AFTER_CAPABILITIES` | `"AFTER_CAPABILITIES"` |
| `LIBSPDM_CONNECTION_STATE_NEGOTIATED` | `"NEGOTIATED"` |
| `LIBSPDM_CONNECTION_STATE_AFTER_DIGESTS` | `"AFTER_DIGESTS"` |
| `LIBSPDM_CONNECTION_STATE_AFTER_CERTIFICATE` | `"AFTER_CERTIFICATE"` |
| `LIBSPDM_CONNECTION_STATE_AUTHENTICATED` | `"AUTHENTICATED"` |

Read `connection_state` from `spdm_context->connection_info.connection_state`.

### Per-slot cert state fields (cert events only)

| Field | Source | TLA+ variable |
|---|---|---|
| `slot` | slot_id argument | `challenge_slot`, `auth_slot` |
| `cert_fetched` | `spdm_context->connection_info.peer_used_cert_chain[slot_id].buffer_size > 0` | `cert_fetched[slot]` |
| `cert_hash_valid` | `spdm_context->connection_info.peer_used_cert_chain_buffer_hash_size > 0` | `cert_hash_valid[slot]` |

---

## Section 2: Action-to-Code Mapping

### `TraceNegotiate`

| Field | Value |
|---|---|
| **Spec action** | `Negotiate` |
| **Code location** | `library/spdm_requester_lib/libspdm_req_negotiate_algorithms.c` — after `NEGOTIATED` state is set |
| **Trigger point** | After `libspdm_set_connection_state(LIBSPDM_CONNECTION_STATE_NEGOTIATED)` on Requester |
| **Event name** | `"negotiate"` |
| **Node** | `"requester"` |
| **Extra fields** | none |
| **Notes** | One event per connection, emitted by Requester only. Responder state is modeled as advancing synchronously in the spec; only instrument one side to avoid duplicate Negotiate triggers. |

---

### `TraceReqGetDigests`

| Field | Value |
|---|---|
| **Spec action** | `ReqGetDigests` |
| **Code location** | `library/spdm_requester_lib/libspdm_req_get_digests.c` — after sending GET_DIGESTS request |
| **Trigger point** | After `spdm_send_spdm_request()` returns SUCCESS |
| **Event name** | `"req_get_digests"` |
| **Node** | `"requester"` |
| **Extra fields** | none |

---

### `TraceRspGetDigests`

| Field | Value |
|---|---|
| **Spec action** | `RspGetDigests` |
| **Code location** | `library/spdm_responder_lib/libspdm_rsp_digests.c` — line 180 (after response appended to message_b) |
| **Trigger point** | After `libspdm_append_message_b()` for the response succeeds (line 180) |
| **Event name** | `"rsp_get_digests"` |
| **Node** | `"responder"` |
| **Extra fields** | none |
| **Notes** | If response append fails, emit `"rsp_digest_append_fail"` instead (see below). Do not emit both for the same exchange. |

---

### `TraceReqDigestsRecv`

| Field | Value |
|---|---|
| **Spec action** | `ReqDigestsRecv` |
| **Code location** | `library/spdm_requester_lib/libspdm_req_get_digests.c` — after response received and state advanced |
| **Trigger point** | After `libspdm_set_connection_state(LIBSPDM_CONNECTION_STATE_AFTER_DIGESTS)` |
| **Event name** | `"req_digests_recv"` |
| **Node** | `"requester"` |
| **Extra fields** | none |

---

### `TraceReqGetCertificate`

| Field | Value |
|---|---|
| **Spec action** | `ReqGetCertificate` |
| **Code location** | `library/spdm_requester_lib/libspdm_req_get_certificate.c` — after request sent |
| **Trigger point** | After `spdm_send_spdm_request()` for GET_CERTIFICATE returns SUCCESS |
| **Event name** | `"req_get_certificate"` |
| **Node** | `"requester"` |
| **Extra fields** | `"slot": <slot_id>` |

---

### `TraceRspGetCertificate` / `TraceRspGetCertificateInSession`

| Field | Value |
|---|---|
| **Spec actions** | `RspGetCertificate` (normal) / `RspGetCertificateInSession` (session path) |
| **Code location** | `library/spdm_responder_lib/libspdm_rsp_certificate.c:243-246` — after `connection_state` set to AFTER_CERTIFICATE |
| **Trigger point** | After `libspdm_set_connection_state(LIBSPDM_CONNECTION_STATE_AFTER_CERTIFICATE)` at line 243 |
| **Event name** | `"rsp_get_certificate"` |
| **Node** | `"responder"` |
| **Extra fields** | `"slot": <slot_id>`, `"in_session": <bool>` |
| **Notes** | `in_session` = `(session_info != NULL)`. This distinguishes the normal path (message_b appended) from the buggy session path (message_b NOT appended). The Trace spec dispatches on this field. Capture `in_session` from the local variable `session_info` at line 56 of `libspdm_rsp_certificate.c`. |

---

### `TraceReqCertificateRecv`

| Field | Value |
|---|---|
| **Spec action** | `ReqCertificateRecv` |
| **Code location** | `library/spdm_requester_lib/libspdm_req_get_certificate.c` — after cert chain stored and state advanced |
| **Trigger point** | After `libspdm_set_connection_state(LIBSPDM_CONNECTION_STATE_AFTER_CERTIFICATE)` on Requester |
| **Event name** | `"req_certificate_recv"` |
| **Node** | `"requester"` |
| **Extra fields** | `"slot": <slot_id>`, `"cert_fetched": <bool>`, `"cert_hash_valid": <bool>` |

---

### `TraceReqChallenge`

| Field | Value |
|---|---|
| **Spec action** | `ReqChallenge` |
| **Code location** | `library/spdm_requester_lib/libspdm_req_challenge.c:89` — after precondition check passes |
| **Trigger point** | After the connection_state guard at line 89 passes, before request is sent |
| **Event name** | `"req_challenge"` |
| **Node** | `"requester"` |
| **Extra fields** | `"slot": <slot_id_or_0xFF>` |
| **Notes** | Emit for both normal and mutual auth CHALLENGE paths. For the mutual auth path, a separate `"req_premature_authenticated"` event is emitted at line 380. Slot 0xFF maps to `NullSlot` in the spec. |

---

### `TraceRspChallengeAuth`

| Field | Value |
|---|---|
| **Spec action** | `RspChallengeAuth` |
| **Code location** | `library/spdm_responder_lib/libspdm_rsp_challenge_auth.c:337` — after `libspdm_set_connection_state(AUTHENTICATED)` |
| **Trigger point** | After state set to AUTHENTICATED on Responder |
| **Event name** | `"rsp_challenge_auth"` |
| **Node** | `"responder"` |
| **Extra fields** | `"slot": <slot_id_or_0xFF>` |

---

### `TraceReqChallengeAuthVerifyPass` / `TraceReqChallengeAuthVerifyFail`

| Field | Value |
|---|---|
| **Spec actions** | `ReqChallengeAuthVerifyPass` / `ReqChallengeAuthVerifyFail` |
| **Code location** | `library/spdm_common_lib/libspdm_com_crypto_service.c:882-938` — inside `libspdm_verify_certificate_chain_hash()` |
| **Trigger point** | After `libspdm_verify_certificate_chain_hash()` returns |
| **Event name** | `"req_challenge_auth_recv"` |
| **Node** | `"requester"` |
| **Extra fields** | `"slot": <slot_id_or_0xFF>`, `"verify_result": "pass" | "fail"` |
| **Notes** | `verify_result` captures the return value of `libspdm_verify_certificate_chain_hash()`. Instrument at call site in `libspdm_req_challenge.c:252`. |

---

### `TraceReqSetAuthenticatedPrematurely`

| Field | Value |
|---|---|
| **Spec action** | `ReqSetAuthenticatedPrematurely` |
| **Code location** | `library/spdm_requester_lib/libspdm_req_challenge.c:380` — the direct struct write |
| **Trigger point** | At line 380: `context->connection_info.connection_state = LIBSPDM_CONNECTION_STATE_AUTHENTICATED` |
| **Event name** | `"req_premature_authenticated"` |
| **Node** | `"requester"` |
| **Extra fields** | `"slot": <slot_id_or_0xFF>` |
| **Notes** | This event is only emitted when `mut_auth` is active (i.e., when `libspdm_encapsulated_request()` will be called at line 392). Detect by checking whether `basic_mut_auth_requested` flag is set in the request. In a non-mut-auth flow, use `"req_challenge_auth_recv"` instead. |

---

### `TraceReqEncapRequestFail`

| Field | Value |
|---|---|
| **Spec action** | `ReqEncapRequestFail` |
| **Code location** | `library/spdm_requester_lib/libspdm_req_challenge.c:392-396` — after `libspdm_encapsulated_request()` returns non-SUCCESS |
| **Trigger point** | At line 393 (the `if (status != LIBSPDM_STATUS_SUCCESS)` branch body) |
| **Event name** | `"req_encap_fail"` |
| **Node** | `"requester"` |
| **Extra fields** | `"status": <hex_status_code>` |
| **Notes** | BUG INSTRUMENTATION: also capture `connection_state` here to confirm it remains AUTHENTICATED despite the failure (the bug). |

---

### `TraceRspEncapChallengeAuthFail`

| Field | Value |
|---|---|
| **Spec action** | `RspEncapChallengeAuthFail` |
| **Code location** | `library/spdm_responder_lib/libspdm_rsp_encap_challenge.c:257-260` — after signature verification returns failure |
| **Trigger point** | At line 259: the `if (status != LIBSPDM_STATUS_SUCCESS)` return branch |
| **Event name** | `"rsp_encap_sig_fail"` |
| **Node** | `"responder"` |
| **Extra fields** | `"status": <hex_status_code>` |
| **Notes** | BUG INSTRUMENTATION: capture `message_mut_c` size or a boolean `mut_c_non_empty` to confirm that message_mut_c was NOT reset (the bug). In the correct fix, `libspdm_reset_message_mut_c()` would be called before return. |

---

### `TraceAppendResponseFail_GetDigests`

| Field | Value |
|---|---|
| **Spec action** | `AppendResponseFail_GetDigests` |
| **Code location** | `library/spdm_responder_lib/libspdm_rsp_digests.c:180` — after `libspdm_append_message_b()` for the response fails |
| **Trigger point** | On failure return from `libspdm_append_message_b()` at line 180 |
| **Event name** | `"rsp_digest_append_fail"` |
| **Node** | `"responder"` |
| **Extra fields** | `"status": <hex_status_code>` |
| **Notes** | Inject failure by wrapping `libspdm_append_message_b()` at line 180 with a configurable error injection point. The request was already appended at line 173 and cannot be un-appended. |

---

### `TraceAppendResponseFail_GetCertificate`

| Field | Value |
|---|---|
| **Spec action** | `AppendResponseFail_GetCertificate` |
| **Code location** | `library/spdm_responder_lib/libspdm_rsp_certificate.c:235` — after `libspdm_append_message_b()` for certificate response fails |
| **Trigger point** | On failure return from `libspdm_append_message_b()` at line 235 |
| **Event name** | `"rsp_cert_append_fail"` |
| **Node** | `"responder"` |
| **Extra fields** | `"slot": <slot_id>`, `"status": <hex_status_code>` |
| **Notes** | Same pattern as GetDigests. Request was appended at line 228. |

---

## Section 3: Special Considerations

### 3.1 Mutual auth detection

The `basic_mut_auth_requested` flag is encoded in the CHALLENGE request's `other_params_support` field. To distinguish a mutual-auth CHALLENGE (which will trigger line 380 and the `"req_premature_authenticated"` event) from a standard CHALLENGE at instrumentation time, check `spdm_request.header.param2 & SPDM_CHALLENGE_REQUEST_REQUESTER_ONLY_MEASUREMENT` in `libspdm_req_challenge.c` or check the mutual auth capability flags in the connection context.

### 3.2 NullSlot (0xFF) serialization

Slot ID 0xFF must be serialized as the integer 255 in JSON, not as -1 or a string. In `Trace.tla`, `NullSlot` is mapped from the model constant. The harness must use the same numeric value configured in `base.cfg` (currently `NullSlot = NullSlot` with model value 255).

### 3.3 connection_state capture timing

All events capture `connection_state` **after** the state transition. For `"req_premature_authenticated"`, this is immediately after line 380 sets `AUTHENTICATED` — before `libspdm_encapsulated_request()` is called. This ensures the trace reflects the premature state for `ValidateConnectionState`.

### 3.4 In-session detection

`in_session` for `"rsp_get_certificate"` is read from the local `session_info` pointer in `libspdm_get_response_certificate()` (`libspdm_rsp_certificate.c:56`). `session_info != NULL` → `in_session = true`.

### 3.5 Trace file location

Traces are written to `../traces/` relative to the `spec/` directory. The default file `../traces/trace.ndjson` is used unless overridden via `JSON=<path>` environment variable. Run TLC with `-DJSON=../traces/<specific_trace>.ndjson` to validate individual traces.

### 3.6 Omitted silent actions

Three base spec actions have no instrumentation hooks and are handled as silent actions in `Trace.tla`:
- `ReqEncapRequestSuccess` — emitted only when encap succeeds; detected by absence of `"req_encap_fail"` on next line
- `RspEncapChallengeSend` — the encap CHALLENGE is embedded in the CHALLENGE_AUTH response; no separate wire event
- `RspEncapChallengeAuthSuccess` — successful encap sig verify; detected by absence of `"rsp_encap_sig_fail"`
