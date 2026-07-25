# Instrumentation Spec: libspdm Secured Messaging

Produced by spec generation for trace validation of `Trace.tla`.  
Category A (Distributed / Message-Passing): single linear NDJSON trace per test run.

---

## Section 1: Trace Event Schema

### Event Envelope

Every NDJSON line is a JSON object with this top-level structure:

```json
{
  "event":  "<event_name>",
  "node":   "requester" | "responder",
  "dir":    "request" | "response",
  "state":  { <state snapshot fields> },
  "msg":    { <message fields, if applicable> }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `event` | string | Event name (see Section 2) |
| `node` | string | Which endpoint emits the event: `"requester"` or `"responder"` |
| `dir` | string | Message direction: `"request"` (Requester→Responder) or `"response"` |
| `state` | object | Snapshot of the emitting endpoint's relevant state AFTER the operation |
| `msg` | object | Message fields (omitted for state-only events) |

### State Fields (captured at every event)

The `state` object contains the following fields, captured **after** the operation at the emitting endpoint:

| JSON field | TLA+ variable / expression | Source |
|------------|---------------------------|--------|
| `state.seq` | `seq[node][dir]` | `application_secret.request_data_sequence_number` or `response_data_sequence_number` |
| `state.active_epoch` | `active_epoch[node][dir]` | Abstract key epoch (see note below) |
| `state.backup_valid` | `backup_valid[node][dir]` | `requester_backup_valid` / `responder_backup_valid` |
| `state.backup_seq` | `backup_seq[node][dir]` | `application_secret_backup.request_data_sequence_number` (only when `backup_valid` is true) |
| `state.backup_epoch` | `backup_epoch[node][dir]` | abstract backup epoch (see note) |
| `state.update_phase` | `update_phase` | Synthesized from caller context (see note) |
| `state.initiator_committed` | `initiator_committed` | Synthesized flag (see Section 3) |

> **Note on abstract epoch**: The implementation uses key bytes, not an integer epoch. For tracing, instrument a thread-local counter `uint32_t key_epoch` that increments each time `libspdm_create_update_session_data_key` is called for the given direction. Export this counter as `active_epoch` / `backup_epoch`. This maps to the spec's integer epoch exactly.

> **Note on update_phase**: There is no single `update_phase` field in the implementation. Synthesize it in the harness using a test-scope global variable that is updated at each key-update event (see Section 3).

### Message Fields

The `msg` object is included for encode/decode events and key-update control messages:

| JSON field | TLA+ message field | Description |
|------------|-------------------|-------------|
| `msg.epoch` | `m.epoch` | Key epoch used to encrypt/MAC this message |
| `msg.seq` | `m.seq` | Sequence number in the A_DATA header |
| `msg.session_id_ok` | `m.session_id_ok` | TRUE unless session_id mismatch was detected |
| `msg.aead_ok` | `m.aead_ok` | TRUE if AEAD verification succeeded |
| `msg.all_keys` | `m.all_keys` | TRUE for UPDATE_ALL_KEYS operation |

---

## Section 2: Action-to-Code Mapping

### `encode_advance_seq`

| Field | Value |
|-------|-------|
| Spec action | `EncodeAdvanceSeq(d)` |
| Code location | `libspdm_secmes_encode_decode.c:171–183` |
| Trigger point | After `request_data_sequence_number++` / `response_data_sequence_number++`, before the AEAD key/IV derivation |
| State snapshot | `seq`, `active_epoch`, `backup_valid` for the direction being encoded |
| msg fields | `epoch` (current active epoch), `seq` (the incremented value) |
| Notes | One event per call to `libspdm_encode_secured_message`; fire regardless of whether AEAD subsequently succeeds. |

---

### `encode_success`

| Field | Value |
|-------|-------|
| Spec action | `EncodeSuccess(d)` |
| Code location | `libspdm_secmes_encode_decode.c:232–242` (ENC_MAC) / `libspdm_secmes_encode_decode.c:293–302` (MAC_ONLY) |
| Trigger point | After successful return from `libspdm_aead_encryption` / HMAC computation, before returning to caller |
| State snapshot | `seq`, `active_epoch` |
| msg fields | `epoch`, `seq`, `session_id_ok=true`, `aead_ok=true` |
| Notes | Only fire when AEAD/HMAC succeeds. If AEAD fails, fire `encode_aead_fail` instead (not modeled in current spec — AEAD failure on encode is uncommon in practice; instrument if needed). |

---

### `decode_increment_seq`

| Field | Value |
|-------|-------|
| Spec action | `DecodeIncrementSeq(m)` |
| Code location | `libspdm_secmes_encode_decode.c:414–426` |
| Trigger point | Immediately after `request_data_sequence_number++` / `response_data_sequence_number++` in the decode path |
| State snapshot | `seq` (post-increment), `active_epoch`, `backup_valid` |
| msg fields | `epoch` (from message A_DATA), `seq` (from message header, pre-increment), `session_id_ok` (not yet checked; set TRUE), `aead_ok` (not yet checked; set TRUE) |
| Notes | **This event fires unconditionally**, even when the subsequent session_id or AEAD check fails. The harness must capture the raw message fields from the incoming buffer before any validation. Failure events (`decode_session_id_fail`, `decode_aead_fail`) are separate events fired after this one. |

---

### `decode_success`

| Field | Value |
|-------|-------|
| Spec action | `DecodeSuccess(m)` |
| Code location | `libspdm_secmes_encode_decode.c:538–548` (ENC_MAC) / `libspdm_secmes_encode_decode.c:636–648` (MAC_ONLY) |
| Trigger point | After AEAD/HMAC verification succeeds and plain_text is validated, before returning `LIBSPDM_STATUS_SUCCESS` |
| State snapshot | `seq`, `active_epoch` |
| msg fields | `epoch`, `seq`, `session_id_ok=true`, `aead_ok=true` |

---

### `decode_session_id_fail`

| Field | Value |
|-------|-------|
| Spec action | `DecodeSessionIdFail(m)` |
| Code location | `libspdm_secmes_encode_decode.c:444–453` (ENC_MAC) / `libspdm_secmes_encode_decode.c:557–563` (MAC_ONLY) |
| Trigger point | After `record_header1->session_id != session_id` check fails |
| State snapshot | `seq` (already incremented by `decode_increment_seq`), `active_epoch` |
| msg fields | `epoch`, `seq` (from A_DATA), `session_id_ok=false`, `aead_ok=false` |
| Notes | Only fires when the session_id mismatch error is returned. The preceding `decode_increment_seq` event will already have been emitted for this decode call. |

---

### `decode_aead_fail`

| Field | Value |
|-------|-------|
| Spec action | `DecodeAEADFail(m)` |
| Code location | `libspdm_secmes_encode_decode.c:523–533` (ENC_MAC, `!result` + `!backup_valid`) / `libspdm_secmes_encode_decode.c:627–630` (MAC_ONLY equivalent) |
| Trigger point | After AEAD verification fails AND `backup_valid = false` (returns `LIBSPDM_STATUS_CRYPTO_ERROR`) |
| State snapshot | `seq`, `active_epoch`, `backup_valid=false` |
| msg fields | `epoch`, `seq`, `session_id_ok=true`, `aead_ok=false` |

---

### `decode_aead_fail_backup`

| Field | Value |
|-------|-------|
| Spec action | `DecodeAEADFailWithBackup(m)` |
| Code location | `libspdm_secmes_encode_decode.c:523–533` (ENC_MAC, `!result` + `backup_valid = true`) |
| Trigger point | After AEAD fails AND `backup_valid = true` (returns `LIBSPDM_STATUS_SESSION_TRY_DISCARD_KEY_UPDATE`) |
| State snapshot | `seq`, `active_epoch`, `backup_valid=true`, `backup_epoch`, `backup_seq` |
| msg fields | `epoch`, `seq`, `session_id_ok=true`, `aead_ok=false` |
| Notes | Caller will proceed to trigger the rollback-retry loop. The `responder_try_discard_key_update` event fires from the outer receive handler, not from inside `decode`. |

---

### `create_update_responder_key`

| Field | Value |
|-------|-------|
| Spec action | `CreateUpdateResponderKey` |
| Code location | `libspdm_req_key_update.c:111–122` (call to `libspdm_create_update_session_data_key(RESPONDER)`) |
| Trigger point | After `libspdm_create_update_session_data_key` returns TRUE for the responder direction |
| State snapshot | `active_epoch[Requester][ResponseDir]`, `backup_epoch[Requester][ResponseDir]`, `backup_valid[Requester][ResponseDir]=true`, `backup_seq[Requester][ResponseDir]`, `seq[Requester][ResponseDir]=0` |
| msg fields | (none) |
| Notes | The `node` field is always `"requester"` and `dir` is `"response"` for this event. |

---

### `send_key_update_request`

| Field | Value |
|-------|-------|
| Spec action | `SendKeyUpdateRequest(all_keys)` |
| Code location | `libspdm_req_key_update.c:131–140` (after `libspdm_send_spdm_request` returns) |
| Trigger point | After the KEY_UPDATE message is sent successfully |
| State snapshot | `seq[Requester][RequestDir]`, `update_phase="PendingAck"` |
| msg fields | `epoch`, `seq`, `all_keys` (TRUE if `SPDM_KEY_UPDATE_OPERATIONS_UPDATE_ALL_KEYS`) |

---

### `responder_receive_key_update`

| Field | Value |
|-------|-------|
| Spec action | `ResponderReceiveKeyUpdate(m)` |
| Code location | `libspdm_rsp_key_update_ack.c:147–216` |
| Trigger point | After creating/activating the new keys and before sending KEY_UPDATE_ACK |
| State snapshot | `active_epoch[Responder][RequestDir]`, `active_epoch[Responder][ResponseDir]`, `backup_valid[Responder][RequestDir]`, `seq[Responder][RequestDir]` |
| msg fields | `epoch` (of incoming KEY_UPDATE), `seq`, `all_keys` |

---

### `requester_receive_key_update_ack`

| Field | Value |
|-------|-------|
| Spec action | `RequesterReceiveKeyUpdateAck(m)` |
| Code location | `libspdm_req_key_update.c:171–216` |
| Trigger point | After `libspdm_activate_update_session_data_key(REQUESTER, true)` and before sending VERIFY_NEW_KEY |
| State snapshot | `active_epoch[Requester][RequestDir]`, `backup_valid[Requester][RequestDir]=false` (no backup – immediate commit), `initiator_committed=true`, `seq[Requester][RequestDir]=0` (reset) |
| msg fields | `epoch` (of KEY_UPDATE_ACK), `seq`, `all_keys` |
| Notes | **This is the CommitPoint** (Family 2). The spec sets `initiator_committed = TRUE` in this action. The harness `initiator_committed` flag must be set here and cleared on `requester_receive_verify_ack`. |

---

### `responder_receive_verify_new_key`

| Field | Value |
|-------|-------|
| Spec action | `ResponderReceiveVerifyNewKey(m)` |
| Code location | `libspdm_rsp_key_update_ack.c:194–216` |
| Trigger point | After `libspdm_activate_update_session_data_key(REQUESTER, true)` and before sending VERIFY_ACK |
| State snapshot | `active_epoch[Responder][RequestDir]`, `backup_valid[Responder][RequestDir]=false`, `seq[Responder][RequestDir]`, `update_phase="Idle"` |
| msg fields | `epoch` (of VERIFY_NEW_KEY), `seq` |

---

### `responder_try_discard_key_update`

| Field | Value |
|-------|-------|
| Spec action | `ResponderTryDiscardKeyUpdate(m)` |
| Code location | `libspdm_rsp_receive_send.c:197–264` (TRY_DISCARD handler, rollback path) |
| Trigger point | After `libspdm_activate_update_session_data_key(REQUESTER, false)` (rollback) returns |
| State snapshot | `active_epoch[Responder][RequestDir]` (restored to backup), `backup_valid[Responder][RequestDir]=false`, `seq[Responder][RequestDir]` (restored from `backup_seq`) |
| msg fields | `epoch` (of the failed VERIFY_NEW_KEY), `seq` |
| Notes | `initiator_committed` is still TRUE at this point on the requester side – this is the Family 2 / MC1 window. |

---

### `requester_receive_verify_ack`

| Field | Value |
|-------|-------|
| Spec action | `RequesterReceiveVerifyAck(m)` |
| Code location | `libspdm_req_key_update.c:290–314` |
| Trigger point | After validating VERIFY_ACK response fields and before returning SUCCESS |
| State snapshot | `update_phase="Idle"`, `initiator_committed=false`, `seq[Requester][ResponseDir]` |
| msg fields | `epoch`, `seq` |

---

### `encap_create_activate_rsp_key`

| Field | Value |
|-------|-------|
| Spec action | `EncapCreateAndActivateRspKey` |
| Code location | `libspdm_rsp_encap_key_update.c:79–98` |
| Trigger point | After `libspdm_activate_update_session_data_key(RESPONDER, true)` returns (immediate commit, no backup window) |
| State snapshot | `active_epoch[Responder][ResponseDir]`, `backup_valid[Responder][ResponseDir]=false`, `seq[Responder][ResponseDir]=0`, `is_encap=true`, `update_phase="PendingVerify"` |
| msg fields | (none) |
| Notes | **Family 3**: backup_valid is FALSE here because create+activate are called back-to-back with no intervening state. The `is_encap` flag must be set in the harness-scope state. |

---

### `requester_handle_response_not_ready`

| Field | Value |
|-------|-------|
| Spec action | `RequesterHandleResponseNotReady(m)` |
| Code location | `libspdm_req_send_receive.c:218–313` |
| Trigger point | After rollback (`activate_update(false)`) and re-create (`create_update`) complete, before retrying the send |
| State snapshot | `active_epoch[Requester][RequestDir]`, `backup_valid[Requester][RequestDir]`, `backup_seq[Requester][RequestDir]`, `seq[Requester][ResponseDir]` (incremented from NOT_READY decode) |
| msg fields | `epoch` (of NOT_READY response), `seq` |
| Notes | **Family 4**: capture `backup_seq` AFTER the re-create; this is the N+1 value that may diverge from the remote's expectation. |

---

## Section 3: Special Considerations

### Abstract Key Epoch Counter

The implementation uses raw cryptographic key bytes; the spec uses integer epochs. The harness must maintain a per-direction epoch counter alongside the secured message context:

```c
typedef struct {
    uint32_t req_epoch;  /* increments each create_update(REQUESTER) */
    uint32_t rsp_epoch;  /* increments each create_update(RESPONDER) */
    uint32_t req_backup_epoch;
    uint32_t rsp_backup_epoch;
} spdm_trace_epoch_t;
```

Instrument `libspdm_create_update_session_data_key` to increment the appropriate counter and store the backup before overwriting.

### Synthesized `update_phase`

There is no `update_phase` variable in the implementation. The harness must track it via a test-scope global:
- Set to `"PendingAck"` when `send_key_update_request` fires.
- Set to `"PendingVerify"` when `requester_receive_key_update_ack` fires.
- Set to `"Idle"` when `requester_receive_verify_ack` or `responder_try_discard_key_update` fires.
- For encap flow: set to `"PendingVerify"` when `encap_create_activate_rsp_key` fires; set to `"Idle"` when `responder_receive_encap_verify_ack` fires.

### Synthesized `initiator_committed`

Track as a boolean in the test harness. Set to TRUE at `requester_receive_key_update_ack` (requester activate-no-rollback window). Set to FALSE at `requester_receive_verify_ack` (update complete).

For the encap flow: set to TRUE at `encap_create_activate_rsp_key`.

### Trace Event Ordering

In a single-session, single-threaded test, events are totally ordered. The harness must emit events in the order operations occur within a single execution thread. For multi-session tests, add a `session_id` field to the envelope and filter in the Trace spec by session.

### `decode_increment_seq` Event Granularity

The decode path increments seq before any validation. The harness must instrument the increment site directly (not a wrapper function), so that `decode_increment_seq` fires even when the message is subsequently rejected. The subsequent failure event (`decode_session_id_fail`, `decode_aead_fail`, etc.) follows as the next NDJSON line.

### MAC_ONLY vs ENC_MAC Paths

Both session types (`LIBSPDM_SESSION_TYPE_ENC_MAC` and `LIBSPDM_SESSION_TYPE_MAC_ONLY`) share the same event names since the spec models them identically. Instrument both branches with the same event names. Add an optional `session_type` field to the msg object for debugging if needed.

### Event Pairs: `decode_increment_seq` → failure/success

Every decode call emits exactly one `decode_increment_seq` event followed by exactly one of:
- `decode_success`
- `decode_session_id_fail`
- `decode_aead_fail`
- `decode_aead_fail_backup`

The harness must guarantee this pairing. If the decode function returns early for size checks (before the seq increment at line 414), do NOT emit `decode_increment_seq`.
