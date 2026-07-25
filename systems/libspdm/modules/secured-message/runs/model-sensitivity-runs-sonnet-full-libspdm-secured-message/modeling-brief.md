# Modeling Brief: libspdm Secured Messaging

## 1. System Overview

**System**: libspdm (DMTF/libspdm) — C implementation of the SPDM protocol (DSP0274/DSP0277)  
**Target subsystem**: `spdm_secured_message_lib` + requester/responder key-update handlers  
**Core LOC**: ~1,843 lines in `library/spdm_secured_message_lib/`; ~700 additional lines in key-update handlers  
**Category**: **Category A (Distributed / Message-Passing)**  
Justification: Two endpoints (Requester, Responder) exchange structured messages in a session; correctness depends on both sides agreeing on which key/sequence-number epoch is active, not on thread interleaving.

**Protocol implemented**: SPDM DSP0277 secured messaging — AEAD-protected messages with per-direction sequence numbers and a key-update (UPDATE_KEY / UPDATE_ALL_KEYS / VERIFY_NEW_KEY) sub-protocol.

**Key architectural decisions**:
- Sequence numbers are incremented **before** AEAD verification in the decode path.
- Key updates use a **create-then-backup / activate-with-rollback** pattern: `libspdm_create_update_session_data_key` installs the new key and saves the old one; `libspdm_activate_update_session_data_key(use_new_key)` either commits (clears backup) or reverts.
- When decryption fails and a backup key exists, `LIBSPDM_STATUS_SESSION_TRY_DISCARD_KEY_UPDATE` is returned; the caller rolls back keys, retries decode, then re-installs the new key ("create-rollback-recreate" loop).
- RESPONSE_NOT_READY creates a three-phase sequence in key update: create → rollback (to decode error) → re-create (for subsequent ACK).
- UPDATE_ALL_KEYS and UPDATE_KEY are handled by different code paths in the encap (responder-initiated) vs non-encap (requester-initiated) flows.

---

## 2. Bug Families

### Family 1: Sequence-Number Advance Before Validation / AEAD Verification

**Mechanism**: In `libspdm_decode_secured_message`, the session's expected sequence number is incremented unconditionally (lines 414–426) before the session_id field is checked (lines 444–453), and before AEAD decryption succeeds (lines 477–482 and 583–588). Any failure after the increment — session_id mismatch, sequence-num-in-header mismatch, AEAD tag failure — leaves the sequence counter permanently advanced with no recovery path for non-key-update failures.

**Evidence**:
- Historical: Issue #780 / PR #879 (fixed 2022-05): Sequence number NOT incremented for NOT_READY response inside a session caused subsequent exchanges to fail with sequence mismatch — confirms the sequence counter and RESPONSE_NOT_READY interaction is a historically bug-prone area
- Historical: Issue #2393 / PR #2396 (fixed 2023-10): Endianness detection at seq=0 was broken — the detection code was tied to when the sequence number first becomes non-trivially distinguishable, confirming sequence number handling is fragile around boundary conditions
- Code analysis: `libspdm_secmes_encode_decode.c:414–426` — sequence incremented unconditionally
- Code analysis: `libspdm_secmes_encode_decode.c:444–453` — session_id check after increment (ENC_MAC path)
- Code analysis: `libspdm_secmes_encode_decode.c:557–563` — session_id check after increment (MAC_ONLY path)
- Code analysis: `libspdm_secmes_encode_decode.c:523–533, 627–630` — `SESSION_TRY_DISCARD_KEY_UPDATE` is the only recovery path; it fires only when `backup_valid=true`, not for general validation failures
- Code analysis: `libspdm_secmes_encode_decode.c:171–183` — same pattern on encode side (increment before AEAD encrypt; AEAD failure leaves sequence advanced)

**Affected code paths**:
- `libspdm_decode_secured_message` (both ENC_MAC and MAC_ONLY branches)
- `libspdm_encode_secured_message` (ENC_MAC and MAC_ONLY branches)

**Suggested modeling approach**:
- Variables: explicit `seq_num` per direction per side; flag `seq_committed` (true only after successful AEAD)
- Actions: `DecodeAttempt` split into `IncrementSeq` + `AeadVerify`; `IncrementSeq` is always taken, `AeadVerify` may fail
- Granularity: model `IncrementSeq` and `AeadVerify` as separate steps to expose the gap

**Priority**: High  
**Rationale**: A single malformed or injected message (wrong session_id or corrupted sequence field, both of which exist in the unauthenticated A_DATA header) permanently breaks the session sequence counter. The backup/rollback recovery applies only in the key-update context, leaving the general case unprotected. TLA+ can determine whether any such state leads to session inoperability without a way for the peers to resynchronize.

---

### Family 2: Key Update State Machine — Backup/Commit/Rollback Consistency

**Mechanism**: The key update sub-protocol maintains per-direction backup keys (`application_secret_backup`) and validity flags (`requester_backup_valid`, `responder_backup_valid`). The invariant "both sides use the same active key" depends on: (a) the correct ordering of `create_update`, `activate_update`, and message exchange across both endpoints; (b) the commit point (VERIFY_NEW_KEY) being reached atomically from both sides' perspectives; and (c) the RESPONSE_NOT_READY re-create loop correctly reconstructing the same derived key.

**Evidence**:
- Code analysis: `libspdm_req_key_update.c:111–122` — requester creates NEW responder key **before** sending KEY_UPDATE; responder activates that key **before** sending ACK; there is a window where requester holds "pending" new responder key while the network is in flight
- Code analysis: `libspdm_req_key_update.c:199–216` — requester creates and immediately activates new requester key with no rollback window before sending VERIFY_NEW_KEY; any decode failure on responder triggers rollback on responder side but requester has already committed
- Code analysis: `libspdm_rsp_key_update_ack.c:193–216` — VERIFY_NEW_KEY activates requester key and clears backup; if VERIFY_NEW_KEY itself cannot be decoded (e.g., wrong key), `SESSION_TRY_DISCARD_KEY_UPDATE` fires after the requester has already committed; the two sides diverge
- Code analysis: `libspdm_req_send_receive.c:207–313` — TRY_DISCARD handler: rollback → retry decode → `reset_key_update=true` → re-create; the re-created key is `HKDF(old_secret)` which equals the first-try key (deterministic), but the backup sequence number now reflects an extra decode increment
- Code analysis: `libspdm_rsp_receive_send.c:197–264` — same pattern on responder side for the requester direction
- Code analysis: `libspdm_secmes_session.c:335–465` — `create_update` backs up current key+seq, installs new; `activate_update(false)` restores backup; `activate_update(true)` clears backup

**Affected code paths**:
- `libspdm_create_update_session_data_key` / `libspdm_activate_update_session_data_key`
- `libspdm_try_key_update` (requester side) — lines 77–226
- `libspdm_get_response_key_update` (responder side) — UPDATE_KEY, UPDATE_ALL_KEYS, VERIFY_NEW_KEY handlers
- Requester/responder `receive_spdm_response` / `receive_request` TRY_DISCARD handlers

**Suggested modeling approach**:
- Variables: `active_key[Requester|Responder][req_dir|rsp_dir]`, `backup_key[…]`, `backup_valid[…]`, `seq_num[…]`; state enum `{Idle, PendingAck, PendingVerify}` per update initiator
- Actions: `CreateUpdate`, `SendKeyUpdate`, `ReceiveKeyUpdate`, `SendAck`, `ReceiveAck`, `SendVerify`, `ReceiveVerify`, `Rollback`, `Commit`
- Granularity: model VERIFY_NEW_KEY as a two-action sequence (requester commits before sending; responder verifies after receiving) to expose the no-rollback window

**Priority**: High  
**Rationale**: The state machine involves three message types, four key objects, and two rollback paths across two endpoints. The VERIFY_NEW_KEY commit asymmetry (requester commits before responder confirms) is the highest-risk interaction point. TLA+ can exhaustively check whether the invariant "active keys match on both sides after any sequence of normal operations, errors, and rollbacks" holds.

---

### Family 3: Encap vs Non-Encap Key Update Asymmetry

**Mechanism**: The responder-initiated (encap) key update path differs structurally from the requester-initiated path. In the encap VERIFY_NEW_KEY phase (`libspdm_get_encap_request_key_update`), the responder calls `create_update` and immediately `activate_update(true)` on the response key — a create-then-immediately-commit with no rollback window — and then encrypts VERIFY_NEW_KEY with the new key. The non-encap path, by contrast, maintains a full backup window through VERIFY_NEW_KEY. If the requester cannot decode the encap VERIFY_NEW_KEY (wrong new key), there is no TRY_DISCARD path for the response direction on the encap flow.

Additionally, the encap flow disallows UPDATE_ALL_KEYS (returns error at `libspdm_req_encap_key_update_ack.c:115`), and the VERIFY_NEW_KEY precedent check in the encap responder handler (`libspdm_req_encap_key_update_ack.c:118`) only accepts UPDATE_KEY as the previous operation, while the non-encap responder (`libspdm_rsp_key_update_ack.c:194–199`) accepts both UPDATE_KEY and UPDATE_ALL_KEYS.

**Evidence**:
- Historical: Issue #3003 / PR #3083 (fixed 2025-06): Encapsulated KEY_UPDATE was missing session ID context — if multiple sessions existed, the wrong session's keys could be updated; confirms encap key update path has had real correctness bugs distinct from the non-encap path
- Code analysis: `libspdm_rsp_encap_key_update.c:79–98` — create+activate immediately before sending VERIFY_NEW_KEY
- Code analysis: `libspdm_req_encap_key_update_ack.c:118–131` — only UPDATE_KEY accepted as prior op; VERIFY_NEW_KEY activates responder key
- Code analysis: `libspdm_secmes_encode_decode.c:625–630` — TRY_DISCARD checks `responder_backup_valid`, which is false after immediate activate in the encap path

**Affected code paths**:
- `libspdm_get_encap_request_key_update` (responder sends encap request)
- `libspdm_get_encap_response_key_update` (requester handles encap request)
- `libspdm_process_encap_response_key_update` (responder processes ACK)

**Suggested modeling approach**:
- Add an `is_encap` flag; model two variants of the key update action set; check that both variants maintain the "active keys match" invariant under the same error conditions

**Priority**: Medium  
**Rationale**: The structural asymmetry (immediate commit in encap, backup window in non-encap) is an intentional design choice but creates an unverified assertion that the encap VERIFY_NEW_KEY is always deliverable. TLA+ can check whether the asymmetry introduces reachable states where the response key is permanently mismatched.

---

### Family 4: Sequence Number Epoch Consistency After Key Update + Rollback

**Mechanism**: When a key update occurs, sequence numbers reset to 0 for the new key epoch. Rollback (`activate_update(false)`) restores the backed-up sequence number. The backup is taken at `create_update` time, before any messages are exchanged on the new key. If a message is decoded on the new key (sequence advances from 0 to 1) and THEN rollback is triggered (from the `try_key_update` error path at `libspdm_req_key_update.c:167–182`), the restored backup sequence is the pre-update value, not the incremented one. Meanwhile, the TRY_DISCARD flow in `receive_spdm_response` (which handles RESPONSE_NOT_READY) rolls back and then re-creates, leaving the backup sequence at N+1 (incremented during the error message decode), not N (pre-update). Whether this N vs N+1 difference can cause a decode failure on the next attempt depends on whether the remote side's sequence matches.

**Evidence**:
- Historical: Issue #780 / PR #879 (fixed 2022-05): When NOT_READY response was sent inside a session, sequence number was not incremented, causing subsequent KEY_UPDATE exchanges to fail — confirms that the epoch boundary between "message with old key before update" and "message with new key after update" has historically produced sequence desync
- Historical: Issue #2318 / PR #2319 (fixed 2023-08): Session key export did not account for the `salt XOR sequence_number_delta` combination — the key+salt+seq triple was not treated as a single atomic backup unit, confirming that these three values must be backed up and restored together
- Code analysis: `libspdm_secmes_session.c:379–381` — backup saves seq at create time
- Code analysis: `libspdm_secmes_session.c:526–528` — rollback restores backup seq
- Code analysis: `libspdm_req_send_receive.c:218–223, 308–312` — rollback followed by re-create; backup seq updated to N+1 after successful decode of RESPONSE_NOT_READY

**Affected code paths**:
- `libspdm_create_update_session_data_key`, `libspdm_activate_update_session_data_key`
- Receive handlers in `libspdm_req_send_receive.c` and `libspdm_rsp_receive_send.c`

**Suggested modeling approach**:
- Track `backup_seq` explicitly alongside `backup_key`; check that rollback-then-re-create always produces a backup seq that matches the next expected receive seq on the remote side

**Priority**: Medium  
**Rationale**: The N vs N+1 discrepancy in backup sequence numbers is subtle. In the RESPONSE_NOT_READY case the next response from the remote comes at N+1 (old key) or 0 (new key). TLA+ can determine whether the re-create sequence is always consistent with what the remote side sends next.

---

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Per-direction sequence numbers as explicit state variables | Family 1, Family 4: sequence advance-before-verify is the primary source of potential session inoperability | Separate `req_seq` / `rsp_seq` per endpoint; increment as a distinct action |
| Key epoch as `{old, new}` with backup validity flag | Family 2: the backup/rollback mechanism is the core protocol invariant to verify | `active_key`, `backup_key`, `backup_valid` per direction per endpoint |
| Key update state machine with three phases | Family 2, Family 3: the multi-message exchange has distinct commit points | State enum `{Idle, UpdateSent, VerifySent}` at the initiator; corresponding event at responder |
| Encode sequence increment as a distinct step | Family 1: encode also advances before AEAD; model as non-atomic | `EncodeAdvanceSeq` → `EncodeAEAD`; AEAD failure leaves seq advanced |
| VERIFY_NEW_KEY as a one-way commit on the initiator side | Family 2: once VERIFY_NEW_KEY is sent, the initiator's key is committed with no rollback | Model `Commit` as a non-reversible action on the initiator after VERIFY_NEW_KEY send |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| AEAD cryptography internals | TLA+ cannot evaluate cryptographic strength; treat AEAD as an oracle that may fail |
| Transport-layer routing (session_id matching at dispatch) | The transport is assumed to correctly route by session_id; misrouting is an implementation concern outside the protocol |
| PSK vs DHE key derivation | The key derivation path (PSK/DHE) does not affect the key update state machine; model the resulting keys as abstract values |
| Endianness detection at sequence number 1 | The `_DEC_BOTH` auto-negotiation adds complexity with marginal protocol relevance; the endian is resolved at most by the second message and does not interact with the key update state machine |
| Opaque data structures in key exchange | Not part of the encode/decode/key-update protocol logic |
| PQ KEM vs classical DHE | Same key schedule interface; the key update logic is algorithm-agnostic |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| SeqNumEpoch | `req_seq`, `rsp_seq` per side | Model the sequence counter that advances before AEAD | Family 1 |
| KeyUpdateState | `active_key[dir]`, `backup_key[dir]`, `backup_valid[dir]` per side | Track backup/rollback state | Family 2, Family 4 |
| UpdatePhase | `update_phase ∈ {Idle, PendingAck, PendingVerify}` | Track which phase of the three-message update is in progress | Family 2 |
| CommitPoint | `initiator_committed: bool` | Flag that VERIFY_NEW_KEY has been sent (no rollback on initiator) | Family 2 |
| EncapMode | `is_encap: bool` | Gate the asymmetric immediate-commit behavior on the responder side | Family 3 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| KeyAgreement | Safety | After any complete key update (VERIFY_NEW_KEY_ACK received), both sides hold identical active keys in both directions | Family 2 |
| SeqMonotonicity | Safety | The sequence number for each direction only increases; a message cannot be decoded with a lower-than-expected sequence number | Family 1, Family 4 |
| BackupValidConsistency | Safety | `backup_valid = true` iff a `create_update` has been called without a matching `activate_update`; never true after session establishment without a preceding `create_update` | Family 2 |
| RollbackSafety | Safety | After `activate_update(use_new_key=false)`, the active key and sequence number match what the remote side expects for the next message | Family 2, Family 4 |
| VerifyNewKeyCommit | Safety | After VERIFY_NEW_KEY is sent, the initiator's send direction key is permanently committed; no subsequent `activate_update(false)` is called for that direction on the initiator | Family 2 |
| SessionContinuity | Liveness | A session that has not experienced a decode error or key update failure can always send and receive the next message | Family 1 |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|------------------------------|------------|
| MC1 | After VERIFY_NEW_KEY is sent by the requester (key committed, no rollback) and decode fails on the responder with `SESSION_TRY_DISCARD_KEY_UPDATE`, can the responder roll back to old key while the requester is committed to new key, resulting in permanent key mismatch? | KeyAgreement | Family 2 |
| MC2 | Can the RESPONSE_NOT_READY re-create loop (rollback → decode error → re-create) result in a backup sequence number that does not match the remote side's next expected sequence, causing a cascade of decode failures? | SeqMonotonicity, RollbackSafety | Family 4 |
| MC3 | In the UPDATE_ALL_KEYS flow, can the requester's "pre-create responder key before send" window, combined with a concurrent key update initiated by the responder via encap, result in both sides computing different responder keys? | KeyAgreement | Family 2, Family 3 |
| MC4 | Is it possible for `backup_valid` to be true on both sides simultaneously for the same direction (e.g., both sides call `create_update(REQUESTER)` before either commits), and if so, does this lead to a state where neither backup is valid relative to the other side's current key? | BackupValidConsistency | Family 2 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|------------------------|
| TV1 | Verify that a session_id mismatch in a received A_DATA header (legitimate routing error) permanently desynchronizes the sequence counter, making the session unable to process subsequent correct messages | Unit test: inject message with wrong session_id in A_DATA, send subsequent correct message, verify failure |
| TV2 | Verify that the RESPONSE_NOT_READY retry re-creates the same derived key (HKDF output is deterministic) after rollback, not a new key | Unit test with mock HKDF to compare key bytes before first create and after rollback+re-create |
| TV3 | Verify sequence number is correctly restored from backup on rollback when backup_seq ≠ current_seq (i.e., when key was created at seq N and a decode happened incrementing seq to N+1 before rollback) | Unit test with explicit seq checking at each step |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR1 | In `libspdm_decode_secured_message`, the sequence number is incremented before session_id is validated; a message from a wrong session (possible with a broken transport) corrupts the counter of the target session | Add a note in code comment; confirm transport always routes correctly before calling decode |
| CR2 | Encap VERIFY_NEW_KEY in `libspdm_get_encap_request_key_update` calls create+activate immediately with no backup window; the backup_valid=false means `SESSION_TRY_DISCARD_KEY_UPDATE` cannot fire if the VERIFY_NEW_KEY decode fails on the requester | Review whether the encap path needs a backup window analogous to the non-encap path |
| CR3 | `libspdm_clear_handshake_secret` (called on session state transition to ESTABLISHED) resets `requester_backup_valid = false` and `responder_backup_valid = false`; if called while a key update is in progress (theoretically), this would silently discard a live backup | Assert that no key update is in progress when transitioning to ESTABLISHED |

---

## 7. Reference Pointers

**Key source files**:
- `library/spdm_secured_message_lib/libspdm_secmes_encode_decode.c` — encode/decode logic, sequence number handling, endianness detection (lines 63–649)
- `library/spdm_secured_message_lib/libspdm_secmes_session.c` — key derivation, create_update, activate_update, backup/rollback (lines 335–583)
- `library/spdm_requester_lib/libspdm_req_key_update.c` — requester key update flow, VERIFY_NEW_KEY send, RESPONSE_NOT_READY handling (lines 32–351)
- `library/spdm_responder_lib/libspdm_rsp_key_update_ack.c` — responder key update handler for all three operations (lines 12–241)
- `library/spdm_requester_lib/libspdm_req_encap_key_update_ack.c` — encap requester handler (lines 13–159)
- `library/spdm_responder_lib/libspdm_rsp_encap_key_update.c` — encap responder send/receive (lines 12–175)
- `library/spdm_requester_lib/libspdm_req_send_receive.c:207–313` — TRY_DISCARD handler on requester side
- `library/spdm_responder_lib/libspdm_rsp_receive_send.c:197–264` — TRY_DISCARD handler on responder side
- `include/internal/libspdm_secured_message_lib.h` — context struct definition (lines 22–87)

**Reference algorithm**: DSP0277 — Secured Messages using SPDM (DMTF specification for SPDM secure channel)

**GitHub repository**: https://github.com/DMTF/libspdm (no git history in snapshot; archaeology via GitHub API)

**Bug archaeology coverage** (from GitHub API):
- Total open bug-labeled issues reviewed: ~10
- Confirmed relevant fixed PRs analyzed: 17
- Confirmed relevant open bugs: 8 (Bugs A–H above)
- Key fixed bugs providing Family evidence: #780 (seq + NOT_READY), #2318 (salt export epoch mismatch), #2393 (endianness at seq=0), #3003 (encap missing session context), #1136 (FINISH verify data used raw transcript — shows how key material mishandling causes silent security failure), #1424 (SessionID byte order)
- Key open bugs relevant to modeling scope: Issue #3009 (wrong error code in encap state), Issue #524 (transcript rollback on error — confirms lack of atomic staging is a recurring pattern)
