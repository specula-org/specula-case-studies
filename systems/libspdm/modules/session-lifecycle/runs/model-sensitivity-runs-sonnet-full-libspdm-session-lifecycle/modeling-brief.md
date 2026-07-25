# Modeling Brief: libspdm Session Lifecycle (HEARTBEAT / KEY_UPDATE / END_SESSION)

## 1. System Overview

- **System**: DMTF/libspdm — reference C implementation of the SPDM (Security Protocol and Data Model) protocol, used for device authentication and secure messaging in firmware/hardware stacks
- **Language**: C, ~1 200 LOC of core session-lifecycle logic (requester + responder + secured-message libs)
- **Category**: **Category A (Distributed / Message-Passing)** — the protocol is a two-party request-response state machine over an encrypted session; bugs arise from message ordering, key-state transitions, and protocol-phase sequencing between the two endpoints
- **Protocol implemented**: SPDM 1.1–1.3 post-handshake session management: HEARTBEAT (keep-alive), KEY_UPDATE (ratchet session keys), END_SESSION (graceful teardown)
- **Key architectural choices**:
  - A `libspdm_secured_message_context_t` per session holds BOTH the active AEAD key/IV and a backup set (`application_secret_backup`), used to recover from a lost KEY_UPDATE_ACK
  - `create_update_session_data_key` atomically advances the active key to a new derived value and saves the old key in the backup; `activate_update_session_data_key(new=true)` clears the backup (commits); `activate(new=false)` restores from backup (reverts)
  - `session_info->last_key_update_request` is a mini state machine tracking which UPDATE_KEY / UPDATE_ALL_KEYS operation is in progress on the responder; cleared only by VERIFY_NEW_KEY
  - Session cleanup on the responder side happens **outside** the message handler — `libspdm_terminate_session` is called in `libspdm_build_response` after `transport_encode_message` succeeds for END_SESSION_ACK (rsp_receive_send.c:792); on the requester side it happens **inside** the handler (req_end_session.c:141)
- **Concurrency model**: Single-threaded request-response; no goroutines or threads. Both sides serialise on the session object. The only "independent" liveness mechanism is the heartbeat watchdog timer (a platform stub), reset by every session message and stopped on END_SESSION_ACK (rsp_receive_send.c:785-791)

---

## 2. Bug Families

### Family 1: Two-Party Key Update State Desynchronization (HIGH)

**Mechanism**: The three-message KEY_UPDATE protocol (UPDATE_KEY or UPDATE_ALL_KEYS → ACK → VERIFY_NEW_KEY → ACK) involves multiple key-commitment points that differ between requester and responder. Each side must independently commit keys at the right moment; a mismatch or unexpected ordering can leave the two sides permanently unable to decrypt each other's messages.

**Evidence**:
- Historical: Issue #3003 / PR #3083 — "Encapsulated key update needs to know session_id" — encap key update was using the wrong session context, producing key derivations on a different session object; the bug was that `session_info->last_key_update_request` was referenced on the wrong session
- Historical: Issue #3414 — "Questionable KEY_UPDATE.VerifyNewKey behavior" — SPDM WG discussion of whether the requester's TX key should be committed before or after VERIFY_NEW_KEY is sent; behavior accepted as implementation-defined but acknowledged as a semantic edge
- Historical: Issue #809 — "Need update export master secret during key update" — UPDATE_ALL_KEYS does not update the Export Master Secret, creating a known divergence between the key derivation state and what the session export exposes
- Code analysis: req_key_update.c:200–215 — the requester creates AND activates its new TX key (requester direction) **before** sending VERIFY_NEW_KEY; the responder activates the corresponding RX key only **after** receiving VERIFY_NEW_KEY (rsp_key_update_ack.c:205-213). During the window between requester TX activation and VERIFY_NEW_KEY reception, the requester is transmitting with the new key while the responder is decrypting with the new key already in the active slot (from `create_update`) but has not yet committed (backup still valid)
- Code analysis: rsp_receive_send.c:197–263 — the decode-time fallback path: when decryption fails with the new key but the backup is valid, the code reverts to the backup, decodes the message, then immediately re-derives the new key via `create_update` again (lines 255-263). After this re-derive, `session_info->last_key_update_request` is **not** reset; if the decoded message was not VERIFY_NEW_KEY, the state machine is stuck: subsequent UPDATE_KEY or UPDATE_ALL_KEYS will be rejected with INVALID_REQUEST because `prev_spdm_request != 0` (rsp_key_update_ack.c:115-121, 141-146)

**Affected code paths**:
- `libspdm_try_key_update` (req_key_update.c:32–322) — requester UPDATE_KEY + VERIFY_NEW_KEY flow
- `libspdm_get_response_key_update` (rsp_key_update_ack.c:12–241) — responder handler, UPDATE_KEY / UPDATE_ALL_KEYS / VERIFY_NEW_KEY branches
- `libspdm_get_encap_response_key_update` (req_encap_key_update_ack.c:13–159) — requester-side handler for responder-initiated encap KEY_UPDATE (also references `last_key_update_request`)
- `libspdm_create_update_session_data_key` / `libspdm_activate_update_session_data_key` (secmes_session.c:335–583)
- Decode-time fallback (rsp_receive_send.c:197–263, req_send_receive.c:207–239)

**Suggested modeling approach**:
- Variables: `req_key_state ∈ {idle, update_sent, verify_sent}`, `rsp_key_state ∈ {idle, update_rx, verify_done}`, `req_tx_gen ∈ Nat` (key generation counter), `rsp_tx_gen ∈ Nat`, `req_rx_backup_valid`, `rsp_rx_backup_valid`
- Actions: Split KEY_UPDATE into `SendUpdateKey`, `RecvUpdateKeyAck`, `SendVerifyNewKey`, `RecvVerifyNewKeyAck`; add `RollbackKeyOnDecryptFail` to model the decode-time revert-and-re-derive path
- Granularity: Each `create_update` and `activate` is a separate sub-action; the intermediate state (new key active but backup valid) must be explicit

**Priority**: High  
**Rationale**: Multiple historical bugs share this mechanism. The decode-time re-derive path (lines 255-263) is subtle and is not covered by any TLA+ spec today. The interplay of `last_key_update_request` with the backup-rollback path is an unaudited mechanism question.

---

### Family 2: END_SESSION Phase Ordering and Session Cleanup (MEDIUM)

**Mechanism**: Session cleanup (state → NOT_STARTED, free session ID) happens at different protocol points on the requester and the responder. A mismatch in when each side considers the session dead can allow one side to send messages to a freed session slot.

**Evidence**:
- Code analysis: req_end_session.c:136–141 — requester sets session state to NOT_STARTED and calls `libspdm_free_session_id` **inside** the response-validation block, before releasing the receiver buffer (line 151). The session_info pointer becomes invalid after `libspdm_free_session_id` (it is re-initialized), but `libspdm_release_receiver_buffer` and `libspdm_append_msg_log` (lines 147-148) are called after
- Code analysis: rsp_receive_send.c:779–793 — responder calls `libspdm_terminate_session` (which calls `set_session_state(NOT_STARTED)` + `free_session_id`) **after** `transport_encode_message` returns success for END_SESSION_ACK; if encoding fails, the responder retains the session in ESTABLISHED state while the requester has already freed it
- Historical: Issue #2309 — "Provide public function in spdm_common_lib that terminates a session" — acknowledged that the responder has no way to unilaterally terminate a session and signal the requester
- Historical: Issue #2776 — "Handle Responder sending END_SESSION in application phase" — clarified that END_SESSION cannot be encapsulated; the only mechanism for responder-initiated teardown is DECRYPT_ERROR, which the requester is expected to handle as session termination

**Affected code paths**:
- `libspdm_try_send_receive_end_session` (req_end_session.c:26–153)
- `libspdm_get_response_end_session` (rsp_end_session_ack.c:9–107)
- `libspdm_build_response` END_SESSION_ACK branch (rsp_receive_send.c:779-793)
- `libspdm_terminate_session` (rsp_receive_send.c:350–363)

**Suggested modeling approach**:
- Variables: `req_session_state`, `rsp_session_state` ∈ {ESTABLISHED, NOT_STARTED}; `end_session_sent`, `end_session_ack_encoded`
- Actions: `ReqSendEndSession`, `RspRecvEndSession` (records attributes, builds ACK), `RspEncodeEndSessionAck` (succeeds/fails), `RspTerminateSession` (only if encode succeeded), `ReqRecvEndSessionAck` (terminates immediately)
- Key invariant to check: after any complete END_SESSION exchange, both `req_session_state = NOT_STARTED` and `rsp_session_state = NOT_STARTED`; also check that if `rsp_session_state = NOT_STARTED` then `req_session_state = NOT_STARTED` (requester always terminates before or at same time as responder)

**Priority**: Medium  
**Rationale**: The asymmetric cleanup is a known design choice, but TLA+ can verify that no reachable state has the session alive on one side and dead on the other after a complete exchange. The encode-failure path is an unaudited edge case.

---

### Family 3: Heartbeat Liveness and Session State Consistency (LOW-MEDIUM)

**Mechanism**: The heartbeat watchdog timer maintains session liveness. Any session message resets the watchdog (rsp_receive_send.c:800). If the watchdog fires, the session should be terminated. But the watchdog is a platform stub — libspdm does not directly terminate the session on watchdog expiry; it signals the integrator via a callback. The question is whether a session can be kept ESTABLISHED after the watchdog fires without the integrator intervening.

**Evidence**:
- Code analysis: rsp_receive_send.c:795–806 — every session message (including KEY_UPDATE and non-HEARTBEAT messages) resets the watchdog; HEARTBEAT is not special
- Code analysis: rsp_heartbeat.c:99–103 — the responder rejects HEARTBEAT with UNEXPECTED_REQUEST if `heartbeat_period == 0`; the requester makes the same check (req_heartbeat.c:63–65); the heartbeat_period value is negotiated during session setup and must match on both sides
- Code analysis: rsp_receive_send.c:779–791 — watchdog is stopped only on END_SESSION_ACK, not on any other session termination path (e.g., DECRYPT_ERROR, sequence-number overflow at line 735-736)

**Affected code paths**:
- `libspdm_try_heartbeat` (req_heartbeat.c:25–149)
- `libspdm_get_response_heartbeat` (rsp_heartbeat.c:11–121)
- Watchdog reset in `libspdm_build_response` (rsp_receive_send.c:795-806)
- Watchdog stop at END_SESSION_ACK (rsp_receive_send.c:780-791)

**Suggested modeling approach**:
- Variables: `watchdog_active`, `watchdog_expired`, `heartbeat_period`
- Actions: `SendHeartbeat`, `RecvHeartbeatAck`, `SessionMessageReceived` (resets watchdog), `WatchdogExpiry` (fires when no message within period), `IntegratorTerminatesSession` (triggered by watchdog callback)
- Key invariant: if `watchdog_expired = true` and no message has been received since expiry, then `rsp_session_state = NOT_STARTED` (the integrator must have been called)

**Priority**: Low-Medium  
**Rationale**: The watchdog path is entirely integrator-controlled; TLA+ can verify the liveness property in a model where the integrator is a non-deterministic actor. Low priority because the watchdog firing is well-understood; the main value is confirming that non-HEARTBEAT messages correctly serve as keep-alives.

---

### Family 4: `last_key_update_request` State Machine Stuck After Rollback (MEDIUM)

**Mechanism**: `session_info->last_key_update_request` acts as the responder's key-update phase tracker. The decode-time key rollback path (rsp_receive_send.c:197-263) reverts the active key to the backup and immediately re-derives the new key, but does **not** reset `last_key_update_request`. If the rolled-back message is not VERIFY_NEW_KEY, the state machine is left in a state where any new UPDATE_KEY or UPDATE_ALL_KEYS from the requester will be rejected as INVALID_REQUEST.

**Evidence**:
- Code analysis: rsp_receive_send.c:249-263 — after rollback, `create_update(REQUESTER)` is called but `session_info->last_key_update_request` is untouched
- Code analysis: rsp_key_update_ack.c:115-121 and 141-146 — the guard for UPDATE_KEY and UPDATE_ALL_KEYS checks `prev_spdm_request == 0`; if non-zero, returns INVALID_REQUEST immediately
- Code analysis: rsp_key_update_ack.c:215-216 — `last_key_update_request` is only zeroed in the VERIFY_NEW_KEY branch (successful completion) and not in any error path
- The rollback scenario requires: (1) responder processed UPDATE_KEY → sets `last_key_update_request`; (2) next incoming request fails decryption with new key but succeeds with backup; (3) the decoded message is anything other than VERIFY_NEW_KEY

**Affected code paths**:
- Decode-time rollback: rsp_receive_send.c:197-263
- Key update handler: rsp_key_update_ack.c:113-223
- `libspdm_activate_update_session_data_key` (secmes_session.c:491-583)

**Suggested modeling approach**:
- Model `last_key_update_request` as an explicit state variable in the spec
- Add a `DecodeWithBackup` action that reverts to backup key and re-derives, leaving `last_key_update_request` unchanged
- Check invariant: if `last_key_update_request = UPDATE_KEY` and a new UPDATE_KEY arrives, the handler must not silently deadlock the key-update flow

**Priority**: Medium  
**Rationale**: The rollback-then-re-derive path is an unusual interplay between the cryptographic backup mechanism and the protocol state machine. The missing reset is an unaudited code path that TLA+ can confirm as either harmless (VERIFY_NEW_KEY always arrives next) or genuinely dangerous.

---

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|------|-----|-----|
| Two-party key update state machine | Family 1 — multiple historical bugs, decode-time re-derive path unaudited | Explicit `req_tx_gen`, `rsp_tx_gen`, backup-valid flags; split `create_update` / `activate` into separate actions |
| `last_key_update_request` phase tracker | Family 4 — not reset by rollback path; reachability question | Add `rsp_last_key_op ∈ {none, update_key, update_all_keys}` as explicit variable |
| Session state machine (ESTABLISHED → NOT_STARTED) | Family 2 — asymmetric cleanup points | Track `req_session`, `rsp_session` ∈ {ESTABLISHED, NOT_STARTED} separately |
| Backup key validity flags | Family 1 — critical to the decrypt-fallback mechanism | Model `req_rx_backup_valid`, `rsp_rx_backup_valid` as booleans; trigger rollback nondeterministically |
| VERIFY_NEW_KEY as two-phase protocol message | Family 1 — key commitment happens at different times for each side | Make VERIFY_NEW_KEY a distinct action that activates requester TX on the requester side and commits requester RX on the responder side |

### 3.2 Do Not Model (with rationale)

| What | Why |
|------|-----|
| AEAD encryption / HKDF key derivation details | Cryptographic correctness is outside TLA+'s scope; the model needs only key-generation counters, not actual key material |
| Transport-layer sequence numbers | Sequence-number exhaustion is an integrator policy concern (the AEAD limit doc makes this explicit); not a protocol state machine bug |
| Heartbeat watchdog implementation | The watchdog is a platform stub; TLA+ can model the liveness property abstractly without modeling timer internals |
| Export Master Secret during KEY_UPDATE | Issue #809 is acknowledged as implementation-defined; not a protocol correctness question |
| Encapsulated KEY_UPDATE vs normal KEY_UPDATE interleaving | The request-response serialization prevents true interleaving; the shared `last_key_update_request` concern resolves to a sequencing property not requiring concurrent modeling |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Key generation tracking | `req_tx_gen`, `rsp_tx_gen`, `req_rx_gen`, `rsp_rx_gen ∈ Nat` | Track which generation of key each side uses for TX/RX; detect desync | Family 1 |
| Backup validity flags | `req_rx_backup_valid`, `rsp_rx_backup_valid ∈ BOOLEAN` | Model the two-key window during UPDATE_KEY | Families 1, 4 |
| Key-update phase tracker | `rsp_last_key_op ∈ {none, update_key, update_all_keys}` | Mirror `last_key_update_request` on responder; check stuck-state invariant | Family 4 |
| Session state per endpoint | `req_session_state`, `rsp_session_state ∈ {ESTABLISHED, NOT_STARTED}` | Track asymmetric cleanup; check session invariants | Family 2 |
| End-session attributes | `end_session_preserve_state ∈ BOOLEAN` | Model CACHE_CAP negotiation and connection-state preservation | Family 2 |
| Decode-time rollback action | `DecodeWithBackupKey` nondeterministic action | Allow model checker to explore the fallback path and check `last_key_update_request` state | Families 1, 4 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| KeySynchronization | Safety | At all times, if a message is successfully decrypted on the receiving side, the sender used the same key generation as the receiver's active key | Family 1 |
| BackupKeyWindow | Safety | At most one side has a backup key valid at any time; if both backups are valid simultaneously, the protocol is in an inconsistent state | Family 1 |
| UpdateKeyStateMachineNotStuck | Safety | If `rsp_last_key_op ≠ none` and a new UPDATE_KEY arrives after a `DecodeWithBackupKey` event, the session is not permanently unable to complete KEY_UPDATE | Family 4 |
| SessionTerminationConsistency | Safety | After a complete END_SESSION exchange (both sides acknowledged termination), `req_session_state = rsp_session_state = NOT_STARTED` | Family 2 |
| SessionMonotonicity | Safety | Once `req_session_state = NOT_STARTED`, it never returns to ESTABLISHED without a new session establishment sequence | Family 2 |
| VerifyNewKeyProgress | Liveness | If UPDATE_KEY succeeds (ACK received), VERIFY_NEW_KEY will eventually be sent (KEY_UPDATE flow terminates) | Family 1 |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|------------------------------|------------|
| MC1 | After a `DecodeWithBackupKey` event (non-VERIFY_NEW_KEY message decoded with old key), can a subsequent UPDATE_KEY from the requester be permanently rejected (session stuck unable to do key update) while both sides believe the session is ESTABLISHED? | `UpdateKeyStateMachineNotStuck` violated if `last_key_update_request` is non-zero after rollback and is never reset | Family 4 |
| MC2 | During the UPDATE_ALL_KEYS flow, between the requester activating its new TX key (req_key_update.c:210-215) and the responder receiving VERIFY_NEW_KEY, can a third message (e.g., a retransmitted UPDATE_ALL_KEYS) trigger a double `create_update` on the responder, producing a twice-derived key that the requester cannot decrypt? | `KeySynchronization` violated: requester TX gen N+1, responder RX gen N+2 | Family 1 |
| MC3 | If END_SESSION_ACK encoding fails on the responder (`transport_encode_message` returns error), can the system reach a state where `req_session_state = NOT_STARTED` and `rsp_session_state = ESTABLISHED` and no further messages can repair this (session permanently split)? | `SessionTerminationConsistency` violated | Family 2 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|------------------------|
| TV1 | Wrong error code (`LIBSPDM_STATUS_UNSUPPORTED_CAP`) returned when `libspdm_create_update_session_data_key` or `libspdm_activate_update_session_data_key` fails with a crypto error (rsp_key_update_ack.c:130, 169, 209; req_encap_key_update_ack.c:101, 107) | Inject fault in `libspdm_hkdf_expand`; verify the returned status is `LIBSPDM_STATUS_CRYPTO_ERROR` not `LIBSPDM_STATUS_UNSUPPORTED_CAP` |
| TV2 | Watchdog is stopped on END_SESSION_ACK (rsp_receive_send.c:785-791) but not on session termination via DECRYPT_ERROR or sequence-number overflow (lines 735-736) — orphaned watchdog timer | Test session termination via DECRYPT_ERROR; verify watchdog is stopped |
| TV3 | `heartbeat_period == 0` guard present on both requester (req_heartbeat.c:63) and responder (rsp_heartbeat.c:99) but the period is set from the session setup — verify behavior when requester sees period=0 but responder sees period>0 (asymmetric period) | Unit test with mismatched periods |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR1 | `last_key_update_request` not reset in the decode-time rollback path (rsp_receive_send.c:249-263) | Add `libspdm_zero_mem(prev_spdm_request, ...)` after the re-derive in the `reset_key_update` branch, or document the invariant that the rolled-back message must always be VERIFY_NEW_KEY |
| CR2 | `session_info->end_session_attributes` set at req_end_session.c:136 then immediately invalidated by `libspdm_free_session_id` at line 141 (the pointer is stale after free); the value is never read after this point | Confirm the attribute write at line 136 is dead code; remove if so, or move after the buffer release if the value is actually needed |
| CR3 | Typo at rsp_key_update_ack.c:219: `"espurious case\n"` should be `"spurious case\n"` | Fix typo |

---

## 7. Reference Pointers

- **Core source files**:
  - `library/spdm_requester_lib/libspdm_req_key_update.c` — requester UPDATE_KEY + VERIFY_NEW_KEY (352 lines)
  - `library/spdm_responder_lib/libspdm_rsp_key_update_ack.c` — responder UPDATE_KEY / UPDATE_ALL_KEYS / VERIFY_NEW_KEY handler (241 lines)
  - `library/spdm_requester_lib/libspdm_req_encap_key_update_ack.c` — requester encap KEY_UPDATE response handler (159 lines)
  - `library/spdm_responder_lib/libspdm_rsp_encap_key_update.c` — responder-initiated encap KEY_UPDATE (175 lines)
  - `library/spdm_requester_lib/libspdm_req_end_session.c` — requester END_SESSION flow (179 lines)
  - `library/spdm_responder_lib/libspdm_rsp_end_session_ack.c` — responder END_SESSION_ACK handler (107 lines)
  - `library/spdm_responder_lib/libspdm_rsp_receive_send.c:197-263` — decode-time key rollback path
  - `library/spdm_responder_lib/libspdm_rsp_receive_send.c:764-808` — session state transition dispatch (FINISH_RSP, PSK_FINISH_RSP, END_SESSION_ACK)
  - `library/spdm_secured_message_lib/libspdm_secmes_session.c:335-583` — `create_update_session_data_key` and `activate_update_session_data_key`
  - `library/spdm_secured_message_lib/libspdm_secmes_encode_decode.c:523-532, 625-634` — backup-key decrypt-failure signal
- **Relevant GitHub issues**:
  - #3003 / PR #3083 — encap key update wrong session context (fixed)
  - #3414 — VerifyNewKey behavior discussion (accepted as-is)
  - #2844 / PR #2848 — SessionRequired error code for SPDM 1.1 (fixed)
  - #2309 — session termination public API (fixed)
  - #2776 — responder-initiated END_SESSION (not supported by design)
  - #809 — Export Master Secret during key update (open / deferred)
  - #2101 — AEAD sequence number limit policy (closed, integrator-driven)
- **Reference specification**: DSP0274 (SPDM spec) §10 (Session management), §11 (Key Update); DSP0277 (Secured Messages spec) §4 (Key schedule)
- **AEAD limits documentation**: `doc/aead_limit.md` in the repo
