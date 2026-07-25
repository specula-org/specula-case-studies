# Instrumentation Spec: libspdm KEY_EXCHANGE / FINISH

Maps each TLA+ spec action to the source code location(s) that must be instrumented to produce compatible traces for `Trace.tla`.

---

## Section 1: Trace Event Schema

### Common Event Envelope

Every event is a single NDJSON line (one JSON object per line):

```json
{
  "event":      "<event_name>",
  "session_id": <int>,   // 1-based session slot index (0 if not yet allocated)
  // ... event-specific fields below
}
```

### State Fields (captured per-event)

| JSON field | TLA+ variable | C expression | Notes |
|---|---|---|---|
| `session_state` | `session_state[s]` | `session_info->session_state` (cast to string) | Map: `NOT_STARTED`="not_started", `HANDSHAKING`="handshaking", `ESTABLISHED`="established" |
| `latest_session_id` | `latest_session_id` | `spdm_context->latest_session_id` | Session slot index (0 = none) |
| `peer_cert_slot` | `peer_cert_slot[s]` | `session_info->peer_used_cert_chain_slot_id` | 0 = not set |
| `cert_advertised` | `cert_advertised[s]` | req_slot_id from KEY_EXCHANGE message | Only on rsp_handle_key_exchange event |
| `mut_auth_mode` | `mut_auth_mode[s]` | derived from `LIBSPDM_RESPONSE_MUTUAL_AUTH_REQUESTED` bits | Map: 0="none", bit0="non_encap", bit1="encap" |
| `data_keys_live` | `data_keys_live[s]` | `session_info->secured_message_context->application_secret.request_data_secret != NULL` | Boolean |
| `expected_seq` | `expected_seq[s]` | `session_info->secured_message_context->application_secret.request_data_sequence_number` | After update |
| `hitc` | `hitc_negotiated[s]` | `(session_info->session_type == LIBSPDM_SESSION_TYPE_ENC_HANDSHAKE)` ? false : true | Boolean |

### Ghost / Abstract Fields

These fields are not directly read from C; they are computed by the harness from surrounding context:

| JSON field | TLA+ ghost variable | How to compute |
|---|---|---|
| `auth_session` | `finish_authenticated_for[s]` | The session_id the requester used when sending FINISH (harness tracks this from context) |
| `finish_authenticated_for` | `finish_authenticated_for[s]` | Set by harness to `auth_session` of the FINISH message that triggered RspDeriveDataKeys |
| `cert_slot_verified` | `cert_slot_verified[s]` | Value of `peer_used_cert_chain_slot_id` read by the verify functions in rsp_finish_rsp.c |
| `seq_before_advance` | `seq_before_advance[s]` | Value of sequence number counter BEFORE it is incremented in `libspdm_decode_secured_message` |

---

## Section 2: Action-to-Code Mapping

### 1. `req_send_key_exchange`

| Field | Value |
|---|---|
| **Spec action** | `ReqSendKeyExchange(hitc, req_slot, mode)` |
| **Code location** | `library/spdm_requester_lib/libspdm_req_key_exchange.c` — entry of `spdm_send_receive_key_exchange_ex` (approx. line 100) |
| **Trigger point** | After constructing KEY_EXCHANGE request, before `libspdm_send_spdm_request` |
| **Event name** | `"req_send_key_exchange"` |

**Fields to capture:**
```json
{
  "event": "req_send_key_exchange",
  "session_id": 0,
  "hitc": <bool>,
  "req_slot_id": <int>,
  "mode": "<none|non_encap|encap>"
}
```

**Notes:** `session_id` is 0 here (session not yet allocated by responder). `hitc` is derived from `spdm_request_attribute` containing `SPDM_KEY_EXCHANGE_REQUEST_ATTRIBUTE_HANDSHAKE_IN_THE_CLEAR_REQUESTED`. `mode` is the mutual-auth mode the requester requests.

---

### 2. `rsp_handle_key_exchange`

| Field | Value |
|---|---|
| **Spec action** | `RspHandleKeyExchange(m, s)` |
| **Code location** | `library/spdm_responder_lib/libspdm_rsp_key_exchange.c` — after `libspdm_assign_session_id` returns (line ~230), before response buffer is finalized |
| **Trigger point** | After both the session allocation AND the conditional `peer_used_cert_chain_slot_id` write (line ~575); capture post-state |

**Fields to capture:**
```json
{
  "event": "rsp_handle_key_exchange",
  "session_id": <int>,
  "hitc": <bool>,
  "req_slot_id": <int>,
  "mode": "<none|non_encap|encap>",
  "latest_session_id": <int>,
  "session_state": "handshaking",
  "peer_cert_slot": <int>,
  "cert_advertised": <int>,
  "mut_auth_mode": "<none|non_encap|encap>"
}
```

**Notes:**
- `session_id` is the newly allocated slot index (from `libspdm_assign_session_id` return value; libspdm_com_context_data_session.c:221).
- `peer_cert_slot` will be 0 for non-encap (the bug), or `req_slot_id` for encap (libspdm_rsp_key_exchange.c:575).
- Emit this event AFTER line 575 so both branches are reflected.

---

### 3. `req_send_finish`

| Field | Value |
|---|---|
| **Spec action** | `ReqSendFinish(key_ex_rsp, auth_session)` |
| **Code location** | `library/spdm_requester_lib/libspdm_req_finish.c` — after FINISH message is constructed, before `libspdm_send_spdm_request` (approx. line 400) |
| **Trigger point** | After MAC/signature is computed and FINISH buffer is ready |

**Fields to capture:**
```json
{
  "event": "req_send_finish",
  "session_id": <int>,
  "session_id_valid": <bool>,
  "auth_session": <int>,
  "req_slot_id": <int>
}
```

**Notes:**
- `auth_session` = the session_id this FINISH was computed for (= `session_id` in normal cases).
- `session_id_valid` = FALSE if HANDSHAKE_IN_THE_CLEAR (cleartext FINISH path).
- `req_slot_id` = the requester cert slot used to sign the FINISH.

---

### 4. `rsp_derive_data_keys`

| Field | Value |
|---|---|
| **Spec action** | `RspDeriveDataKeys(m)` |
| **Code location** | `library/spdm_responder_lib/libspdm_rsp_finish_rsp.c` — after `libspdm_generate_session_data_key` at line 744, before returning |
| **Trigger point** | After successful key derivation (line 744 returns OK) |

**Fields to capture:**
```json
{
  "event": "rsp_derive_data_keys",
  "session_id": <int>,
  "session_id_valid": <bool>,
  "auth_session": <int>,
  "req_slot_id": <int>,
  "session_state": "keys_derived",
  "data_keys_live": true,
  "cert_slot_verified": <int>,
  "finish_authenticated_for": <int>,
  "latest_session_id": <int>
}
```

**Notes:**
- `session_id` = the resolved target session (from `latest_session_id` if HITC, else from header).
- `cert_slot_verified` = value of `session_info->peer_used_cert_chain_slot_id` as read by `libspdm_verify_finish_req_signature` (rsp_finish_rsp.c:153).
- `finish_authenticated_for` = `auth_session` (the session whose keys verified the MAC, from the FINISH message context).
- Capturing `latest_session_id` here helps diagnose F1 scenarios.

**Critical:** Emit this event AFTER `libspdm_generate_session_data_key` succeeds. If the call fails, emit `rsp_encode_failure` instead.

---

### 5. `rsp_commit_established`

| Field | Value |
|---|---|
| **Spec action** | `RspCommitEstablished(finish_rsp, s_derive)` |
| **Code location (HITC path)** | `library/spdm_responder_lib/libspdm_rsp_receive_send.c:817-820` — after `libspdm_transport_encode_message` succeeds |
| **Code location (non-HITC path)** | `library/spdm_responder_lib/libspdm_rsp_receive_send.c:771-773` — after encode succeeds |
| **Trigger point** | After `libspdm_set_session_state(ESTABLISHED)` call |

**Fields to capture:**
```json
{
  "event": "rsp_commit_established",
  "session_id": <int>,
  "session_state": "established",
  "latest_session_id": <int>
}
```

**Notes:**
- `session_id` = the slot that was just marked ESTABLISHED (the argument to `libspdm_set_session_state`).
- For HITC path: `session_id` = `spdm_context->latest_session_id` at line 817 (this may differ from the session that processed the FINISH — the F1 bug).
- Capturing `latest_session_id` alongside `session_id` allows trace validation to detect divergence.

---

### 6. `rsp_encode_failure`

| Field | Value |
|---|---|
| **Spec action** | `RspEncodeFailure(s)` |
| **Code location** | `library/spdm_responder_lib/libspdm_rsp_finish_rsp.c:738-763` — error return paths after `libspdm_calculate_th2_hash` or `libspdm_generate_session_data_key` failure |
| **Trigger point** | When these functions return an error status (before function returns) |

**Fields to capture:**
```json
{
  "event": "rsp_encode_failure",
  "session_id": <int>,
  "session_state": "keys_derived",
  "data_keys_live": <bool>
}
```

**Notes:**
- Only emitted on error paths (F3 fault scenario).
- This event is typically only seen in fault-injection test scenarios (TV1).
- `data_keys_live` may be TRUE if `libspdm_generate_session_data_key` failed AFTER partial key setup, or FALSE if `libspdm_calculate_th2_hash` failed before key derivation.

---

### 7. `req_send_app_data`

| Field | Value |
|---|---|
| **Spec action** | `ReqSendAppData(s, authentic)` |
| **Code location** | Requester application layer — before `libspdm_send_receive_data` |
| **Trigger point** | After application-data message is encrypted (application keys used) |

**Fields to capture:**
```json
{
  "event": "req_send_app_data",
  "session_id": <int>,
  "seq_num": <int>,
  "authentic": true
}
```

**Notes:**
- `authentic` = TRUE for all legitimate requester messages.
- `seq_num` = the sequence number included in the secured message header.

---

### 8. `rsp_decode_secured_message`

| Field | Value |
|---|---|
| **Spec action** | `RspDecodeSecuredMessage(m)` |
| **Code location** | `library/spdm_secured_message_lib/libspdm_secmes_encode_decode.c` — at line ~420 (sequence counter increment) and line 477 (AEAD call) |
| **Trigger point** | After AEAD completes (success or failure) — capture both pre- and post-counter values |

**Fields to capture:**
```json
{
  "event": "rsp_decode_secured_message",
  "session_id": <int>,
  "seq_num": <int>,
  "authentic": <bool>,
  "seq_before_advance": <int>,
  "expected_seq": <int>,
  "last_decode_rejected": <bool>
}
```

**Notes:**
- `seq_before_advance` = sequence counter value BEFORE increment (line ~419).
- `expected_seq` = sequence counter value AFTER increment (line ~420).
- `last_decode_rejected` = TRUE if AEAD returned an error (line 477).
- To capture `seq_before_advance`, add a local variable save before the increment:
  ```c
  uint64_t seq_before = secured_message_context->application_secret.request_data_sequence_number;
  // ... existing increment code (line ~420) ...
  // ... AEAD (line 477) ...
  emit_trace("rsp_decode_secured_message", session_id, seq_num, aead_result, seq_before, ...);
  ```
- The F4 bug is observable when `last_decode_rejected=true` AND `expected_seq != seq_before_advance`.

---

## Section 3: Special Considerations

### 3.1 Session Slot Indexing

libspdm uses session IDs (opaque 32-bit values) internally but the TLA+ spec uses 1-based slot indices (1..MaxSessions). The harness must map between them.

The mapping: `spdm_context->session_info[i]` corresponds to TLA+ slot `i+1` (0-based C array to 1-based TLA+ slots). The `session_id` field in trace events should use the TLA+ slot index, not the libspdm session_id value.

Alternatively, use the index returned by `libspdm_get_session_info_via_session_id` to find the array index.

### 3.2 HITC Detection

A session uses HANDSHAKE_IN_THE_CLEAR when:
```c
session_info->session_type != LIBSPDM_SESSION_TYPE_ENC_HANDSHAKE
```
or equivalently, when the `SPDM_KEY_EXCHANGE_REQUEST_ATTRIBUTE_HANDSHAKE_IN_THE_CLEAR_REQUESTED` bit was set in the KEY_EXCHANGE request.

The harness should read `session_info->session_type` when emitting events.

### 3.3 Mutual Auth Mode Detection

Map `MutualAuthRequested` bits from the KEY_EXCHANGE_RSP:
- `0x00`: `MUT_NONE` — no mutual auth
- `0x01` (bit 0 set): `MUT_NON_ENCAP` — non-encapsulated slot-id method
- `0x02` (bit 1 set): `MUT_ENCAP` — encapsulated certificate exchange

### 3.4 Ghost Field: `auth_session`

`auth_session` is not directly visible in the C code — it represents which session the requester computed the FINISH MAC for. The harness must track this by correlating:
1. Which session_id was in the KEY_EXCHANGE_RSP the requester received
2. Using that as `auth_session` in the FINISH event

In a test harness, this is available from the requester state; in the responder-only harness, it must be computed from the FINISH request payload's session context.

### 3.5 Trace File Location

Trace files (`.ndjson`) are stored in:
```
experiments/model-sensitivity/runs/sonnet/full/libspdm-key-exchange/traces/
```

The `Trace.tla` default path is `../traces/trace.ndjson`. Override with `IOEnv.JSON`:
```bash
tlc -config Trace.cfg -DJSON=../traces/my_trace.ndjson Trace.tla
```

### 3.6 F4 Instrumentation — Two Probe Points

For `rsp_decode_secured_message`, two probe points are needed in `libspdm_secmes_encode_decode.c`:
1. Before sequence counter increment (~line 419): save `seq_before`
2. After AEAD call (line 477): read AEAD result

These cannot be collapsed into one probe point because the counter increment and AEAD call are separate statements. Emit the event after the AEAD call using both captured values.
