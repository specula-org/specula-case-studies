# Instrumentation Spec — libspdm GET_MEASUREMENTS

Maps each `Trace.tla` action wrapper to the exact source code location, trigger point,
event name, and fields to capture for the NDJSON trace.

---

## Section 1: Trace Event Schema

### Event Envelope

Every event is one JSON object on its own line (NDJSON):

```json
{
  "event":   "<event_name>",
  "data":    { ... },
  "post":    { ... }
}
```

- **`event`** — string matching the `IsEvent(name)` predicate in `Trace.tla`
- **`data`** — inputs / parameters at the trigger point (pre-action)
- **`post`** — post-action state snapshot (captured after the action completes)

### State Fields (captured in `post` at every relevant event)

| Field | C source | TLA+ variable |
|-------|----------|---------------|
| `spdm_version` | `context->connection_info.version >> SPDM_VERSION_NUMBER_SHIFT_BIT` as string `"1.1"` etc. | `spdm_version` |
| `connection_state` | `context->connection_info.connection_state` (enum string) | `connection_state` |
| `response_state` | `context->response_state` (enum string) | `response_state` |
| `message_m_global_len` | `libspdm_get_managed_buffer_size(&context->transcript.message_m)` | `Len(message_m_global)` |
| `message_m_session_len` | `libspdm_get_managed_buffer_size(&session->session_transcript.message_m)` | `Len(message_m_session[sid])` |
| `session_id` | `session_info ? *session_id_ptr : 0` | `current_session_id` |
| `parse_offset` | local variable `ptr - (uint8_t*)spdm_response` | `parse_offset` |
| `parse_error` | boolean return value of size check | `parse_error` |
| `response_slot` | `spdm_response->header.param2 & SPDM_MEASUREMENTS_RESPONSE_SLOT_ID_MASK` | `response_slot` |
| `gen_sig` | `(param1 & SPDM_GET_MEASUREMENTS_REQUEST_ATTRIBUTES_GENERATE_SIGNATURE) != 0` | `current_request.gen_sig` |
| `slot_id` | `slot_id_param` or `"none"` when no-sig | `requested_slot` / `signing_slot` |

---

## Section 2: Action-to-Code Mapping

### 1. `negotiate_version`

| Field | Value |
|-------|-------|
| **Spec action** | `NegotiateVersion(v)` |
| **Code location** | `library/spdm_common_lib/libspdm_com_context_data.c`: `libspdm_set_connection_state` at `CS_NEGOTIATED` transition |
| **Trigger point** | After `connection_info.connection_state` is set to `LIBSPDM_CONNECTION_STATE_NEGOTIATED` |
| **Event name** | `negotiate_version` |
| **Data fields** | `version`: negotiated version string (e.g. `"1.2"`) |
| **Post fields** | `spdm_version`, `connection_state` |
| **Notes** | Fire once per successful NEGOTIATE_ALGORITHMS completion. Captures the agreed version before any GET_MEASUREMENTS. |

---

### 2. `establish_session`

| Field | Value |
|-------|-------|
| **Spec action** | `EstablishSession(sid)` |
| **Code location** | `library/spdm_responder_lib/libspdm_rsp_key_exchange.c` or `libspdm_rsp_psk_exchange.c`: at `LIBSPDM_SESSION_STATE_ESTABLISHED` transition |
| **Trigger point** | After `libspdm_secured_message_set_session_state(ESTABLISHED)` |
| **Event name** | `establish_session` |
| **Data fields** | `session_id`: uint32 session identifier |
| **Post fields** | `session_id` (confirm in `active_sessions`) |
| **Notes** | Captures the `session_id` that becomes active. |

---

### 3. `requester_send_get_measurements`

| Field | Value |
|-------|-------|
| **Spec action** | `RequesterSendGetMeasurements(sid, slot, gen_sig, meas_idx)` |
| **Code location** | `library/spdm_requester_lib/libspdm_req_get_measurements.c`: entry of `libspdm_try_get_measurement`, after parameter validation, before `libspdm_send_request` (~line 230) |
| **Trigger point** | After request buffer is assembled, before sending |
| **Event name** | `requester_send_get_measurements` |
| **Data fields** | `session_id`, `gen_sig`, `slot_id` (string `"none"` if no sig), `meas_index` |
| **Post fields** | `gen_sig`, `slot_id`, `session_id`, `message_m_global_len` or `message_m_session_len` |
| **Notes** | Capture `slot_id_param` at this point to detect the uninitialized-for-v1.0 bug (Family 4, CR1). |

---

### 4. `responder_append_request`

| Field | Value |
|-------|-------|
| **Spec action** | `ResponderAppendRequest` |
| **Code location** | `library/spdm_responder_lib/libspdm_rsp_measurements.c:497` — immediately after `libspdm_append_message_m(spdm_context, session_info, spdm_request, spdm_request_size)` |
| **Trigger point** | After the request has been appended to message_m (success path) |
| **Event name** | `responder_append_request` |
| **Data fields** | `session_id`, `request_size` |
| **Post fields** | `message_m_global_len` or `message_m_session_len`, `session_id` |
| **Notes** | Only fire on the success path. On error paths the message_m reset fires instead. |

---

### 5. `responder_build_response`

| Field | Value |
|-------|-------|
| **Spec action** | `ResponderBuildResponse(ml, ol, hs)` |
| **Code location** | `library/spdm_responder_lib/libspdm_rsp_measurements.c:505-512` — after `libspdm_append_message_m` for the response (excluding signature bytes) |
| **Trigger point** | After `libspdm_append_message_m(spdm_context, session_info, spdm_response, *response_size - signature_size)` succeeds |
| **Event name** | `responder_build_response` |
| **Data fields** | `meas_len`, `opaque_len`, `has_sig`, `session_id` |
| **Post fields** | `response_slot`, `signing_slot` (= `slot_id_param`), `message_m_global_len` / `message_m_session_len` |
| **Notes** | `slot_id_param` is captured here (after line 424 assignment for v1.1+). Captures the uninitialized-slot bug path for v1.0. |

---

### 6. `responder_generate_signature`

| Field | Value |
|-------|-------|
| **Spec action** | `ResponderGenerateSignature` |
| **Code location** | `library/spdm_responder_lib/libspdm_rsp_measurements.c:41` — immediately after `libspdm_reset_message_m(spdm_context, session_info)` inside `libspdm_generate_measurement_signature` |
| **Trigger point** | After message_m reset, before the `if (!result) return false` check (captures the reset-before-failure window) |
| **Event name** | `responder_generate_signature` |
| **Data fields** | `session_id`, `slot_id` |
| **Post fields** | `message_m_global_len` (should be 0), `message_m_session_len` (should be 0), `session_id` |
| **Notes** | Capturing AFTER the reset and BEFORE the failure check is critical for Family 1 bug MC1. |

---

### 7. `l1l2_computation_failure`

| Field | Value |
|-------|-------|
| **Spec action** | `L1L2ComputationFailure` |
| **Code location** | `library/spdm_responder_lib/libspdm_rsp_measurements.c:42-44` — inside `if (!result) return false` branch of `libspdm_generate_measurement_signature` |
| **Trigger point** | At entry of the `if (!result)` branch, before `return false` |
| **Event name** | `l1l2_computation_failure` |
| **Data fields** | `session_id` |
| **Post fields** | `message_m_global_len` (= 0 — already reset), `message_m_session_len` (= 0) |
| **Notes** | This event fires when `libspdm_calculate_l1l2` returns false. Traces the destructive reset-before-failure pattern. |

---

### 8. `requester_parse_response_sig`

| Field | Value |
|-------|-------|
| **Spec action** | `RequesterParseResponseSig` |
| **Code location** | `library/spdm_requester_lib/libspdm_req_get_measurements.c:426-496` — after all size checks in the `generate_signature` branch complete |
| **Trigger point** | After the final `if (spdm_response_size < ...)` check and `spdm_response_size = ...` normalization (line ~495), before appending to message_m |
| **Event name** | `requester_parse_response_sig` |
| **Data fields** | `session_id`, `meas_len`, `opaque_len`, `response_size` |
| **Post fields** | `parse_offset`, `parse_error` (= false on success), `session_id` |
| **Notes** | Capture `ptr - (uint8_t*)spdm_response` as `parse_offset` after the last `ptr +=` before message_m append. |

---

### 9. `requester_parse_response_nosig`

| Field | Value |
|-------|-------|
| **Spec action** | `RequesterParseResponseNoSig` |
| **Code location** | `library/spdm_requester_lib/libspdm_req_get_measurements.c:545-575` — after size check (line 546-548) and nonce/opaque reads |
| **Trigger point** | After `ptr += SPDM_NONCE_SIZE` (line 558) and `opaque_length = libspdm_read_uint16(ptr)` (line 563) |
| **Event name** | `requester_parse_response_nosig` |
| **Data fields** | `session_id`, `meas_len`, `opaque_len`, `response_size` |
| **Post fields** | `parse_offset` (= `ptr - (uint8_t*)spdm_response`), `parse_error` (= `parse_offset > response_size`) |
| **Notes** | This is where the Family 2 confirmed bug lives. If `response_size < sizeof(header) + meas_len + NONCE_SIZE + 2`, parse_error will be TRUE in the spec but the code may continue. Capture both `parse_offset` and `response_size` to expose the discrepancy. |

---

### 10. `requester_verify_signature`

| Field | Value |
|-------|-------|
| **Spec action** | `RequesterVerifySignature` |
| **Code location** | `library/spdm_requester_lib/libspdm_req_get_measurements.c:544` — immediately after `libspdm_reset_message_m` in the signature-verified success path |
| **Trigger point** | After `libspdm_reset_message_m(spdm_context, session_info)` at line 544 (signature verified, message_m cleared) |
| **Event name** | `requester_verify_signature` |
| **Data fields** | `session_id`, `slot_id` |
| **Post fields** | `message_m_global_len` (= 0), `message_m_session_len` (= 0), `session_id`, `sig_verified` (= true) |
| **Notes** | Fire only on the success path (after `libspdm_verify_measurement_signature` returns true). |

---

### 11. `complete_exchange`

| Field | Value |
|-------|-------|
| **Spec action** | `CompleteExchange` |
| **Code location** | `library/spdm_requester_lib/libspdm_req_get_measurements.c` — at `receive_done:` label or equivalent return point |
| **Trigger point** | After the exchange function returns (either signature or no-signature path complete) |
| **Event name** | `complete_exchange` |
| **Data fields** | `session_id`, `status` (SPDM return code) |
| **Post fields** | `parse_offset` (= 0), `parse_error` (= false) |
| **Notes** | Fire at the function exit. Covers both clean completion and error exit (parse_error capture distinguishes them). |

---

### 12. `need_resync`

| Field | Value |
|-------|-------|
| **Spec action** | `NeedResync` |
| **Code location** | `library/spdm_responder_lib/libspdm_rsp_handle_response_state.c:21-31` — inside `LIBSPDM_RESPONSE_STATE_NEED_RESYNC` branch |
| **Trigger point** | At entry of the NEED_RESYNC response state handler |
| **Event name** | `need_resync` |
| **Data fields** | (none) |
| **Post fields** | `connection_state` (= NOT_STARTED) |
| **Notes** | Captures the Family 3 bug: active_sessions are NOT cleared here. Verify in trace that `active_sessions` in spec stays non-empty. |

---

### 13. `reset_context`

| Field | Value |
|-------|-------|
| **Spec action** | `ResetContext` |
| **Code location** | `library/spdm_common_lib/libspdm_com_context_data.c:2942-2957` — `libspdm_reset_context` |
| **Trigger point** | At return of `libspdm_reset_context` |
| **Event name** | `reset_context` |
| **Data fields** | (none) |
| **Post fields** | `connection_state` (= NOT_STARTED), `message_m_global_len` (= 0) |
| **Notes** | Note that `message_m_session_len` values are NOT reset here — Family 3 bug. Capture them to verify they remain non-zero after reset_context when a session was active. |

---

## Section 3: Special Considerations

### Dual message_m buffers (Family 3)
Both `message_m_global_len` and `message_m_session_len` must be captured at every relevant
event. The `session_id` field determines which buffer to capture; when `session_id = 0`,
capture global; otherwise capture per-session. When both could matter (e.g. around `NeedResync`
or `ResetContext`), capture both.

### Transcript not stored as byte sequence in model
The spec models `message_m_global` as a sequence of `{req, resp}` pair records rather than raw
bytes. The trace captures `message_m_*_len` (count of pairs), not byte-level content. This is
intentional: the invariants checked (L1L2Agreement, TranscriptNoSignatureBytes) operate on the
structural content, not the byte count. For deeper byte-content verification, compare
`libspdm_get_managed_buffer_size(&context->transcript.message_m)` before/after each append.

### Uninitialized slot_id_param for SPDM v1.0 (Family 4 / CR1)
For traces that exercise SPDM v1.0 with `GENERATE_SIGNATURE`, `slot_id_param` is read from the
stack. The harness should capture the value of `slot_id_param` at `responder_build_response`
even for v1.0 (where it is never assigned). The captured value may be non-deterministic. In the
spec, v1.0 + sig is modeled as using slot 0; if the trace captures a non-zero value, this is
direct evidence of the uninitialized-variable bug.

### response_size injection (Family 2)
`RequesterParseResponseNoSig` requires that `response_size` be injected into the initial state or
captured in the `complete_exchange` / `requester_parse_response_nosig` events. The harness must
capture `spdm_response_size` (the actual byte count received, before any truncation) in the
`requester_parse_response_nosig` data block. TLC will then check whether `parse_offset > response_size`.

### L1/L2 content abstraction
The spec models L1/L2 as a sequence `message_a \o message_m` (concatenation) rather than the
actual cryptographic hash. This suffices for verifying structural equality. For trace validation,
the harness does NOT need to capture the hash value; the spec checks structural equality of the
transcript sequences, not the hash bytes.

### TraceInit / bootstrap
If a trace starts after `NEGOTIATE_ALGORITHMS` (i.e., connection already established), emit a
synthetic `negotiate_version` event as the first event in the trace to bootstrap the spec state,
or adjust `TraceInit` to start with `connection_state = CS_NEGOTIATED` and the correct
`spdm_version`. See `TraceInit` in `Trace.tla`.
