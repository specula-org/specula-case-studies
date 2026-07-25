# Instrumentation Spec: libspdm Session Lifecycle

Action-to-code mapping for harness generation.  
Spec: `base.tla` / `Trace.tla`  
Target: libspdm C library (SPDM 1.1–1.3 post-handshake session management)

---

## Section 1: Trace Event Schema

### Event Envelope

Every trace event is a JSON object (one per line, NDJSON) with the following top-level fields:

```json
{
  "event":   "<event_name>",
  "state":   { ... },
  "msg":     { ... }   // present only for message-send/recv events
}
```

### State Snapshot Fields

Captured at every event (post-action unless noted). These map to TLA+ variables:

| JSON field              | TLA+ variable          | C source                                                                  | Notes                                    |
|-------------------------|------------------------|---------------------------------------------------------------------------|------------------------------------------|
| `req_session_state`     | `req_session_state`    | `session_info->secured_message_context` session state (requester side)    | String: `"ESTABLISHED"` or `"NOT_STARTED"` |
| `rsp_session_state`     | `rsp_session_state`    | `session_info->secured_message_context` session state (responder side)    | String: `"ESTABLISHED"` or `"NOT_STARTED"` |
| `req_ku_state`          | `req_ku_state`         | Local state in `libspdm_try_key_update` based on which phase is active    | String: `"idle"`, `"update_sent"`, `"verify_sent"` |
| `rsp_last_key_op`       | `rsp_last_key_op`      | `session_info->last_key_update_request.header.param1`                     | String: `"none"`, `"update_key"`, `"update_all_keys"` |
| `req_tx_gen`            | `req_tx_gen`           | Generation counter derived from `application_secret` TX slot (requester)  | Integer; increment on each `activate(new=true)` |
| `rsp_rx_gen`            | `rsp_rx_gen`           | Generation counter derived from `application_secret` RX slot (responder)  | Integer; increment on each `create_update` |
| `rsp_rx_backup_valid`   | `rsp_rx_backup_valid`  | Whether `application_secret_backup` is populated (responder RX)           | Boolean |
| `end_session_sent`      | `end_session_sent`     | Whether requester has sent END_SESSION in this session                     | Boolean |
| `end_session_ack_encoded` | `end_session_ack_encoded` | Whether responder successfully encoded END_SESSION_ACK                | Boolean |
| `watchdog_active`       | `watchdog_active`      | Whether platform watchdog timer is running                                 | Boolean |

### Message Fields (event-specific)

Present only on send/recv events, nested under `"msg"`:

| JSON field  | Description                              |
|-------------|------------------------------------------|
| `mtype`     | Message type string (matches spec constant name) |
| `param1`    | `spdm_message_header_t.param1` value     |
| `param2`    | `spdm_message_header_t.param2` (tag/nonce) |

---

## Section 2: Action-to-Code Mapping

### ReqSendUpdateKey

| Field           | Value |
|-----------------|-------|
| Spec action     | `ReqSendUpdateKey` |
| Trace event     | `req_send_update_key` |
| Code location   | `library/spdm_requester_lib/libspdm_req_key_update.c:124` |
| Trigger point   | After `libspdm_send_spdm_request` returns success (line 124–128), before acquiring receiver buffer |
| State captured  | Full state snapshot (post-send) |
| Msg captured    | `mtype="UPDATE_KEY"`, `param1=SPDM_KEY_UPDATE_OPERATIONS_UPDATE_KEY`, `param2` from request |
| Notes           | `single_direction=true` path; no `create_update` before send on this path |

---

### ReqSendUpdateAllKeys

| Field           | Value |
|-----------------|-------|
| Spec action     | `ReqSendUpdateAllKeys` |
| Trace event     | `req_send_update_all_keys` |
| Code location   | `library/spdm_requester_lib/libspdm_req_key_update.c:124` |
| Trigger point   | After `libspdm_send_spdm_request` success, `single_direction=false` branch |
| State captured  | Full state snapshot; capture `rsp_rx_backup_valid=true` (set at line 115–122) |
| Msg captured    | `mtype="UPDATE_ALL_KEYS"`, `param1=SPDM_KEY_UPDATE_OPERATIONS_UPDATE_ALL_KEYS` |
| Notes           | `create_update(RESPONDER)` runs at lines 111–122 before send; snapshot taken after |

---

### RspRecvUpdateKey

| Field           | Value |
|-----------------|-------|
| Spec action     | `RspRecvUpdateKey` |
| Trace event     | `rsp_recv_update_key` |
| Code location   | `library/spdm_responder_lib/libspdm_rsp_key_update_ack.c:138` |
| Trigger point   | After `libspdm_copy_mem(prev_spdm_request, ...)` at line 137–138 |
| State captured  | Full state snapshot; `rsp_last_key_op="update_key"`, `rsp_rx_gen` incremented, `rsp_rx_backup_valid=true` |
| Msg captured    | None (responder side, after request processed) |
| Notes           | Capture before `libspdm_generate_response` sends ACK; `rsp_rx_gen` counter is a shadow field (see §3) |

---

### RspRecvUpdateAllKeys

| Field           | Value |
|-----------------|-------|
| Spec action     | `RspRecvUpdateAllKeys` |
| Trace event     | `rsp_recv_update_all_keys` |
| Code location   | `library/spdm_responder_lib/libspdm_rsp_key_update_ack.c:190` |
| Trigger point   | After `libspdm_copy_mem(prev_spdm_request, ...)` at lines 189–191 |
| State captured  | `rsp_last_key_op="update_all_keys"`, `rsp_rx_backup_valid=true`, `rsp_tx_gen` incremented |
| Msg captured    | None |
| Notes           | `activate(RESPONDER, new=true)` at lines 179–187 commits TX; snapshot after that |

---

### ReqRecvKeyUpdateAck

| Field           | Value |
|-----------------|-------|
| Spec action     | `ReqRecvKeyUpdateAck` |
| Trace event     | `req_recv_key_update_ack` |
| Code location   | `library/spdm_requester_lib/libspdm_req_key_update.c:210` |
| Trigger point   | After `activate(REQUESTER, new=true)` at line 210–215 |
| State captured  | `req_tx_gen` incremented, `req_ku_state="verify_sent"` (send immediately follows) |
| Msg captured    | None |
| Notes           | In the `single_direction=false` path, `activate(RESPONDER, new=true)` at lines 184–194 also fires; capture after both activates |

---

### RspRecvVerifyNewKey

| Field           | Value |
|-----------------|-------|
| Spec action     | `RspRecvVerifyNewKey` |
| Trace event     | `rsp_recv_verify_new_key` |
| Code location   | `library/spdm_responder_lib/libspdm_rsp_key_update_ack.c:216` |
| Trigger point   | After `libspdm_zero_mem(prev_spdm_request, ...)` at line 215–216 |
| State captured  | `rsp_last_key_op="none"`, `rsp_rx_backup_valid=false` |
| Msg captured    | None |
| Notes           | `activate(REQUESTER, new=true)` at lines 201–213 discards backup; zero of `prev_spdm_request` follows |

---

### ReqRecvVerifyAck

| Field           | Value |
|-----------------|-------|
| Spec action     | `ReqRecvVerifyAck` |
| Trace event     | `req_recv_verify_ack` |
| Code location   | `library/spdm_requester_lib/libspdm_req_key_update.c:313` |
| Trigger point   | After successful response validation (line 305–312), before `libspdm_release_receiver_buffer` |
| State captured  | `req_ku_state="idle"` |
| Msg captured    | None |

---

### DecodeWithBackupKey

| Field           | Value |
|-----------------|-------|
| Spec action     | `DecodeWithBackupKey` |
| Trace event     | `rsp_decode_with_backup_key` |
| Code location   | `library/spdm_responder_lib/libspdm_rsp_receive_send.c:263` |
| Trigger point   | After `libspdm_create_update_session_data_key(REQUESTER)` at line 255–263 (re-derive completes) |
| State captured  | `rsp_rx_gen` incremented, `rsp_rx_backup_valid=true`, `rsp_last_key_op` unchanged (NOT reset) |
| Msg captured    | None |
| Notes           | This event is only emitted when `reset_key_update=true` (line 229) AND the re-derive at 255–263 succeeds. The harness must check `reset_key_update` flag at line 249. |

---

### ReqSendEndSession

| Field           | Value |
|-----------------|-------|
| Spec action     | `ReqSendEndSession` |
| Trace event     | `req_send_end_session` |
| Code location   | `library/spdm_requester_lib/libspdm_req_end_session.c:90` |
| Trigger point   | After `libspdm_send_spdm_request` returns success for END_SESSION |
| State captured  | `end_session_sent=true`, session state still ESTABLISHED |
| Msg captured    | `mtype="END_SESSION"` |

---

### RspRecvEndSession

| Field           | Value |
|-----------------|-------|
| Spec action     | `RspRecvEndSession` |
| Trace event     | `rsp_recv_end_session` |
| Code location   | `library/spdm_responder_lib/libspdm_rsp_end_session_ack.c:50` |
| Trigger point   | After request validation in `libspdm_get_response_end_session`, before response build |
| State captured  | Session states unchanged |
| Msg captured    | None |

---

### RspEncodeEndSessionAckSuccess

| Field           | Value |
|-----------------|-------|
| Spec action     | `RspEncodeEndSessionAckSuccess` |
| Trace event     | `rsp_encode_end_session_ack_success` |
| Code location   | `library/spdm_responder_lib/libspdm_rsp_receive_send.c:792` |
| Trigger point   | After `libspdm_terminate_session` call at line 792 (only on success path) |
| State captured  | `rsp_session_state="NOT_STARTED"`, `end_session_ack_encoded=true`, `watchdog_active=false` |
| Msg captured    | `mtype="END_SESSION_ACK"` |
| Notes           | Only emit this event if `transport_encode_message` returned success (line 779 branch). If it failed, emit no event (harness detects via return value). |

---

### ReqRecvEndSessionAck

| Field           | Value |
|-----------------|-------|
| Spec action     | `ReqRecvEndSessionAck` |
| Trace event     | `req_recv_end_session_ack` |
| Code location   | `library/spdm_requester_lib/libspdm_req_end_session.c:141` |
| Trigger point   | After `libspdm_free_session_id` at line 141 (req session freed) |
| State captured  | `req_session_state="NOT_STARTED"` |
| Msg captured    | None |
| Notes           | **CRITICAL**: `session_info` pointer is invalid after line 141. Do NOT dereference `session_info` after this point in the harness. Capture all needed fields before line 141. |

---

### ReqSendHeartbeat

| Field           | Value |
|-----------------|-------|
| Spec action     | `ReqSendHeartbeat` |
| Trace event     | `req_send_heartbeat` |
| Code location   | `library/spdm_requester_lib/libspdm_req_heartbeat.c:90` |
| Trigger point   | After `libspdm_send_spdm_request` success for HEARTBEAT |
| State captured  | Session state snapshot |
| Msg captured    | `mtype="HEARTBEAT"` |

---

### RspRecvHeartbeat

| Field           | Value |
|-----------------|-------|
| Spec action     | `RspRecvHeartbeat` |
| Trace event     | `rsp_recv_heartbeat` |
| Code location   | `library/spdm_responder_lib/libspdm_rsp_heartbeat.c:100` |
| Trigger point   | After watchdog reset in `libspdm_build_response` (rsp_receive_send.c:800–805), before ACK response |
| State captured  | `watchdog_active=true`, `watchdog_expired=false` |
| Msg captured    | None |

---

### ReqRecvHeartbeatAck

| Field           | Value |
|-----------------|-------|
| Spec action     | `ReqRecvHeartbeatAck` |
| Trace event     | `req_recv_heartbeat_ack` |
| Code location   | `library/spdm_requester_lib/libspdm_req_heartbeat.c:130` |
| Trigger point   | After successful response validation |
| State captured  | Session state snapshot |
| Msg captured    | None |

---

## Section 3: Special Considerations

### Key Generation Counters Are Shadow Fields

libspdm does not expose an integer key-generation counter. The harness must maintain shadow counters:
- `req_tx_gen`: increment each time `libspdm_activate_update_session_data_key(REQUESTER, new=true)` is called on the requester side.
- `rsp_rx_gen`: increment each time `libspdm_create_update_session_data_key(REQUESTER)` is called on the responder side.
- `rsp_tx_gen`: increment each time `libspdm_activate_update_session_data_key(RESPONDER, new=true)` is called on the responder.

A hook on these function calls (or the `libspdm_trigger_key_update_callback`) is the recommended instrument point.

### rsp_last_key_op Mapping

`session_info->last_key_update_request` is a `spdm_key_update_request_t` struct. The relevant field is `header.param1`:
- `0` → `"none"`
- `SPDM_KEY_UPDATE_OPERATIONS_UPDATE_KEY (1)` → `"update_key"`
- `SPDM_KEY_UPDATE_OPERATIONS_UPDATE_ALL_KEYS (2)` → `"update_all_keys"`

### Pointer Invalidation After libspdm_free_session_id

At `req_end_session.c:141`, `libspdm_free_session_id` re-initializes the session slot. The `session_info` pointer captured before this call becomes a dangling reference. The harness must capture all state snapshot fields **before** `libspdm_free_session_id` (at or before line 136), then emit the event after line 141.

### DecodeWithBackupKey Detection

The rollback path at `rsp_receive_send.c:197–263` is triggered when `transport_decode_message` returns `LIBSPDM_STATUS_SESSION_TRY_DISCARD_KEY_UPDATE`. The harness must:
1. Detect this return value at line 197.
2. Track the `reset_key_update` flag (line 229).
3. Emit `rsp_decode_with_backup_key` only after the re-derive at line 255–263 succeeds.

### Watchdog Events Are Not Directly Observable

`libspdm_stop_watchdog` and `libspdm_reset_watchdog` are platform stubs. The harness must instrument these stub functions or the callback registration points to capture watchdog state. If the platform doesn't support this, `WatchdogExpiry` and `IntegratorTerminatesSession` will fire as silent actions in trace validation.

### Heartbeat Period Negotiation

`heartbeat_period == 0` causes both `req_heartbeat.c:63–65` and `rsp_heartbeat.c:99–103` to reject HEARTBEAT with `UNEXPECTED_REQUEST`. The harness test scenarios should use `heartbeat_period > 0`; if `heartbeat_period == 0`, skip HEARTBEAT events.

### Bootstrap / Initial State

Traces begin with the session already in ESTABLISHED state (post-handshake). `TraceInit` in `Trace.tla` matches this by using the base `Init` which sets both sides to ESTABLISHED.
