# Modeling Brief: libspdm-secured-message

## 1. System Overview

**System**: libspdm-secured-message (C)  
**Reference**: SPDM DSP0277 Secured Messages v1.0-1.2  
**Category**: **Category A (Distributed / Message-Passing)**  
**Justification**: This is a protocol implementation for encoding/decoding SPDM secured messages with cryptographic safeguards. The core logic involves message-passing semantics (encode/decode handlers), sequence number management, and cryptographic state transitions. Correctness relies on protocol-specific invariants, not concurrent memory access patterns.

**Scale**: ~100KB core logic (3 primary files)

**Architecture**: Single-threaded library providing:
- Message encoding/decoding with AEAD encryption
- Session key derivation and management
- Key update with rollback mechanism
- Endian-independent sequence number handling

**Key Deviations from Reference**:
- Runtime endianness determination for sequence numbers (TLS-inspired but not in base spec)
- Backup-key rollback mechanism for key updates (DVT of forward progress)
- Multiple endianness variants (LITTLE_DEC_LITTLE, LITTLE_DEC_BOTH, BIG_DEC_BIG, BIG_DEC_BOTH)

**Concurrency Model**: Single-threaded; no internal locks or async operations. All state transitions are synchronous. The library is thread-safe only if callers serialize access per session.

---

## 2. Bug Families

### Family 1: Sequence Number Endianness Determination Race

**Mechanism**: The code determines sequence number endianness at runtime by attempting decryption with two candidate endianness encodings (lines 487-521 in libspdm_secmes_encode_decode.c, decode path). On first message (seq=0), endianness is ambiguous (same encoding in both). On second message (seq=1), it tries one endianness; if decryption fails, it swaps and retries. **If both attempts succeed or both fail**, the code accepts the first result without cross-validation, potentially locking in the wrong endianness for the entire session.

**Evidence**:
- Code analysis: libspdm_secmes_encode_decode.c:487-521 (ENC_MAC), 593-623 (MAC_ONLY)
- Condition: `!is_sequence_number_endian_determined(...) && (sequence_number == 1)`
- Issue: No consensus mechanism; unilateral acceptance of first-succeeded result

**Affected code paths**:
- `libspdm_decode_secured_message()` - both ENC_MAC and MAC_ONLY session types
- Called when receiving second message in a session

**Suggested modeling approach**:
- **Variables**: `sequence_number_endian` (current), attempted endianness pair, decryption outcome flags
- **Actions**: 
  - `DecodeMessage` splits into `AttemptFirstEndian` and `AttemptSecondEndian`
  - Invariant: once determined, endianness must remain fixed for session
  - Add trap: if second message decryption outcome is ambiguous (both succeed or both fail), session enters ERROR state
- **Granularity**: Separate decode-endian-determined action from main decode

**Priority**: High  
**Rationale**: 
- Bug density: Endianness is negotiated implicitly and determined unilaterally at runtime; no explicit agreement.
- TLA+ suitability: Pure protocol logic; no crypto oracle needed. Model endianness as a variable and check single-assignment.
- Severity: If wrong endianness is locked in, all subsequent IVs are incorrect → auth failures on all future messages.
- Evidence: Code explicitly documents this is a problem ("Attempting to determine endianness" lines 490-491)

---

### Family 2: Non-Atomic Key Update and Backup Validity Window

**Mechanism**: Key update requires saving old key state (lines 357-407 in libspdm_secmes_session.c) before deriving new keys. After save, `requester_backup_valid` or `responder_backup_valid` is set to true (line 407, 459). However, the encode/decode path (libspdm_secmes_encode_decode.c:525-527) assumes backup validity correlates with key freshness:
- If decryption fails AND backup is valid → return `SESSION_TRY_DISCARD_KEY_UPDATE` (rollback hint)
- If backup not valid → return `CRYPTO_ERROR` (permanent failure)

**The window**: Between `create_update_session_data_key()` returning and the caller checking/acting on backup_valid, the session state is inconsistent — new key is active, backup is marked valid, but the peer may not have adopted the update yet. If a message arrives before the peer synchronizes, decryption fails, and the code **silently rolls back to the old key**. If the peer also rolls back, both agree; if peer committed to new key, both disagree until re-sync.

**Evidence**:
- Code analysis: libspdm_secmes_session.c:357-407, 408-459 (save phase)
- Code analysis: libspdm_secmes_encode_decode.c:525-527 (rollback condition)
- Decoupling: `backup_valid` flag is set *after* key derivation, not atomically with peer coordination

**Affected code paths**:
- `libspdm_create_update_session_data_key()` - creates backup and new key
- `libspdm_activate_update_session_data_key()` - finalizes or rolls back
- `libspdm_decode_secured_message()` - reads backup_valid and may silently rollback
- Interaction: No explicit state transition synchronization between peers

**Suggested modeling approach**:
- **Variables**:
  - `application_secret` (current)
  - `application_secret_backup` + `backup_valid` flag
  - Key update phase: IDLE → PENDING → CONFIRMED → IDLE
- **Actions**:
  - `CreateKeyUpdate` (both sides): saves old, derives new, marks PENDING
  - `ConfirmKeyUpdate` (both sides): moves to CONFIRMED after both peers send/recv one message with new key
  - `DecodeMessage` (during PENDING): if decryption fails with new key, fall back to old key + log rollback intent
  - Invariant: backup is only valid in PENDING state; if both sides in PENDING, they must have same old key
- **Granularity**: Split key update into explicit phases rather than silent auto-rollback

**Priority**: High  
**Rationale**:
- Bug density: Key update is a common operation; potential for desynchronization is inherent to the split-state design.
- TLA+ suitability: Excellent; pure protocol logic, no crypto needed.
- Severity: Desynchronization can cause message loss (both sides reject each other's messages) or key confusion (accepting messages with wrong key).
- Evidence: Return code `SESSION_TRY_DISCARD_KEY_UPDATE` is explicit acknowledgment that this scenario exists.

---

### Family 3: Session State Transition Non-Atomicity

**Mechanism**: Transition from HANDSHAKING to ESTABLISHED (libspdm_secmes_context_data.c:39-43) performs three steps:
1. Set `session_state = ESTABLISHED` (line 37)
2. Call `libspdm_clear_handshake_secret()` (line 41)
3. Call `libspdm_clear_master_secret()` (line 42)

Each is a separate function call with no atomic guarantee. Between step 1 and step 2, if another thread (or async callback) calls `libspdm_encode_secured_message()`, it will:
- See `session_state = ESTABLISHED` (line 110-112: assertions pass)
- Select application keys (line 137-151)
- But handshake secrets are still in memory, not yet cleared

**While single-threaded operation is assumed, the design does not prevent accidental concurrent calls**, and the zeroization of handshake secrets is a security property that could be violated.

**Evidence**:
- Code analysis: libspdm_secmes_context_data.c:39-43
- Code analysis: libspdm_secmes_session.c:467-480 (clear_handshake_secret calls zero_mem 3 times)
- Non-atomic observation: State change visible immediately; clear operations follow

**Affected code paths**:
- `libspdm_secured_message_set_session_state()` with `ESTABLISHED` parameter
- Any encode/decode during the clearing window

**Suggested modeling approach**:
- **Variables**: session_state, zeroization_complete flag
- **Actions**:
  - `TransitionToEstablished`: atomic set (state, zeroization_complete) to (ESTABLISHED, false) then async clear
  - `PerformZeroization`: completes the clear, sets zeroization_complete = true
  - Invariant: Encode/Decode only allowed if (state ≠ ESTABLISHED OR zeroization_complete)
- **Granularity**: Split state transition into logical and physical phases

**Priority**: Medium  
**Rationale**:
- Bug density: Happens once per session (at end of handshake).
- TLA+ suitability: Moderate; requires modeling of async operations or explicit sequencing.
- Severity: Breaks forward secrecy if handshake secret is exposed; primarily a side-channel concern, not protocol correctness.
- Evidence: Code explicitly calls libspdm_zero_mem; implies developers considered this important.

---

### Family 4: Sequence Number Overflow Silent Boundary

**Mechanism**: Both encode and decode check `if (sequence_number >= max_spdm_session_sequence_number)` and return `SEQUENCE_NUMBER_OVERFLOW` (libspdm_secmes_encode_decode.c:159-161, 399-403). However:
1. The check uses `>=`, not `==`, so overflow at exactly `max_spdm_session_sequence_number` is rejected.
2. After increment (line 173, 179, 416, 422, 416, 422), the sequence number can reach `max_spdm_session_sequence_number` (last valid) and then overflow to 0 or beyond, depending on uint64_t wraparound.
3. No check exists *after* increment; only before operation.

**The issue**: If sequence number reaches `max - 1`, the next encode increments to `max`. The subsequent encode will check `max >= max` and reject. But if a message is pending during this transition, and the peer is at `max - 1`, they might not be synchronized; one side rejected, the other accepted.

**Evidence**:
- Code analysis: libspdm_secmes_encode_decode.c:159-161 (encode check), 173-183 (encode increment)
- Code analysis: libspdm_secmes_encode_decode.c:399-403 (decode check), 414-426 (decode increment)
- Asymmetry: Check before operation; increment after operation

**Affected code paths**:
- `libspdm_encode_secured_message()` - checks then increments
- `libspdm_decode_secured_message()` - checks then increments

**Suggested modeling approach**:
- **Variables**: request_sequence_number, response_sequence_number, max_sequence_number
- **Actions**:
  - `SendMessage`: check `seq < max`, then increment; if at boundary, transition to SESSION_CLOSED or similar
  - `ReceiveMessage`: check `seq < max`, then increment; if at boundary, **must match sender's boundary transition**
- **Invariant**: After either side reaches max, session must enter closed state; no further messages allowed
- **Granularity**: Boundary checking and state transition as one atomic action

**Priority**: Medium  
**Rationale**:
- Bug density: Happens at the very end of a session's lifetime (64-bit counter).
- TLA+ suitability: Good; state machine logic.
- Severity**: Moderate; impacts long-lived sessions. DSP0277 allows for sequence number updates, but this code has a hard limit.
- Evidence: Explicit check for overflow; suggests developers intended to prevent it, but did not handle transition.

---

### Family 5: IV Generation from Sequence Number — Endian-Dependent Correctness

**Mechanism**: Function `generate_iv()` (libspdm_secmes_encode_decode.c:9-42) XORs salt with sequence number, with different code paths for little-endian vs big-endian:
- Little-endian (line 23-26): copy sequence_number to iv_temp, XOR from index 0
- Big-endian (line 32-39): byte-swap sequence_number, copy to `iv_temp + (aead_iv_size - 8)`, XOR from that offset

**The risk**: If sequence_number_endian is misinterpreted (see Family 1), the IV will be computed incorrectly for the misinterpreted endianness. Since IV is critical input to AEAD, an incorrect IV means:
- Encryption produces a different ciphertext (not detectable until decryption)
- Decryption with wrong IV fails auth tag verification

**This is a consequence of Family 1**, but it manifests here as a correctness property: once endianness is chosen, every message must use it consistently.

**Evidence**:
- Code analysis: libspdm_secmes_encode_decode.c:9-42 (generate_iv)
- Code analysis: libspdm_secmes_encode_decode.c:163-164 (encode calls generate_iv), 405-406 (decode calls generate_iv)
- Dependency: `endian` parameter is `secured_message_context->sequence_number_endian`

**Affected code paths**:
- `libspdm_encode_secured_message()` - all messages use generate_iv
- `libspdm_decode_secured_message()` - all messages use generate_iv

**Suggested modeling approach**:
- **Variables**: `sequence_number_endian`, `iv`
- **Actions**:
  - `ComputeIV(seq_num, salt, endian) -> iv`: pure function, can be inlined in TLA+
  - Invariant: For a given sequence number, salt, and endian, IV must be deterministic
  - Cross-check invariant: If endianness changes mid-session, all messages encrypted with old endian become unverifiable
- **Granularity**: Inline in encode/decode; no separate action

**Priority**: High (depends on Family 1 being resolved)  
**Rationale**:
- Bug density: Every message uses generate_iv; if endianness is wrong, all messages fail.
- TLA+ suitability: Excellent; pure deterministic computation.
- Severity: Critical; wrong IV = auth failure for all messages.
- Evidence: Explicit encoding for two endianness variants; no validation that chosen endian is correct.

---

### Family 6: Application Data Length Validation After Decryption

**Mechanism**: After AEAD decryption in ENC_MAC mode (libspdm_secmes_encode_decode.c:534-543):
1. Decrypt entire message
2. Read `enc_msg_header->application_data_length` from decrypted data (line 534)
3. Check `plain_text_size > cipher_text_size` (line 535)

**The issue**: The `application_data_length` field is decrypted, hence authenticated. However, the check `plain_text_size > cipher_text_size` is a bounds check, not a protocol check. If `application_data_length` is set to a value larger than the actual decrypted plaintext, the code rejects it. But the field itself is attacker-controllable (via AEAD auth forgery, if the attacker broke AEAD — not realistic in practice). **More critically**, there's no check that `cipher_text_size` actually holds the claimed `plain_text_size + random_padding`. The code blindly trusts the length field.

**Counterpoint / Mitigation**: AEAD provides authenticated encryption, so if the auth tag is valid, the plaintext is authentic. The application_data_length field is inside the ciphertext, so it's protected. The check is thus more of a sanity check than a security check. **Verdict**: Low risk, but worth modeling to verify AEAD semantics are preserved.

**Evidence**:
- Code analysis: libspdm_secmes_encode_decode.c:534-543 (ENC_MAC path)
- Code analysis: libspdm_secmes_encode_decode.c:227-228 (encode sets application_data_length)

**Affected code paths**:
- `libspdm_decode_secured_message()` - ENC_MAC session type

**Suggested modeling approach**:
- **Variables**: ciphertext_bytes, application_data_length, random_padding
- **Actions**:
  - `DecodeENCMAC`: verify `application_data_length + random_bytes == plaintext_length`
  - Invariant: If AEAD auth succeeds, plaintext must be structured correctly (header + data + padding)
- **Granularity**: Inline in decode logic; no separate action

**Priority**: Low  
**Rationale**:
- Bug density: Low; AEAD provides structural integrity.
- TLA+ suitability: Moderate; requires AEAD oracle.
- Severity**: Low; mitigated by AEAD auth.
- Evidence: Code includes the check; suggests defensive posture.

**Exclusion**: This family is more of a defensive programming observation. The risk is minimal given AEAD guarantees. Include as a test-verifiable finding, not a model-checkable one.

---

## 3. Modeling Recommendations

### 3.1 What to Model (with rationale)

| Item | Why | Approach |
|------|-----|----------|
| **Sequence number endianness determination** | Family 1: Unilateral decision at runtime without peer agreement can lock in wrong encoding. Endianness mismatch → IV mismatch → all future messages fail auth. | Model endianness as explicit state variable; add trap if both decryption attempts succeed/fail (ambiguous outcome). Use `sequence_number == 1` to trigger endian-determination action. Verify single-assignment. |
| **Key update state consistency** | Family 2: Backup mechanism allows silent rollback, but peer may not be in sync. Desynchronization causes message loss. | Model key update as explicit state machine: IDLE → PENDING (backup saved, new key active) → CONFIRMED (both peers agreed) → IDLE. Verify that backup rollback only occurs if peer has also rolled back (or pending). |
| **Sequence number overflow boundary** | Family 4: No explicit state transition when reaching max sequence number; one side may reject while other accepts. | Model sequence number as bounded; add explicit session-closed state when max is reached. Verify both sides transition simultaneously. |
| **Session state transition atomicity** | Family 3: Zeroization of handshake secrets is not atomic with state change. Forward secrecy property could be violated. | Model as two-phase: logical transition (state = ESTABLISHED) then physical transition (secrets_cleared = true). Verify that encoding only happens if secrets_cleared OR state ≠ ESTABLISHED. |
| **IV generation determinism** | Family 5: IV must be consistent for a given (seq, salt, endian) tuple. Wrong endian → wrong IV. | Inline deterministic function; verify no state corruption or key leakage through IV. Cross-check with Family 1 (endianness must be stable). |

### 3.2 What NOT to Model (with rationale)

| Item | Why |
|------|-----|
| **Cryptographic primitives (AEAD, HKDF)** | Crypto oracle; assume correct. Spec should call into `libspdm_aead_encryption()` as a black box. |
| **Random number generation** | Low entropy is checked (Family 6, line 194-196), but RNG is non-deterministic. Model randomness in tests; don't encode RNG logic in invariants. |
| **Actual key material values** | Keys are derived and used, but their values are not relevant to protocol correctness. Model keys as abstract quantities; use symbolic crypto semantics. |
| **Memory layout and buffer management** | Pointer arithmetic and alignment are implementation-specific. Not relevant to protocol logic. |
| **Endian conversion utilities** | byte_swap_64, copy_mem are correctness-preserving. Assume they work; focus on the logic that uses them. |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| `SeqNumEndianDetermined` | `sequence_number_endian`, `endian_determined_at_seq` | Track whether endianness has been locked in and at which sequence number. | Family 1 |
| `KeyUpdatePhase` | `key_update_phase` (IDLE/PENDING/CONFIRMED), `backup_valid`, `peer_update_phase` (inferred from message decryption) | Track whether both sides have agreed on key update. Separate from current binary `backup_valid` flag. | Family 2 |
| `SessionSequenceNumberMax` | `sequence_number`, `max_spdm_session_sequence_number` | Model boundary; add closed state when max is reached. | Family 4 |
| `SessionTransitionPhase` | `session_state`, `secrets_cleared` (boolean) | Separate logical state change from physical secret zeroization. | Family 3 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| **EndianStableAfterDetermination** | Safety | Once `sequence_number_endian` is determined (no longer BOTH variant), it never changes for the session. | Family 1 |
| **EndianDeterminationUnambiguous** | Safety | If `sequence_number == 1` and endianness must be determined, decryption attempts must not both succeed or both fail. If both succeed, session enters ERROR. | Family 1 |
| **IVDeterministic** | Safety | For a given (sequence_number, salt, endian), `generate_iv()` always produces the same IV. | Family 5 |
| **KeyUpdateSynchronized** | Liveness | Both peers must transition key update phase together. If one side creates backup, the other must see the update (or rollback occurs symmetrically). | Family 2 |
| **BackupValidConsistency** | Safety | If `backup_valid == true`, then a prior key update was initiated; `application_secret_backup` contains valid old key material. | Family 2 |
| **NoRollbackAfterConfirm** | Safety | Once key update is confirmed (both sides used new key), backup is cleared and rollback is impossible. | Family 2 |
| **SequenceNumberMonotonic** | Safety | Within a session, `request_data_sequence_number` (and all variants) are monotonically increasing. | Family 4 |
| **SequenceNumberBounded** | Safety | `sequence_number < max_spdm_session_sequence_number` at all times. Once max is reached, session transitions to CLOSED. | Family 4 |
| **SessionStateTransitionLinear** | Safety | State transitions follow: INIT → HANDSHAKING → ESTABLISHED. Each transition is unidirectional; no backward transitions. | General |
| **SecretsZeroizedAfterTransition** | Safety | If `session_state == ESTABLISHED` and `secrets_cleared == true`, then handshake_secret and master_secret are all zeros. | Family 3 |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable Findings

| ID | Description | Expected violation | Bug Family | Status |
|----|-------------|-------------------|-----------|--------|
| MC1 | If two consecutive decrypts at seq=1 both succeed with different endianness, does the spec choose consistently? | `EndianDeterminationUnambiguous` violated; two sessions lock in different endianness for the same (peer, salt) pair. | Family 1 | Open |
| MC2 | If requester initiates key update while responder sends a message with old key, can both sides deadlock? | `KeyUpdateSynchronized` violated; requester has new key active, responder has old key active; both sides' next message fails auth. | Family 2 | Open |
| MC3 | Can an attacker cause endianness to be determined incorrectly by causing first decryption to fail? | `EndianStableAfterDetermination` violated; endian swapped after single auth failure. | Family 1 | Open |
| MC4 | If sequence number approaches max and key update is initiated, can the overflow check be bypassed? | `SequenceNumberBounded` violated; seq wraps to 0 before session closed. | Family 4 | Open |
| MC5 | If session transitions to ESTABLISHED before secrets_cleared is set, can encode see handshake keys? | `SecretsZeroizedAfterTransition` violated; sensitive handshake material leaked to encoding path. | Family 3 | Open |

### 6.2 Test-Verifiable Findings

| ID | Description | Suggested test approach |
|----|-------------|------------------------|
| TV1 | Endianness determination: Craft two messages at seq=1 that decrypt correctly with different endianness. Does the implementation choose one consistently? | Fuzz: generate two different (salt, key, ciphertext) tuples that decrypt with opposite endianness. Verify only one is accepted per session. |
| TV2 | Key update rollback: Initiate key update, send message with new key, then send message with old key. Does it rollback or error? | Unit test: call `create_update`, encode with new key, decode with old key, verify `SESSION_TRY_DISCARD_KEY_UPDATE`. |
| TV3 | Sequence number at boundary (max - 1): Encode a message, verify next encode fails with OVERFLOW. | Unit test: set sequence_number to `max - 1`, encode succeeds, increment, next encode should fail. |
| TV4 | Secrets zeroization: After state transition to ESTABLISHED, verify handshake_secret and master_secret are actually zeroed in memory. | Unit test: read memory after `set_session_state(ESTABLISHED)`, verify all handshake bytes are 0x00. |

### 6.3 Code-Review-Only Findings

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR1 | Endianness enum usage: `LIBSPDM_DATA_SESSION_SEQ_NUM_ENC_LITTLE_DEC_BOTH` and `_ENC_BIG_DEC_BOTH` are "undecided" states. Why are both allowed after seq=1? Should one of the DEC_BOTH variants be rejected? | Review: Why two "both" variants? Can they be consolidated? Are they mutually exclusive? Document the semantics. |
| CR2 | Key update activation logic: `libspdm_activate_update_session_data_key(use_new_key)` allows rollback via `!use_new_key`. Who decides the value of `use_new_key`? If the caller chooses, can they choose incorrectly? | Review: Caller controls rollback decision; should this be automatic based on protocol state, not caller discretion? |
| CR3 | Max sequence number hardcoded: `max_spdm_session_sequence_number` is set during context initialization (line 66 in internal header). What happens if this is 0 or 1? Can it cause immediate overflow? | Review: Add validation that `max_spdm_session_sequence_number > 1`. Ensure it's not 0 (which would make all messages fail). |
| CR4 | Consttime comparison used for sequence number: Line 449, 562 use `libspdm_consttime_is_mem_equal()`. This is timing-safe, but the sequence number in the header is not secret; why constant-time? | Review: Is this a false-positive security measure, or is there a timing-side-channel risk that justifies it? Document intent. |

---

## 7. Reference Pointers

- **Core source files**:
  - `/library/spdm_secured_message_lib/libspdm_secmes_encode_decode.c` (encode/decode logic, endianness, key selection)
  - `/library/spdm_secured_message_lib/libspdm_secmes_session.c` (key generation, key update, state transitions)
  - `/library/spdm_secured_message_lib/libspdm_secmes_context_data.c` (session state initialization and transitions)
  - `/include/internal/libspdm_secured_message_lib.h` (context structure, state enums)

- **Protocol specification**:
  - DSP0277 SPDM Secured Messages v1.0.0 (referenced in source code headers)

- **Key data structures**:
  - `libspdm_secured_message_context_t` (lines 22-85 in internal header): Session context with keys, state, sequence numbers
  - `libspdm_session_info_struct_application_secret_t` (lines 41-50): Application secret with backup

---

## 8. Analysis Summary

This codebase implements a message-passing security protocol with several areas of subtle complexity:

1. **Endianness as an implicit negotiation**: The DSP0277 spec allows different endianness variants, and this code determines it at runtime. Without explicit peer coordination, there's a risk of disagreement.

2. **Key update as a distributed state machine**: The backup-key mechanism enables recovery from failed key updates, but requires careful synchronization. Asymmetry between peers can cause desynchronization.

3. **Session boundaries**: Sequence number overflow and session state transitions must be handled carefully to avoid races or state inconsistencies.

The recommended approach is to model these three areas explicitly in TLA+, using safety invariants to catch desynchronizations and liveness properties to ensure forward progress.

**Estimated spec complexity**: 
- Core state machine: ~150-200 lines TLA+
- Endianness handling: ~50-80 lines
- Key update state machine: ~80-120 lines
- Total: ~300-400 lines TLA+ for a comprehensive spec

**Model-checking scope**: 
- 2-3 sessions (requester, responder + trace scenarios)
- Sequence numbers bounded (e.g., 0-4, or smaller per session)
- Message ordering preserved (FIFO per direction)
