# Instrumentation Spec: libspdm VCA Handshake

Action-to-code mapping for trace harness generation.
Companion to `Trace.tla` / `Trace.cfg`.

---

## Section 1: Trace Event Schema

### Event Envelope

Every NDJSON line has the following common fields:

```json
{
  "event": "<event_name>",
  "timestamp_ns": <uint64>,
  "conn_state": "<NOT_STARTED|AFTER_VERSION|AFTER_CAPS|NEGOTIATED>"
}
```

`conn_state` is captured **after** the state transition completes, so it reflects the new state.

### State Fields (captured at every event that modifies them)

| Trace field | Implementation source | TLA+ variable |
|---|---|---|
| `conn_state` | `spdm_context->connection_info.connection_state` | `conn_state` |
| `negotiated_version` | `spdm_context->connection_info.version >> SPDM_VERSION_NUMBER_SHIFT_BIT` | `negotiated_version` |
| `req_cap_flags` | `spdm_context->connection_info.capability.flags` (requester's stored copy of its own flags) | `req_cap_flags` |
| `rsp_cap_flags` | `spdm_context->connection_info.capability.flags` (responder's stored copy) | `rsp_cap_flags` |
| `base_hash_algo` | `spdm_context->connection_info.algorithm.base_hash_algo` | `base_hash_algo` |
| `base_asym_algo` | `spdm_context->connection_info.algorithm.base_asym_algo` | `base_asym_algo` |
| `measurement_spec` | `spdm_context->connection_info.algorithm.measurement_spec` | `measurement_spec` |
| `measurement_hash_algo` | `spdm_context->connection_info.algorithm.measurement_hash_algo` | `measurement_hash_algo` |
| `dhe_algo` | `spdm_context->connection_info.algorithm.dhe_named_group` | `dhe_algo` |
| `aead_algo` | `spdm_context->connection_info.algorithm.aead_cipher_suite` | `aead_algo` |
| `req_asym_algo` | `spdm_context->connection_info.algorithm.req_base_asym_alg` | `req_asym_algo` |
| `key_schedule_algo` | `spdm_context->connection_info.algorithm.key_schedule` | `key_schedule_algo` |
| `req_alg_types` | derived from `spdm_request->header.param1` and struct table | `req_alg_types` |
| `rsp_alg_types` | derived from `spdm_response->header.param1` and struct table | `rsp_alg_types` |
| `req_appended_version` | shadow bool tracking message_a append for VERSION phase | `req_appended["version"]` |
| `rsp_appended_version` | shadow bool tracking message_a append for VERSION phase | `rsp_appended["version"]` |
| `req_appended_capabilities` | shadow bool for CAPABILITIES phase | `req_appended["capabilities"]` |
| `rsp_appended_capabilities` | shadow bool for CAPABILITIES phase | `rsp_appended["capabilities"]` |
| `req_appended_algorithms` | shadow bool for ALGORITHMS phase | `req_appended["algorithms"]` |
| `rsp_appended_algorithms` | shadow bool for ALGORITHMS phase | `rsp_appended["algorithms"]` |

### Algorithm value encoding

Scalar algorithm fields (hash, asym, etc.) are emitted as raw `uint32_t` values.
`Trace.tla` maps non-zero → `ALGO_SOME`, zero → `ALGO_NONE`.

### AlgType set encoding

`req_alg_types` and `rsp_alg_types` are emitted as JSON objects with boolean values:
```json
{
  "ALG_DHE": true,
  "ALG_AEAD": false,
  "ALG_REQ_ASYM": true,
  "ALG_KEY_SCHEDULE": true,
  "ALG_REQ_PQC_ASYM": false,
  "ALG_KEM": false
}
```

### Capability flag set encoding

`req_cap_flags` and `rsp_cap_flags` are emitted as JSON arrays of string names
matching the TLA+ constant names:
```json
["CERT_CAP", "CHAL_CAP", "KEY_EX_CAP", "MAC_CAP"]
```

---

## Section 2: Action-to-Code Mapping

### 1. `req_send_get_version`

| Field | Value |
|---|---|
| **Spec action** | `ReqSendGetVersion` |
| **Code location** | `library/spdm_requester_lib/libspdm_req_get_version.c:~150` |
| **Trigger point** | After `libspdm_append_message_a` for GET_VERSION request (request appended to transcript) |
| **Event name** | `req_send_get_version` |
| **Captured fields** | `conn_state`, `req_appended_version=true` |
| **Notes** | Fires once per handshake attempt. On retry after context reset, fires again. |

---

### 2. `rsp_handle_get_version`

| Field | Value |
|---|---|
| **Spec action** | `RspHandleGetVersion(v)` |
| **Code location** | `library/spdm_responder_lib/libspdm_rsp_version.c:~80` |
| **Trigger point** | After building the VERSION response message, before sending (after `libspdm_append_message_a` for both request and response) |
| **Event name** | `rsp_handle_get_version` |
| **Captured fields** | `offered_version` (string e.g. `"1.2"`), `conn_state`, `req_appended_version=true`, `rsp_appended_version=true` |
| **Notes** | `offered_version` comes from the VERSION response payload version field. |

---

### 3. `req_handle_version`

| Field | Value |
|---|---|
| **Spec action** | `ReqHandleVersion` |
| **Code location** | `library/spdm_requester_lib/libspdm_req_get_version.c:~200` |
| **Trigger point** | After `connection_info.version` is set and `connection_state` advances to `AFTER_VERSION` |
| **Event name** | `req_handle_version` |
| **Captured fields** | `negotiated_version` (string), `conn_state`, `rsp_appended_version=true` |
| **Notes** | `negotiated_version` from `spdm_context->connection_info.version >> SPDM_VERSION_NUMBER_SHIFT_BIT`. |

---

### 4. `req_send_get_capabilities`

| Field | Value |
|---|---|
| **Spec action** | `ReqSendGetCapabilities(flags)` |
| **Code location** | `library/spdm_requester_lib/libspdm_req_get_capabilities.c:~350` |
| **Trigger point** | After `libspdm_append_message_a` for GET_CAPABILITIES request |
| **Event name** | `req_send_get_capabilities` |
| **Captured fields** | `req_cap_flags` (flag name array), `conn_state`, `req_appended_capabilities=true` |
| **Notes** | Capture flags **after** `libspdm_mask_capability_flags` is applied (if v3.x+). |

---

### 5. `rsp_handle_get_capabilities`

| Field | Value |
|---|---|
| **Spec action** | `RspHandleGetCapabilities(req_f, rsp_f)` |
| **Code location** | `library/spdm_responder_lib/libspdm_rsp_capabilities.c:223` (after flag compatibility check passes) and `~400` (after response is built) |
| **Trigger point** | After `libspdm_append_message_a` for both GET_CAPABILITIES request and CAPABILITIES response; after `connection_state` set to `AFTER_CAPS` |
| **Event name** | `rsp_handle_get_capabilities` |
| **Captured fields** | `req_cap_flags`, `rsp_cap_flags`, `conn_state`, `req_appended_capabilities=true`, `rsp_appended_capabilities=true` |
| **Notes** | Instrument at the point where both appends have succeeded and state is updated. The F2 bug (PSK_CAP==3 rejection, missing KEY_EX check) manifests here — if the responder returns an error instead, emit `rsp_error_capabilities`. |

---

### 6. `req_handle_capabilities`

| Field | Value |
|---|---|
| **Spec action** | `ReqHandleCapabilities` |
| **Code location** | `library/spdm_requester_lib/libspdm_req_get_capabilities.c:~430` |
| **Trigger point** | After `validate_responder_capability` passes and `connection_state` set to `AFTER_CAPS` |
| **Event name** | `req_handle_capabilities` |
| **Captured fields** | `rsp_cap_flags`, `conn_state`, `rsp_appended_capabilities=true` |
| **Notes** | The F2 check (KEY_EX requires CERT or PUB_KEY_ID) is present in `validate_responder_capability` — if validation fails, the event is not emitted (the function returns an error status). |

---

### 7. `req_send_negotiate_algorithms`

| Field | Value |
|---|---|
| **Spec action** | `ReqSendNegotiateAlgorithms(alg_types)` |
| **Code location** | `library/spdm_requester_lib/libspdm_req_negotiate_algorithms.c:~200` |
| **Trigger point** | After `libspdm_append_message_a` for NEGOTIATE_ALGORITHMS request |
| **Event name** | `req_send_negotiate_algorithms` |
| **Captured fields** | `req_alg_types` (object), `conn_state`, `req_appended_algorithms=true` |
| **Notes** | Build `req_alg_types` by walking the struct table in the request: set `ALG_DHE=true` if struct table has DHE entry, etc. Param1 counts entries. |

---

### 8. `rsp_handle_negotiate_algorithms`

| Field | Value |
|---|---|
| **Spec action** | `RspHandleNegotiateAlgorithms(...)` |
| **Code location** | `library/spdm_responder_lib/libspdm_rsp_algorithms.c:~820` (after algorithm selection and `libspdm_append_message_a` for both messages) |
| **Trigger point** | After `connection_state` set to `NEGOTIATED` and both transcript appends complete |
| **Event name** | `rsp_handle_negotiate_algorithms` |
| **Captured fields** | `base_hash_algo`, `base_asym_algo`, `measurement_spec`, `measurement_hash_algo`, `dhe_algo`, `aead_algo`, `req_asym_algo`, `key_schedule_algo`, `rsp_alg_types` (object), `conn_state`, `req_appended_algorithms=true`, `rsp_appended_algorithms=true` |
| **Notes** | Critical for F1: capture `measurement_spec` and `measurement_hash_algo` independently — the MC1 bug is that mspec≠0 but mhash=0 when MEL_CAP=1, MEAS_CAP=0. Capture all fields from `spdm_context->connection_info.algorithm.*`. |

---

### 9. `req_handle_algorithms`

| Field | Value |
|---|---|
| **Spec action** | `ReqHandleAlgorithms` |
| **Code location** | `library/spdm_requester_lib/libspdm_req_negotiate_algorithms.c:~570` |
| **Trigger point** | After requester validates ALGORITHMS response and sets `connection_state = NEGOTIATED` |
| **Event name** | `req_handle_algorithms` |
| **Captured fields** | `base_hash_algo`, `base_asym_algo`, `measurement_spec`, `measurement_hash_algo`, `rsp_alg_types`, `conn_state`, `rsp_appended_algorithms=true` |
| **Notes** | F3: the struct table mirroring check happens here. If mirroring fails, the requester returns error and this event is NOT emitted. |

---

### 10. `rsp_error_capabilities`

| Field | Value |
|---|---|
| **Spec action** | `RspErrorInCapabilities` |
| **Code location** | `library/spdm_responder_lib/libspdm_rsp_capabilities.c` — any early-return path that returns after appending the request to message_a but before appending the response |
| **Trigger point** | Any `return libspdm_generate_error_response(...)` call inside `libspdm_get_response_capabilities` that occurs after the request has been appended to message_a |
| **Event name** | `rsp_error_capabilities` |
| **Captured fields** | `conn_state`, `req_appended_capabilities=true`, `rsp_appended_capabilities=false`, error code |
| **Notes** | F4 target. The key invariant violation: req_appended=TRUE, rsp_appended=FALSE. In current libspdm code, the request is appended early (`libspdm_append_message_a` for the request in the responder path), so any mid-function error leaves a lone request. |

---

### 11. `rsp_error_algorithms`

| Field | Value |
|---|---|
| **Spec action** | `RspErrorInAlgorithms` |
| **Code location** | `library/spdm_responder_lib/libspdm_rsp_algorithms.c` — any `return libspdm_generate_error_response(...)` after request has been appended |
| **Trigger point** | Any early-return inside `libspdm_get_response_algorithms` that occurs after request append |
| **Event name** | `rsp_error_algorithms` |
| **Captured fields** | `conn_state`, `req_appended_algorithms=true`, `rsp_appended_algorithms=false`, error code |
| **Notes** | F4 target. Same pattern as `rsp_error_capabilities`. Note there are multiple error returns inside `libspdm_get_response_algorithms` (lines ~579, ~597, ~614, etc.) — instrument all of them. |

---

### 12. `context_reset`

| Field | Value |
|---|---|
| **Spec action** | `ContextReset` |
| **Code location** | `library/spdm_common_lib/libspdm_common_context_data.c` (`libspdm_reset_context`) |
| **Trigger point** | At entry to `libspdm_reset_context` |
| **Event name** | `context_reset` |
| **Captured fields** | `conn_state=NOT_STARTED`, `ctx_reset_count` (incremented) |
| **Notes** | Captures the full context wipe. Also emitted implicitly by GET_VERSION processing in the responder (which resets state before rebuilding). |

---

## Section 3: Special Considerations

### 3.1 Dual role (Requester vs. Responder)

libspdm implements both Requester and Responder in the same library. Traces should tag
each event with a `role` field (`"requester"` or `"responder"`) to distinguish which
side generated the event. The Trace spec uses a single global state (both sides share
`spdm_context` in unit tests); for integration tests using two separate contexts,
use the `node_id` field to distinguish them.

### 3.2 Transcript append timing

The F4 bug lives in the gap between "request appended" and "response appended." To
capture this accurately:
- Instrument `libspdm_append_message_a` calls **by call site** (not inside the function)
- Emit a `*_req_appended` sub-event before generating the response, and a `*_rsp_appended` sub-event after success
- If the harness cannot split these, emit the main event with explicit boolean fields `req_appended` and `rsp_appended`

### 3.3 Algorithm field serialization

`measurement_hash_algo` is a `uint32_t` bitmask. Emit it as a raw integer; `Trace.tla`
converts non-zero → `ALGO_SOME`. Do not emit the string name (the spec abstracts over
the specific algorithm choice).

### 3.4 Capability flag set derivation

Extract flag names from the `uint32_t` bit field using a helper that iterates over
known bit positions. Emit only the flags that are set. The TLA+ `TraceCapFlags` helper
expects a JSON array of string names matching the constant names in `base.tla`.

### 3.5 rsp_alg_types / req_alg_types derivation

Walk the struct table in the request (or response) header, reading `alg_type` fields.
Emit a JSON object with all 6 `ALG_*` keys, setting each to `true` or `false`.
Unknown `alg_type` values from future spec versions should be ignored (set to `false`).

### 3.6 Unit test harness vs. integration test harness

For unit testing (single process, single context), inject instrumentation directly
into the C source. For integration testing (two separate processes for Requester and
Responder), collect traces from both processes, merge on timestamp, and feed the
merged NDJSON file to TLC.

### 3.7 libspdm version note

`libspdm_mask_capability_flags` was introduced in v3.x. For older builds, the masking
step is absent and `req_cap_flags` may contain version-mismatched bits. The spec
models this via `ReqSendGetCapabilities`'s version gate — if the harness runs against
an older build, the trace may include events that violate `VersionAlgoScope` (which is
the F1 finding).
