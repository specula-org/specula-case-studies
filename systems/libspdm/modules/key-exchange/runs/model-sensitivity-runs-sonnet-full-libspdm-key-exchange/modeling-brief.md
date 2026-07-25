# Modeling Brief: libspdm KEY_EXCHANGE / FINISH Session Establishment

## 1. System Overview

- **System**: libspdm — DMTF reference implementation of SPDM (Security Protocol and Data Model), DSP0274
- **Language**: C, ~5000 LOC core logic (requester + responder key exchange/finish + session/crypto infrastructure)
- **Category**: **Category A (Distributed / Message-Passing)** — two-party (Requester/Responder) request-response protocol; all correctness properties are about message sequencing, state transitions, and cryptographic handshake completion
- **Protocol**: SPDM KEY_EXCHANGE → FINISH session establishment (DHE-based mutual authentication and key derivation)
- **Key architectural choices**:
  - A **global `latest_session_id`** tracks the most-recently-allocated session; the HANDSHAKE_IN_THE_CLEAR FINISH path uses this instead of the session-ID embedded in the request (because the request is cleartext and not yet associated with a session)
  - **Two mutual-auth paths**: encap (full encapsulated exchange) and non-encap (inline slot-ID field), with the non-encap path omitting a critical session-state write
  - **State transition split across two functions**: data keys are derived inside `libspdm_get_response_finish`, but `LIBSPDM_SESSION_STATE_ESTABLISHED` is set later inside `libspdm_rsp_receive_send.c` after transport encoding
  - **Session state setter is a plain assignment** with no transition table or guard
- **Concurrency model**: Single-threaded, event-driven; no locks. Multiple concurrent sessions share a flat `session_info[]` array and a single `latest_session_id` global in the context.

---

## 2. Bug Families

### Family 1: Session Identity Confusion Under HANDSHAKE_IN_THE_CLEAR

**Mechanism**: Global `latest_session_id` is overwritten on every `libspdm_assign_session_id` call. The FINISH handler uses this global when the FINISH arrives cleartext (HANDSHAKE_IN_THE_CLEAR negotiated). A second KEY_EXCHANGE started before the first session's FINISH completes silently redirects the FINISH onto the newer session, establishing the newer session without its own FINISH authentication and orphaning the older session in HANDSHAKING state permanently.

**Evidence**:
- Code analysis: `libspdm_com_context_data_session.c:221` — `latest_session_id` unconditionally overwritten on every `libspdm_assign_session_id` call
- Code analysis: `libspdm_rsp_finish_rsp.c:480-484` — FINISH handler uses `latest_session_id` when `last_spdm_request_session_id_valid` is false (the cleartext path)
- Code analysis: `libspdm_rsp_receive_send.c:817-820` — ESTABLISHED state set using `latest_session_id`, not the session matched during FINISH processing
- Historical reference: commit `b459450eb2` — same ordering class of bug: `libspdm_assign_session_id` called before opaque data parsed, causing session version to be wrong; fixed by moving the assignment later

**Affected code paths**:
- `libspdm_get_response_key_exchange` → `libspdm_assign_session_id` (overwrites global)
- `libspdm_get_response_finish` → reads `latest_session_id` when cleartext FINISH
- `libspdm_receive_send_func` → sets ESTABLISHED from `latest_session_id`

**Suggested modeling approach**:
- Variables: `session_slots` (array of slot state), `latest_session_id` (per-context global), `session_state[slot]`
- Actions: `SendKeyExchange` assigns slot and sets `latest_session_id`; `SendFinish` (cleartext) reads `latest_session_id` to locate session; allow two concurrent in-flight KEY_EX sessions
- Invariant: for any session that transitions to ESTABLISHED, its FINISH was authenticated against its own handshake key

**Priority**: High
**Rationale**: Concrete safety violation — session establishment without per-session FINISH authentication. Unique architectural choice (global session pointer) not present in most protocol implementations. High TLA+ suitability: clean state variables, clear transition sequence.

---

### Family 2: Mutual Authentication Path Inconsistency

**Mechanism**: The two mutual-authentication paths (encap vs. non-encap) diverge in whether `peer_used_cert_chain_slot_id` is recorded in session state. The non-encap path sends `req_slot_id_param` in the KEY_EXCHANGE response but never writes it to `session_info->peer_used_cert_chain_slot_id`. The FINISH handler reads `peer_used_cert_chain_slot_id` to select the requester certificate for signature verification. When non-encap mutual auth is used and the requester's cert is not on slot 0, verification uses the wrong certificate.

**Evidence**:
- Code analysis: `libspdm_rsp_key_exchange.c:570-577` — encap path (line 575) sets `peer_used_cert_chain_slot_id = req_slot_id`; non-encap path (lines 571-572) only writes `req_slot_id_param` into the response buffer, omitting the session state write
- Code analysis: `libspdm_rsp_finish_rsp.c:49,153,200,340` — FINISH handler reads `peer_used_cert_chain_slot_id` for signature verification in all four internal functions
- Historical reference: commit `6a2e384dcc` (fix #2121) — mandatory mutual auth not enforced when requester lacks `MUT_AUTH_CAP`; same root cause class: mut-auth policy enforced on one code path but not another
- Historical reference: commit `2ff30e2554` (fix #1782) — `req_slot_id_param` only valid when `MUT_AUTH_REQUESTED` bit 0 is set; prior code treated it as unconditional

**Affected code paths**:
- `libspdm_key_exchange_start_mut_auth` → `libspdm_get_response_key_exchange` (non-encap branch, line 570-572)
- `libspdm_verify_finish_req_signature` → reads `peer_used_cert_chain_slot_id` (lines 153, 200)
- `libspdm_verify_finish_req_hmac` → reads `peer_used_cert_chain_slot_id` (line 49, line 340)

**Suggested modeling approach**:
- Variables: `peer_cert_slot[session]` (set during KEY_EXCHANGE, read during FINISH), `mut_auth_mode` (none / non-encap / encap)
- Actions: `HandleKeyExchangeResp` updates `peer_cert_slot` only in encap branch; `HandleFinish` verifies signature against `peer_cert_slot`
- Invariant: if mutual auth was negotiated, the FINISH signature is verified against the certificate slot that was advertised in KEY_EXCHANGE_RSP

**Priority**: High
**Rationale**: Authentication bypass — FINISH signature verified against wrong certificate, potentially allowing a requester to authenticate as a different identity. Two-path inconsistency with strong historical precedent (multiple closed mut-auth bugs in this area). High TLA+ suitability: clean two-choice branch with observable state divergence.

---

### Family 3: Non-Atomic Session State Transition on Responder (Finish Gap)

**Mechanism**: On the responder FINISH path, session data keys are derived and handshake keys are destroyed inside `libspdm_get_response_finish`, but the session state is only set to `LIBSPDM_SESSION_STATE_ESTABLISHED` later in `libspdm_rsp_receive_send.c` after transport encoding succeeds. Between these two events, application keys are live but the state machine reports HANDSHAKING. Additionally, late crypto failures after key derivation (TH2 hash failure, data key generation failure) return errors without freeing the session, leaving it stuck in HANDSHAKING with live data keys and no path to ESTABLISHED.

**Evidence**:
- Code analysis: `libspdm_rsp_finish_rsp.c:744` — `libspdm_generate_session_data_key` called; simultaneously clears handshake keys
- Code analysis: `libspdm_rsp_receive_send.c:771-773` (in-session FINISH) and `817-820` (cleartext FINISH) — ESTABLISHED state set after encode
- Code analysis: `libspdm_rsp_finish_rsp.c:738-763` — TH2 hash failure and `libspdm_generate_session_data_key` failure return `LIBSPDM_STATUS_CRYPTO_ERROR` without calling `libspdm_free_session_id`; compare with KEY_EXCHANGE handler which frees on all failures
- Historical reference: `56384085e8` (fix #2090), `e9cc874d4f` (fix #3408) — same pattern: error paths in KEY_EXCHANGE skip `libspdm_free_session_id`; now fixed there but not in FINISH

**Affected code paths**:
- `libspdm_get_response_finish` (libspdm_rsp_finish_rsp.c) — derives keys, does NOT set state
- `libspdm_receive_send_func` (libspdm_rsp_receive_send.c:771, 817) — sets ESTABLISHED
- `libspdm_secmes_encode_decode.c` — encode/decode path uses `session_state` to select handshake vs. application keys

**Suggested modeling approach**:
- Variables: `crypto_keys_ready[session]` (set when data keys derived), `session_established[session]` (set when ESTABLISHED)
- Actions: Split responder FINISH into `DeriveDataKeys` and `CommitEstablished`; model `DeriveDataKeys` as non-atomic with `CommitEstablished`
- Invariant: no application-data messages encrypted using application keys are accepted before `session_established` is true

**Priority**: Medium
**Rationale**: Non-atomic two-step transition is a classic TLA+ target. The FINISH slot-leak on late failure is a concrete defect (no `libspdm_free_session_id` on crypto error paths). Lower priority than Families 1–2 because the practical exploit window is narrow in single-threaded operation.

---

### Family 4: Sequence Number Counter Advanced Before AEAD Verification

**Mechanism**: The decode path increments the sequence number counter before AEAD decryption. A network-active attacker who can observe the session ID and current sequence number (both visible in the cleartext header) can inject a message with valid session_id and sequence_num fields but a forged ciphertext. The sequence number header checks pass (lines 444, 449); the counter increments; AEAD fails. All subsequent legitimate messages now fail header validation because their sequence number no longer matches the advanced counter — a permanent, one-shot DoS.

**Evidence**:
- Code analysis: `libspdm_secmes_encode_decode.c:399-426` — sequence number check and counter increment happen before AEAD call at line 477
- Code analysis: `libspdm_secmes_encode_decode.c:523-527` — only mitigation is key-update backup path (`SESSION_TRY_DISCARD_KEY_UPDATE`), which requires a prior `KEY_UPDATE` handshake; does not apply to normal operation
- No revert of the counter on AEAD failure anywhere in the file

**Affected code paths**:
- `libspdm_decode_secured_message` in `libspdm_secmes_encode_decode.c` (decode/decrypt path only)

**Suggested modeling approach**:
- Variables: `expected_seq[session, direction]`, `recv_seq[message]`
- Actions: `DecodeMessage` — atomically check seq, decrypt, then increment (correct); vs. current: check seq, increment, decrypt (buggy)
- Invariant: if `DecodeMessage` returns an error, `expected_seq` equals its pre-call value

**Priority**: Medium (DoS, not authentication bypass; narrower TLA+ scope)
**Rationale**: Confirmed code defect with no compensating mechanism for normal operation. Suitable for TLA+ invariant but limited to liveness/DoS — no session-establishment safety violation.

---

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Global `latest_session_id` and concurrent KEY_EXCHANGE | Family 1: root cause of session-identity confusion in HANDSHAKE_IN_THE_CLEAR | `latest_session_id` variable; allow two simultaneous in-flight sessions; FINISH action reads global |
| Two mutual-auth modes (encap vs. non-encap) | Family 2: non-encap path omits `peer_cert_slot` write; verification uses wrong cert | `peer_cert_slot[session]` variable; set only in encap branch of `HandleKeyExchange` |
| Split FINISH into DeriveDataKeys + CommitEstablished | Family 3: non-atomic state transition; encode failure after key derivation leaves zombie session | Two separate actions; model failure between them |
| Sequence number counter vs. AEAD ordering | Family 4: confirmed code defect — counter advanced before decryption result known | `expected_seq` variable; two action variants (correct vs. current buggy order) |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Session slot memory management (`libspdm_free_session_id` call discipline) | Resource management, not protocol safety. Better verified by test (unit test with mock error injection). No TLA+ invariant captures "slot count never exceeds MAX" at protocol level. |
| Alignment/unaligned pointer casts | Implementation detail, not protocol logic. Fixed in code; no formal model can verify C UB. |
| `secured_message_version` uninitialized for SPDM 1.1 + empty opaque | C undefined behavior, not a protocol state machine issue. Submit directly as a code-review fix. |
| FINISH signature RECORD_TRANSCRIPT wrong-slot bug | Build-time conditional (`LIBSPDM_RECORD_TRANSCRIPT_DATA_SUPPORT`); affects only test builds. Code-review fix. |
| Heartbeat / watchdog period | Transport-layer liveness concern; out of scope for session establishment safety. |
| PSK_EXCHANGE / PSK_FINISH | Different protocol flow; out of scope for this analysis round targeting DHE-based session establishment. |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Global session pointer | `latest_session_id` | Capture overwrite-on-new-session behavior | Family 1 |
| Concurrent session slots | `session_state[1..MAX_SESSIONS]`, `session_in_flight[1..MAX_SESSIONS]` | Allow two in-flight KEY_EXCHANGE to model race | Family 1 |
| Per-session peer cert slot | `peer_cert_slot[session]` | Distinguish encap vs. non-encap mut-auth paths | Family 2 |
| Mut-auth mode per session | `mut_auth_mode[session]` (none/non_encap/encap) | Guard peer-cert-slot write on encap path only | Family 2 |
| Key/state decoupling | `data_keys_live[session]`, `established[session]` | Capture non-atomic key-derivation vs. state-update | Family 3 |
| Sequence counter ordering | `expected_seq[session]` | Model counter-before-AEAD vs. counter-after-AEAD | Family 4 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| SessionEstablishedOnlyAfterOwnFinish | Safety | A session slot S transitions to ESTABLISHED only if a FINISH authenticated against S's own handshake keys was processed | Family 1, MC1 |
| MutAuthUsesNegotiatedSlot | Safety | If mutual auth was requested for session S, FINISH signature verification uses the cert slot advertised in KEY_EXCHANGE_RSP for S | Family 2, MC2 |
| NoDataKeysBeforeEstablished | Safety | No application-layer message is encrypted with session S's data keys before `established[S]` is true | Family 3, MC3 |
| SeqCounterStableOnDecryptFailure | Safety | If AEAD decryption of a message fails, `expected_seq` equals its value at the start of that decode call | Family 4, MC4 |
| SessionStateMonotonic | Safety | Session state transitions only follow the valid progression: NOT_STARTED → HANDSHAKING → ESTABLISHED → NOT_STARTED | Families 1, 3 |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Family |
|----|-------------|------------------------------|--------|
| MC1 | Second KEY_EXCHANGE (HANDSHAKE_IN_THE_CLEAR) before first session's FINISH overwrites `latest_session_id`; FINISH completes wrong session | SessionEstablishedOnlyAfterOwnFinish | 1 |
| MC2 | Non-encap mutual auth omits `peer_cert_slot` write; does FINISH verify requester identity against the advertised slot or always slot 0? | MutAuthUsesNegotiatedSlot | 2 |
| MC3 | Can the responder FINISH path produce an encode error after data key derivation, leaving session in HANDSHAKING with application keys active? | NoDataKeysBeforeEstablished, SessionStateMonotonic | 3 |
| MC4 | Does advancing the sequence counter before AEAD verification permit a one-shot injection to permanently desynchronize requester and responder counters? | SeqCounterStableOnDecryptFailure | 4 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|------------------------|
| TV1 | FINISH responder error paths (TH2 hash failure, `libspdm_generate_session_data_key` failure) do not free session slot | Unit test: mock `libspdm_calculate_th2_hash` and `libspdm_generate_session_data_key` to return failure; assert session count unchanged and slot re-usable |
| TV2 | SPDM 1.1 connection with empty opaque data leaves `secured_message_version` uninitialized | Unit test: force `opaque_length = 0` path; verify session uses correct default algorithm |
| TV3 | Sequence number counter desync on injected corrupt message | Integration test: inject message with correct session_id + seq_num but wrong ciphertext; verify next legitimate message succeeds or fails gracefully |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR1 | `libspdm_generate_finish_req_signature` (RECORD_TRANSCRIPT path) uses `req_slot_id_param` (requester's slot) to look up peer cert chain instead of `session_info->peer_used_cert_chain_slot_id` (`libspdm_req_finish.c:258-267`) | File issue; compare with non-RECORD path which correctly uses `peer_used_cert_chain_slot_id` |
| CR2 | `local_used_cert_chain_slot_id` overwritten in FINISH requester at line 483 regardless of prior KEY_EXCHANGE value — could diverge if caller passes different slot to FINISH | Review SPDM spec requirement; assert or error if slot differs from KEY_EXCHANGE negotiated value |
| CR3 | FINISH_RSP HMAC not verified when HANDSHAKE_IN_THE_CLEAR not supported — authenticity relies on implicit prior-encryption guarantee, not explicit check | Document as spec-correct; add model note for spec author to capture as a conditional rule |
| CR4 | `libspdm_secured_message_set_session_state` is an unguarded assignment; any caller can set any state (`libspdm_secmes_context_data.c:30-44`) | Add a transition table or at minimum an ASSERT for valid predecessor states |

---

## 7. Reference Pointers

**Key source files**:
- `library/spdm_requester_lib/libspdm_req_key_exchange.c` (947 LOC) — requester KEY_EXCHANGE handler
- `library/spdm_requester_lib/libspdm_req_finish.c` (756 LOC) — requester FINISH handler
- `library/spdm_responder_lib/libspdm_rsp_key_exchange.c` (822 LOC) — responder KEY_EXCHANGE handler
- `library/spdm_responder_lib/libspdm_rsp_finish_rsp.c` (770 LOC) — responder FINISH handler
- `library/spdm_common_lib/libspdm_com_context_data_session.c` (258 LOC) — session slot management, `latest_session_id`
- `library/spdm_common_lib/libspdm_com_crypto_service_session.c` (654 LOC) — TH hash computation, verify data
- `library/spdm_secured_message_lib/libspdm_secmes_session.c` (729 LOC) — key derivation
- `library/spdm_secured_message_lib/libspdm_secmes_encode_decode.c` — message encode/decode, sequence counter

**Critical line references**:
- Family 1: `libspdm_com_context_data_session.c:221`, `libspdm_rsp_finish_rsp.c:480-484`, `libspdm_rsp_receive_send.c:817-820`
- Family 2: `libspdm_rsp_key_exchange.c:570-577`, `libspdm_rsp_finish_rsp.c:49,153,200,340`
- Family 3: `libspdm_rsp_finish_rsp.c:738-763`, `libspdm_rsp_receive_send.c:771-773`
- Family 4: `libspdm_secmes_encode_decode.c:399-426` vs. `:477`

**Historical bug references** (closed — evidence for mechanism bug-proneness only):
- `6a2e384dcc` (fix #2121) — mandatory mut-auth bypass, same code area as Family 2
- `2ff30e2554` (fix #1782) — mut-auth slot field interpreted unconditionally, Family 2 area
- `b459450eb2` — session assignment before opaque data parsed, same ordering class as Family 1
- `56384085e8` (fix #2090), `e9cc874d4f` (fix #3408) — session slot leaks on error, Family 3 area
- `b09b5737aa` — VerifyData HMAC context computed at wrong time, transcript ordering

**Reference specification**: DMTF DSP0274 (SPDM specification), Section 11.x (KEY_EXCHANGE) and Section 12.x (FINISH)
