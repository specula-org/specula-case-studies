# Instrumentation Spec: libspdm Encapsulated Mutual Authentication

## Section 1: Trace Event Schema

### Event Envelope

Every trace event is a JSON object on one line (NDJSON):

```json
{
  "event":            "<event_name>",
  "cur_op":           <uint8 op-code integer>,
  "request_id":       <uint8>,
  "response_state":   "<NORMAL|PROCESSING_ENCAP>",
  "variant":          "<NO_ENCAP|WITH_ENCAP_REQUEST|WITH_GET_DIGESTS|BASIC_PK|BASIC_CERT>",
  "cur_op_after":     <uint8>,
  "request_id_after": <uint8>,
  "response_state_after": "<NORMAL|PROCESSING_ENCAP>",
  ... event-specific fields ...
}
```

### Op-code integer encoding (matches `SPDM_*` constants)

| Integer | Constant              | Spec constant   |
|---------|-----------------------|-----------------|
| 0       | 0x00 (terminator)     | `OP_NONE`       |
| 1       | `SPDM_GET_DIGESTS`    | `OP_GET_DIGESTS`|
| 2       | `SPDM_GET_CERTIFICATE`| `OP_GET_CERTIFICATE` |
| 17      | `SPDM_CHALLENGE`      | `OP_CHALLENGE`  |

### Variant string encoding

| String                | C constant                                                    |
|-----------------------|---------------------------------------------------------------|
| `"NO_ENCAP"`          | `SPDM_KEY_EXCHANGE_RESPONSE_MUT_AUTH_REQUESTED`               |
| `"WITH_ENCAP_REQUEST"`| `SPDM_KEY_EXCHANGE_RESPONSE_MUT_AUTH_REQUESTED_WITH_ENCAP_REQUEST` |
| `"WITH_GET_DIGESTS"`  | `SPDM_KEY_EXCHANGE_RESPONSE_MUT_AUTH_REQUESTED_WITH_GET_DIGESTS`   |
| `"BASIC_PK"`          | basic mut auth, `PUB_KEY_ID_CAP` set                          |
| `"BASIC_CERT"`        | basic mut auth, `PUB_KEY_ID_CAP` not set                      |

### State fields captured at every event (pre-action snapshot)

| Trace field       | C source field                                                | TLA+ variable    |
|-------------------|---------------------------------------------------------------|------------------|
| `cur_op`          | `spdm_context->encap_context.current_request_op_code`        | `cur_op`         |
| `request_id`      | `spdm_context->encap_context.request_id`                     | `request_id`     |
| `response_state`  | `spdm_context->response_state`                               | `response_state` |
| `variant`         | determined at init time (see init event)                     | `variant`        |

### Post-action state fields (captured after the action completes)

| Trace field            | C source field                                                | TLA+ variable    |
|------------------------|---------------------------------------------------------------|------------------|
| `cur_op_after`         | `spdm_context->encap_context.current_request_op_code`        | `cur_op'`        |
| `request_id_after`     | `spdm_context->encap_context.request_id`                     | `request_id'`    |
| `response_state_after` | `spdm_context->response_state`                               | `response_state'`|

---

## Section 2: Action-to-Code Mapping

### Action: `init_encap_state`

| Field       | Value |
|-------------|-------|
| Spec action | `Init` (initialization event; consumed by TraceInit) |
| Code location | `libspdm_init_mut_auth_encap_state` (rsp_encap_response.c:551-612) AND `libspdm_init_basic_mut_auth_encap_state` (rsp_encap_response.c:508-548) |
| Trigger point | **After** the init function returns, before any protocol exchange |
| Event name  | `"init_encap_state"` |
| Fields | `cur_op`, `request_id`, `response_state`, `variant`, `resp_authenticated`, `cur_op_after` (= `cur_op`), `request_id_after` (= 0), `response_state_after` |
| Notes | For `WITH_GET_DIGESTS`, `cur_op` will be `1` (GET_DIGESTS) not `0`. Variant string must be determined from the `mut_auth_requested` parameter or capability flags. `resp_authenticated` must be captured at this point: check `spdm_context->connection_info.connection_state == LIBSPDM_CONNECTION_STATE_AUTHENTICATED` and emit `true`/`false`. This field is critical for Family 2 trace validation (req_challenge.c:380 sets AUTHENTICATED before the init call at line 389). |

---

### Action: `verify_responder`

| Field       | Value |
|-------------|-------|
| Spec action | `VerifyResponder` |
| Code location | `libspdm_try_challenge` (req_challenge.c:380) |
| Trigger point | **After** `spdm_context->connection_info.connection_state = LIBSPDM_CONNECTION_STATE_AUTHENTICATED` is assigned (line 380) and **before** `libspdm_encapsulated_request` is called (line 389) |
| Event name  | `"verify_responder"` |
| Fields | Standard state fields (all encap fields are unchanged here) |
| Notes | This event marks the moment AUTHENTICATED is set while encap has not yet started. It is the key evidence for Family 2. Capture only when `(auth_attribute & SPDM_CHALLENGE_AUTH_RESPONSE_ATTRIBUTE_BASIC_MUT_AUTH_REQ) != 0` is true (line 384), indicating encap will follow. |

---

### Action: `get_encapsulated_request`

| Field       | Value |
|-------------|-------|
| Spec action | `GetEncapsulatedRequest` |
| Code location | `libspdm_get_response_encapsulated_request` (rsp_encap_response.c:269-373) |
| Trigger point | **After** `libspdm_process_encapsulated_response` returns SUCCESS (after line 364) and before the response is serialized |
| Event name  | `"get_encapsulated_request"` |
| Fields | Pre-action state + `cur_op_after`, `request_id_after`, `response_state_after` |
| Notes | Capture BEFORE `spdm_response->header.param1 = spdm_context->encap_context.request_id` (line 366). The `cur_op_after` must reflect the advanced op-code (after `EncapMoveToNextOpCode`). |

---

### Action: `deliver_encap_digests`

| Field       | Value |
|-------------|-------|
| Spec action | `DeliverEncapResponseDigests` |
| Code location | `libspdm_process_encap_response_digest` (rsp_encap_get_digests.c, called from rsp_encap_response.c:143-144) |
| Trigger point | **After** `libspdm_process_encap_response_digest` returns SUCCESS, inside `libspdm_process_encapsulated_response`, before `request_id += 1` (rsp_encap_response.c:159) |
| Event name  | `"deliver_encap_digests"` |
| Fields | Pre-action state + `cur_op_after`, `request_id_after`, `response_state_after` |
| Notes | For `WITH_GET_DIGESTS` variant, the pre-action `request_id` is 0. Capture `cur_op_after` as the op-code AFTER `EncapMoveToNextOpCode` runs. |

---

### Action: `deliver_encap_certificate`

| Field       | Value |
|-------------|-------|
| Spec action | `DeliverEncapResponseCertificate` |
| Code location | `libspdm_process_encap_response_certificate` (rsp_encap_get_certificate.c:101-340) |
| Trigger point | **After** `peer_used_cert_chain[req_slot_id]` is populated (rsp_encap_get_certificate.c:297-334), i.e., after the `need_continue = false` path is taken (full chain received) |
| Event name  | `"deliver_encap_certificate"` |
| Fields | Pre-action state + `cur_op_after`, `request_id_after`, `response_state_after`, `cert_chain_received_after: true` |
| Notes | Only emit this event when `need_continue == false` (full chain complete). If `need_continue == true` (chunked transfer still in progress), do NOT emit — the spec models GET_CERTIFICATE as a single atomic step. Add an assertion that chunks are not modeled (or handle by emitting only when `cert_chain_total_len == bytes_received`). |

---

### Action: `deliver_encap_challenge_auth`

| Field       | Value |
|-------------|-------|
| Spec action | `DeliverEncapResponseChallengeAuth` |
| Code location | `libspdm_process_encap_response_challenge_auth` (rsp_encap_challenge.c:80-268) |
| Trigger point | **After** `libspdm_set_connection_state(spdm_context, LIBSPDM_CONNECTION_STATE_AUTHENTICATED)` at line 263, before `return LIBSPDM_STATUS_SUCCESS` |
| Event name  | `"deliver_encap_challenge_auth"` |
| Fields | Pre-action state + `cur_op_after` (= 0, CHALLENGE is last), `request_id_after`, `response_state_after` (= NORMAL), `mutually_authenticated_after: true`, `slot_id_ok_after: true`, `slot_mask_ok_after: true`, `cert_hash_ok_after: true` |
| Notes | Only emit on the SUCCESS path (after signature verification passes at line 257-261). Failure path emits `encap_error` instead. |

---

### Action: `encap_not_ready`

| Field       | Value |
|-------------|-------|
| Spec action | `EncapResponseNotReady` |
| Code location | `libspdm_process_encapsulated_response` (rsp_encap_response.c:149-153) |
| Trigger point | **After** `spdm_context->encap_context.current_request_op_code = 0` is assigned (line 151), inside the `LIBSPDM_STATUS_NOT_READY_PEER` branch |
| Event name  | `"encap_not_ready"` |
| Fields | Pre-action state + `cur_op_after: 0`, `request_id_after` (unchanged), `response_state_after: "NORMAL"` |
| Notes | `response_state` becomes NORMAL via the `encap_request_size == 0` path (rsp_encap_response.c:480-491) — capture AFTER that path runs, not inside `process_encapsulated_response`. The cleanest hook point is after `libspdm_get_response_encapsulated_response_ack` sets `response_state = NORMAL` (line 490). |

---

### Action: `encap_error`

| Field       | Value |
|-------------|-------|
| Spec action | `EncapError` |
| Code location (DELIVER path) | `libspdm_get_response_encapsulated_response_ack` (rsp_encap_response.c:467-470) |
| Code location (GET_ENCAP path) | `libspdm_get_response_encapsulated_request` (rsp_encap_response.c:359-363) |
| Trigger point | **After** `spdm_context->response_state = LIBSPDM_RESPONSE_STATE_NORMAL` is assigned (line 468 or 360), before the error response is generated |
| Event name  | `"encap_error"` |
| Fields | Pre-action state + `cur_op_after` (= unchanged, this is the bug), `request_id_after` (unchanged), `response_state_after: "NORMAL"`, `encap_error_after: true` |
| Notes | Instrument BOTH error paths (lines 359-363 and lines 467-470). The critical field to capture is `cur_op_after` which should show the NON-ZERO op-code that was left in the context. This directly validates the Family 4 invariant violation. |

---

## Section 3: Special Considerations

### 3.1 Multi-chunk GET_CERTIFICATE

The spec models GET_CERTIFICATE as a single atomic step (cert_chain_received flips TRUE once). The implementation uses chunked transfer with `need_continue = true` for partial chunks. The harness must:
- Only emit `deliver_encap_certificate` when `need_continue == false` (final chunk received)
- Ignore intermediate chunk deliveries (no event emitted)
- If chunked transfers must be traced, add a `deliver_encap_certificate_chunk` event type and model it as a silent action in Trace.tla

### 3.2 Variant Determination

The `variant` field is determined differently for basic vs. session mutual auth:
- **Basic mutual auth** (`libspdm_init_basic_mut_auth_encap_state`): check `PUB_KEY_ID_CAP` capability flag → `BASIC_PK` or `BASIC_CERT`
- **Session mutual auth** (`libspdm_init_mut_auth_encap_state`): use `mut_auth_requested` parameter directly

Add a helper function in the harness:
```c
static const char *get_variant_string(libspdm_context_t *ctx, uint8_t mut_auth_requested) {
    // For basic auth path (called from libspdm_init_basic_mut_auth_encap_state):
    if (libspdm_is_capabilities_flag_supported(ctx, false,
            SPDM_GET_CAPABILITIES_REQUEST_FLAGS_PUB_KEY_ID_CAP, 0))
        return "BASIC_PK";
    else
        return "BASIC_CERT";
    // For session path (called from libspdm_init_mut_auth_encap_state):
    // mut_auth_requested == MUT_AUTH_REQUESTED → "NO_ENCAP"
    // mut_auth_requested == WITH_ENCAP_REQUEST → "WITH_ENCAP_REQUEST"
    // mut_auth_requested == WITH_GET_DIGESTS   → "WITH_GET_DIGESTS"
}
```

### 3.3 response_state Encoding

`LIBSPDM_RESPONSE_STATE_NORMAL = 0`, `LIBSPDM_RESPONSE_STATE_PROCESSING_ENCAP = 1`. Emit as human-readable strings `"NORMAL"` or `"PROCESSING_ENCAP"` to match `TraceResponseState()` in Trace.tla.

### 3.4 request_id Capture Timing

`request_id` is incremented inside `libspdm_process_encapsulated_response` at line 159. The `cur_op_after` / `request_id_after` fields must be captured AFTER this increment. The pre-action `request_id` field must be captured BEFORE the call to `libspdm_process_encapsulated_response`.

### 3.5 Instrumentation Library

Use `libspdm_debug_print` or a dedicated NDJSON writer (e.g., `fprintf(trace_file, "{...}\n")`) gated on a compile-time `LIBSPDM_TRACE_ENCAP` flag. Do not use the existing `LIBSPDM_DEBUG` macro as it produces non-parseable output.

### 3.6 No Parallelism

libspdm is single-threaded. No timebox or ViablePIDs logic is needed (Category A trace). Events appear in strict protocol order.
