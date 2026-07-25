# Instrumentation Spec: libspdm-secured-message

## Section 1: Trace Event Schema

### Common Event Envelope

Every trace event is a JSON object with:

```json
{
  "event": "<event-name>",
  "role": "requester" | "responder",
  "session_id": "<sid>",
  "timestamp": <unix_ns>,
  "state": { /* see State Fields */ },
  "message": { /* event-specific fields */ }
}
```

### State Fields (Captured at Every Event)

| Implementation Field | TLA+ Variable | Capture Method |
|---|---|---|
| `session_state` | `session_state[role][sid]` | Direct read from context |
| `request_seq_num` | `request_seq_num[role][sid]` | Direct read from context |
| `response_seq_num` | `response_seq_num[role][sid]` | Direct read from context |
| `sequence_number_endian` | `seq_num_endian[role][sid]` | Direct read from context |
| `endian_determined_at` | `endian_determined_at[role][sid]` | Shadow variable (initialized -1, set when determined) |
| `key_update_phase` | `key_update_phase[role][sid]` | Direct read from context struct |
| `backup_valid` | `backup_valid[role][sid]` | Boolean flag in context |
| `application_secret` (current) | `application_secret[role][sid]` | Symbolic ID (e.g. "key_0", "key_v1") |
| `application_secret_backup` | `application_secret_backup[role][sid]` | Symbolic ID |
| `secrets_cleared` | `secrets_cleared[role][sid]` | Zeroization completion flag |

---

## Section 2: Action-to-Code Mapping

### 1. TransitionToEstablished

**Spec Action**: `TransitionToEstablished(role, sid)`

**Code Location**: 
- `libspdm_secmes_context_data.c:30-44` (libspdm_secured_message_set_session_state with ESTABLISHED)

**Trigger Point**: After line 37 (state = ESTABLISHED), before line 41 (clear_handshake_secret call)

**Trace Event Name**: `transition_to_established`

**Fields to Capture**:
- `session_state_before`: state before transition (should be HANDSHAKING)
- `session_state_after`: state after (should be ESTABLISHED)
- `secrets_cleared_after`: FALSE (zeroization not yet complete)

**Notes**:
- Transition is non-atomic per Family 3. Capture moment between state assignment and secret clearing.
- This is the logical transition phase; physical zeroization follows in CompleteZeroization.

---

### 2. CompleteZeroization

**Spec Action**: `CompleteZeroization(role, sid)`

**Code Location**:
- `libspdm_secmes_context_data.c:41-42` (libspdm_clear_handshake_secret, libspdm_clear_master_secret calls)
- `libspdm_secmes_session.c:467-480` (libspdm_clear_handshake_secret implementation)

**Trigger Point**: After all zero_mem calls complete in clear_handshake_secret

**Trace Event Name**: `complete_zeroization`

**Fields to Capture**:
- `session_state`: ESTABLISHED
- `secrets_cleared_before`: FALSE
- `secrets_cleared_after`: TRUE

**Notes**:
- Models the physical phase of zeroization.
- Verify that handshake_secret and master_secret are indeed zeroed (shadow flag in context).

---

### 3. EncodeSecuredMessage

**Spec Action**: `EncodeSecuredMessage(role, sid)`

**Code Location**:
- `libspdm_secmes_encode_decode.c:63-200+` (libspdm_encode_secured_message)

**Trigger Point**: After line 173 or 179 (sequence number increment), before function return

**Trace Event Name**: `encode_message`

**Fields to Capture**:
- `sequence_number_before`: request_seq_num before increment
- `sequence_number_after`: request_seq_num after increment
- `key_used`: which key (symbolic ID from application_secret)
- `iv_value`: computed IV (capture from IV generation)
- `cipher_text_size`: size of encrypted message

**Notes**:
- Trace the sequence number increment explicitly (Family 4).
- Capture IV to verify determinism (Family 5).

---

### 4. AttemptDecodeFirstEndian

**Spec Action**: `AttemptDecodeFirstEndian(role, sid)`

**Code Location**:
- `libspdm_secmes_encode_decode.c:487-521` (decode path, ENC_MAC mode)
- `libspdm_secmes_encode_decode.c:593-623` (decode path, MAC_ONLY mode)

**Trigger Point**: At line 487-492 (endianness determination attempt), after deciding on first endian

**Trace Event Name**: `decode_first_endian`

**Fields to Capture**:
- `response_seq_num_before`: response_seq_num before processing
- `response_seq_num_after`: response_seq_num after increment
- `endian_attempted`: which endianness was tried first
- `endian_determined`: final endian choice (after first successful decryption)
- `endian_determined_at_seq`: sequence number at which endian was locked in
- `decryption_success`: true/false

**Notes**:
- Family 1 vulnerability: capture the moment endianness is determined.
- If seq=1 and endianness is undetermined (BOTH variant), this action must fire.
- If both decryption attempts succeed/fail ambiguously, trace should reflect that (potential trap).

---

### 5. InitiateKeyUpdate

**Spec Action**: `InitiateKeyUpdate(role, sid)`

**Code Location**:
- `libspdm_secmes_session.c:357-407` (libspdm_create_update_session_data_key)
- Line 407: `requester_backup_valid = true` or `responder_backup_valid = true`

**Trigger Point**: After line 407 (backup_valid flag set)

**Trace Event Name**: `initiate_key_update`

**Fields to Capture**:
- `key_update_phase_before`: IDLE
- `key_update_phase_after`: PENDING
- `backup_valid_after`: TRUE
- `application_secret_backup`: old key value saved
- `application_secret_new`: new derived key

**Notes**:
- Family 2: capture the moment backup is marked valid.
- Both requester and responder sides must eventually initiate (for KU synchronization).

---

### 6. ConfirmKeyUpdate

**Spec Action**: `ConfirmKeyUpdate(role, sid)`

**Code Location**:
- `libspdm_secmes_session.c:408-459` (implicit: when both sides have used new key successfully)

**Trigger Point**: After both sides have sent/received one message with new key

**Trace Event Name**: `confirm_key_update`

**Fields to Capture**:
- `key_update_phase_before`: PENDING
- `key_update_phase_after`: CONFIRMED
- `backup_valid_before`: TRUE
- `backup_valid_after`: FALSE
- `application_secret_backup_cleared`: set to null

**Notes**:
- Family 2: confirm transition clears backup.
- In the real implementation, this is implicit (determined by successful message exchange).
- Instrumentation should infer this when both peers have completed PENDING->CONFIRMED transition.

---

### 7. RollbackToBackupKey

**Spec Action**: `RollbackToBackupKey(role, sid)`

**Code Location**:
- `libspdm_secmes_encode_decode.c:525-527` (decode path when backup_valid and decryption fails)

**Trigger Point**: When decryption fails with new key and backup_valid is true, before rollback

**Trace Event Name**: `rollback_backup_key`

**Fields to Capture**:
- `key_update_phase_before`: PENDING
- `key_update_phase_after`: IDLE (or ROLLBACK if modeling as separate phase)
- `application_secret_before`: new key
- `application_secret_after`: old key (restored from backup)
- `backup_valid_after`: remains TRUE initially (until confirmed or timed out)

**Notes**:
- Family 2: silent rollback is the vulnerability.
- Capture the moment rollback decision is made and old key is restored.

---

## Section 3: Special Considerations

### Implementation-Specific Details

1. **Endianness Enum Values**:
   - `LIBSPDM_DATA_SESSION_SEQ_NUM_ENC_LITTLE_DEC_LITTLE` -> `LITTLE_ENC_LITTLE`
   - `LIBSPDM_DATA_SESSION_SEQ_NUM_ENC_BIG_DEC_BIG` -> `BIG_ENC_BIG`
   - `LIBSPDM_DATA_SESSION_SEQ_NUM_ENC_LITTLE_DEC_BOTH` -> `LITTLE_ENC_BOTH`
   - `LIBSPDM_DATA_SESSION_SEQ_NUM_ENC_BIG_DEC_BOTH` -> `BIG_ENC_BOTH`

2. **Symbolic Key Representation**:
   - Keys are large binary objects. Model as symbolic IDs: `key_0`, `key_v1`, `key_v2`, etc.
   - Use counter or version suffix to distinguish key generations.

3. **Session Context Structure**:
   - Session state is in `libspdm_secured_message_context_t` (internal header).
   - Instruments must access this via getters or direct struct access (if exposed).

4. **Multi-Peer Consideration**:
   - Each session has requester and responder roles.
   - Events are tagged with (role, session_id) for differentiation.
   - For Family 2 (key update desync), ensure both peers' transitions are captured.

5. **Bootstrap State**:
   - Initial state: session_state = INIT, all seq_nums = 0, endian = LITTLE_ENC_BOTH.
   - This matches Init in the base spec.

6. **Sequence Number Constraints**:
   - Check `sequence_number >= max_spdm_session_sequence_number` before each operation.
   - If violated, session transitions to CLOSED (Family 4).

### Trace File Format

Traces are NDJSON (one JSON object per line):

```
{"event": "transition_to_established", "role": "requester", "session_id": "sid1", "timestamp": 1000, "state": {...}, "message": {...}}
{"event": "complete_zeroization", "role": "requester", "session_id": "sid1", "timestamp": 1010, "state": {...}, "message": {...}}
...
```

### Capture Timing

- **Before-action snapshot**: capture state at line before key operation (e.g., before seq_num increment).
- **After-action snapshot**: capture state after operation completes (e.g., after seq_num increment).
- For split operations (Family 1, 2, 3), capture intermediate snapshots to expose non-atomicity.

---

## Section 4: Verification Checklist

- [ ] All 7 spec actions have corresponding code locations
- [ ] All state variables are captured in the trace
- [ ] Endianness determination (Family 1) captured at seq=1
- [ ] Key update phases (Family 2) captured for all state transitions
- [ ] Session state transition (Family 3) captured with zeroization completion flag
- [ ] Sequence number increments (Family 4) captured before and after
- [ ] IV computation (Family 5) captured for determinism validation
- [ ] TraceLog can be deserialized from JSON file
- [ ] Post-state validation matches captured fields
