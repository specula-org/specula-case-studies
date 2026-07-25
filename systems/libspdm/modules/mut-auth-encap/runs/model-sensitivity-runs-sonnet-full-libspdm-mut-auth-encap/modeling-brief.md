# Modeling Brief: libspdm Encapsulated Mutual Authentication

## 1. System Overview

- **System**: DMTF/libspdm — SPDM (Security Protocol and Data Model) reference implementation
- **Language**: C, ~2558 LOC core encap logic
- **Protocol**: SPDM Encapsulated Mutual Authentication (SPDM 1.1–1.4)
- **System Category**: **Category A (Distributed / Message-Passing)** — pure request-response protocol: the Responder drives the Requester via encapsulated GET_ENCAPSULATED_REQUEST / DELIVER_ENCAPSULATED_RESPONSE exchanges to authenticate it
- **Key architectural choices**:
  - Four `mut_auth_requested` variants: `MUT_AUTH_REQUESTED` (no encap), `WITH_ENCAP_REQUEST` (full flow), `WITH_GET_DIGESTS` (Requester pre-sends DIGESTS inline — skips GET_ENCAPSULATED_REQUEST), and basic mutual auth (challenge-only or 3-step: GET_DIGESTS+GET_CERTIFICATE+CHALLENGE)
  - Encap state machine: `current_request_op_code` advances through a fixed `request_op_code_sequence[]` array; 0x00 acts as terminator
  - `request_id` is a monotonic counter that cross-links ENCAPSULATED_REQUEST and DELIVER_ENCAPSULATED_RESPONSE messages
  - Connection state (`NEGOTIATED → AUTHENTICATED`) is set by the REQUESTER *before* encap mutual auth begins (see commit b1942fee)
- **Concurrency model**: single-threaded, synchronous request/response; no concurrency hazards

---

## 2. Bug Families

### Family 1: Encap Op-Code Sequence State Machine Correctness

**Mechanism**: The `current_request_op_code` / `request_op_code_sequence` state machine has four entry variants. State transitions during error handling, ResponseNotReady, and the special `WITH_GET_DIGESTS` pre-seed path have historically been inconsistent.

**Evidence**:
- Historical: commit 6674aa87 — `mut_auth_cert_chain_buffer_size` not updated between GET_CERTIFICATE chunks; Responder endlessly re-requested first chunk (infinite loop in sequence)
- Historical: commit 58bf6bff (Issue #1791) — ResponseNotReady from Requester must terminate encap flow by setting ACK.Param2=0; was not handled before fix
- Historical: commit 5bb9df0f (Issue #3455) — Random number failure in CHALLENGE_AUTH handler caused LOW_ENTROPY instead of encapsulated error, breaking state machine
- Historical: commit 3401f214 (Issue #3031) — Missing NoPendingRequests / UnexpectedRequest error handling when no encap is pending
- Historical: commit da8f0e1c — Wrong error code returned when GET_ENCAPSULATED_REQUEST arrives inside encap flow
- Code analysis: `libspdm_init_mut_auth_encap_state` (rsp_encap_response.c:555-556) — for `WITH_GET_DIGESTS`, `current_request_op_code` is pre-set to SPDM_GET_DIGESTS (not 0), so the Requester skips GET_ENCAPSULATED_REQUEST entirely and directly delivers DELIVER_ENCAPSULATED_RESPONSE with param1=0; the Responder's `request_id=0` matches

**Affected code paths**:
- `libspdm_process_encapsulated_response` (rsp_encap_response.c:121–187)
- `libspdm_encap_move_to_next_op_code` (rsp_encap_response.c:90–110)
- `libspdm_init_basic_mut_auth_encap_state` (rsp_encap_response.c:508–548)
- `libspdm_init_mut_auth_encap_state` (rsp_encap_response.c:551–612)
- `libspdm_get_response_encapsulated_request` (rsp_encap_response.c:269–373)
- `libspdm_get_response_encapsulated_response_ack` (rsp_encap_response.c:375–493)

**Suggested modeling approach**:
- Variables: `cur_op_code` ∈ {0, GET_DIGESTS, GET_CERTIFICATE, CHALLENGE}, `request_id` ∈ Nat, `response_state` ∈ {NORMAL, PROCESSING_ENCAP}, `mut_auth_variant` ∈ {ENCAP, WITH_ENCAP_REQUEST, WITH_GET_DIGESTS, BASIC_PK, BASIC_CERT}
- Actions: Split into `InitEncapFlow`, `SendEncapRequest`, `DeliverEncapResponse`, `EncapResponseNotReady`, `EncapError`
- Key invariant: op-code sequence always terminates (reaches 0); `request_id` strictly increases unless exchange terminates
- For `WITH_GET_DIGESTS`: model first message as DELIVER_ENCAPSULATED_RESPONSE with request_id=0 (no GET_ENCAPSULATED_REQUEST step)

**Priority**: High
**Rationale**: 5+ historical bugs in this area; the four init variants and multiple error paths make exhaustive manual reasoning infeasible; TLA+ is well-suited to checking all state paths

---

### Family 2: Authentication State Ordering vs. Protocol Completion

**Mechanism**: The `LIBSPDM_CONNECTION_STATE_AUTHENTICATED` flag is set at different protocol positions across the four mutual auth variants, creating windows where the connection state does not reflect the true protocol outcome.

**Evidence**:
- Historical: commit b1942fee (Issue #3059) — `AUTHENTICATED` was originally set *after* mutual auth; the fix moved it *before* encap mutual auth starts (req_challenge.c:380). If encap mutual auth then fails, state remains AUTHENTICATED
- Historical: commit 5400adae — Documentation clarification on when Responder must terminate basic mutual auth (ACK.Param2=0)
- Historical: commit 42788e02 — Removed `LIBSPDM_DATA_BASIC_MUT_AUTH_REQUESTED` static config, replaced with dynamic HAL callback, changing when the encap decision is made
- Code analysis: req_challenge.c:380 — AUTHENTICATED set before `libspdm_encapsulated_request()` at line 389; if encap fails (line 392-394), `message_c` is reset but `connection_state` stays AUTHENTICATED
- Code analysis: rsp_encap_challenge.c:263 — For encap CHALLENGE_AUTH verification, AUTHENTICATED is set only on success (after signature verify)
- Code analysis: For basic mutual auth, the Requester's `libspdm_encapsulated_request` controls the auth of the Responder in the encap direction; inconsistency between Requester and Responder views of authenticated state

**Affected code paths**:
- `libspdm_try_challenge` (req_challenge.c:380–396)
- `libspdm_process_encap_response_challenge_auth` (rsp_encap_challenge.c:263)
- `libspdm_get_response_encapsulated_response_ack` error path (rsp_encap_response.c:467–470)

**Suggested modeling approach**:
- Variables: `requester_auth_state` ∈ {NEGOTIATED, RESP_AUTHENTICATED, MUTUALLY_AUTHENTICATED}, `responder_auth_state` ∈ {NEGOTIATED, MUT_AUTH_COMPLETE}
- Actions: `VerifyResponder` (sets RESP_AUTHENTICATED), `CompleteEncapChallenge` (sets MUTUALLY_AUTHENTICATED), `EncapChallengeFail`
- Invariant: if `requester_auth_state == MUTUALLY_AUTHENTICATED` then encap challenge completed successfully; if `requester_auth_state == RESP_AUTHENTICATED` and encap failed, connection is in a protocol-limbo state

**Priority**: High
**Rationale**: Security-critical property; state can be left as AUTHENTICATED with failed mutual auth; protocol completion → state assertion is exactly what TLA+ is good at

---

### Family 3: CHALLENGE_AUTH Response Validation Inconsistency

**Mechanism**: The CHALLENGE_AUTH response carries three interdependent fields — `param1` (slot_id in auth_attribute), `param2` (populated slot_mask), and cert_chain_hash — that must all consistently refer to the same slot. Multiple code paths historically diverged on which fields are checked.

**Evidence**:
- Historical: commit 22fce3eb (Issue #1013) — `param2` slot mask was `(1 << slot_id)` (only the challenged slot) instead of all provisioned slots; fixed by adding `libspdm_get_cert_slot_mask()`
- Historical: commit 15fc448c — CHALLENGE.param2 (measurement_summary_hash_type) during basic mut auth must be `NO_MEASUREMENT_SUMMARY_HASH`; was unchecked before fix
- Historical: commit 999ed70e (Issue #2689) — `libspdm_verify_peer_cert_chain_buffer_authority` was called even when cert integrity check failed
- Code analysis: rsp_encap_challenge.c:124–139 — Two code paths: if `req_slot_id == 0xFF`, validates `slot_id_mask == 0xF` and `param2 == 0`; if specific slot, validates `slot_id == req_slot_id` and `param2 & (1 << req_slot_id) != 0`
- Code analysis: rsp_encap_challenge.c:142–143 — `BASIC_MUT_AUTH_REQ` bit rejection prevents nested challenges
- Code analysis: rsp_encap_challenge.c:169–175 — For `req_slot_id == 0xFF`, verifies public key hash; for specific slot, verifies cert chain hash against the chain received in GET_CERTIFICATE

**Affected code paths**:
- `libspdm_process_encap_response_challenge_auth` (rsp_encap_challenge.c:80–268)
- `libspdm_get_encap_request_challenge` (rsp_encap_challenge.c:12–78)
- `libspdm_get_encap_response_challenge_auth` (req_encap_challenge_auth.c:1–239)

**Suggested modeling approach**:
- Variables: `cert_chain_received[slot_id]` ∈ BOOLEAN, `cert_hash[slot_id]`, `slot_mask`, `req_slot_id`
- Actions: `SendChallenge` (sets nonce + slot context), `ReceiveChallengeAuth` (validates all three checks)
- Invariant: If CHALLENGE_AUTH accepted, then cert_chain_received[req_slot_id] == true AND hash matches AND slot_mask has bit set for req_slot_id; for 0xFF, public key hash verified

**Priority**: Medium-High
**Rationale**: 3 historical bugs; validation rules span across the cert acquisition (GET_CERTIFICATE) and challenge (CHALLENGE) phases; inconsistency possible if certificate data changes between phases

---

### Family 4: Encap Error Code Path / State Reset Completeness

**Mechanism**: When sub-operations within the encap flow fail, the encap context state is only partially reset, leaving `current_request_op_code` non-zero in NORMAL state.

**Evidence**:
- Code analysis: rsp_encap_response.c:467–470 — When `libspdm_process_encapsulated_response` fails (non-NOT_READY), `response_state = NORMAL` but `current_request_op_code` remains non-zero; context is "half-reset"
- Code analysis: rsp_encap_response.c:145–155 — Only `NOT_READY_PEER` terminates cleanly (sets op_code=0); other errors leave op_code intact
- Code analysis: rsp_encap_response.c:359–363 — Same pattern in `libspdm_get_response_encapsulated_request` error path
- Historical: commit 58bf6bff — ResponseNotReady termination was missing entirely before this fix

**Affected code paths**:
- `libspdm_process_encapsulated_response` error branches (rsp_encap_response.c:145–154, 359–363, 467–470)

**Suggested modeling approach**: Verify that after any error, the context is either fully reset (ready for a new exchange) or fully in NORMAL state, not in a partial state where `current_request_op_code != 0` but `response_state == NORMAL`.

**Priority**: Medium
**Rationale**: Context reuse without re-init could cause spurious failures; TLA+ can check all error exit states exhaustively

---

### Family 5: Certificate Chain Slot ID Binding Across Multi-Step Exchange

**Mechanism**: The `req_slot_id` stored in `encap_context` must consistently identify the same certificate chain across the GET_DIGESTS → GET_CERTIFICATE → CHALLENGE sub-steps. The cert chain is accumulated in `mut_auth_cert_chain_buffer`, but the slot_id binding is only checked per-step, not transitively.

**Evidence**:
- Historical: commit 6674aa87 — `mut_auth_cert_chain_buffer_size` not incremented per chunk; subsequent GET_CERTIFICATE requests always requested from offset 0 (infinite loop)
- Code analysis: rsp_encap_get_certificate.c:196–201 — `cert_chain_total_len` consistency check detects tampering between chunks
- Code analysis: rsp_encap_get_certificate.c:297–334 — Upon completion, `peer_used_cert_chain[req_slot_id]` is populated (either full chain or hash+public key depending on compile flag)
- Code analysis: rsp_encap_challenge.c:172–175 — CHALLENGE_AUTH verification uses `peer_used_cert_chain[req_slot_id]` that was populated by GET_CERTIFICATE

**Affected code paths**:
- `libspdm_process_encap_response_certificate` (rsp_encap_get_certificate.c:101–340)
- `libspdm_process_encap_response_challenge_auth` (rsp_encap_challenge.c:162–178)

**Priority**: Low (for new TLA+ targets)
**Rationale**: Core infinite-loop bug is fixed (6674aa87). Remaining concern is transitive slot binding invariant; better verified by code review of slot_id usage rather than a full MC run.

---

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Four `mut_auth_requested` variants | Family 1: each variant has a different initial state (op_code pre-set vs 0, GET_ENCAPSULATED_REQUEST sent vs skipped) | Parameterize spec by variant; `WITH_GET_DIGESTS` starts directly in DELIVER phase with request_id=0 |
| Full op-code sequence state machine | Family 1: multiple historical bugs in sequence progression, error handling, termination | Variables `cur_op`, `request_id`, `response_state`; actions for each step + error/ResponseNotReady paths |
| Authentication state as separate variable | Family 2: AUTHENTICATED set before encap completes; inconsistency if encap fails | Track `resp_authenticated` and `mutually_authenticated` separately; invariant that both must hold for full auth |
| CHALLENGE_AUTH triple validation | Family 3: slot_id / slot_mask / cert_hash must all be consistent | Model `slot_verified`, `cert_hash_match`, `slot_mask_ok` as three conditions that must all hold before accepting CHALLENGE_AUTH |
| Encap error exit states | Family 4: incomplete state reset on non-NOT_READY errors | Add `EncapError` action; check that op_code=0 whenever response_state=NORMAL |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Certificate chain crypto (DER parsing, hash computation) | Implementation-level; not protocol logic; better verified by fuzzing |
| Multi-key connection details (key_pair_id, cert_info, key_usage_bit_mask) | Adds substantial state space; not in top bug families |
| Chunk reassembly arithmetic | Fixed (6674aa87); pure arithmetic, not suitable for TLA+ |
| Session encryption / HMAC | Out of scope for mutual auth protocol logic |
| SEND_EVENT / GET_ENDPOINT_INFO encap opcodes | Not part of mutual auth; separate concern |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Mut auth variant | `variant` ∈ {ENCAP, WITH_ENCAP, WITH_GET_DIGESTS, BASIC_PK, BASIC_CERT} | Capture the four different sequence entry points | Family 1 |
| Op-code sequence | `cur_op`, `op_sequence[]`, `request_id` | Track encap state machine position | Family 1 |
| Auth phase tracking | `resp_authenticated`, `mutually_authenticated` | Separate responder auth from full mutual auth | Family 2 |
| Challenge validation triple | `slot_id_ok`, `slot_mask_ok`, `cert_hash_ok` | Model the three checks in CHALLENGE_AUTH | Family 3 |
| Encap error state | `encap_error` flag | Capture incomplete-reset state on non-NOT_READY errors | Family 4 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| EncapSequenceTerminates | Safety | Op-code sequence always reaches cur_op=0 (no infinite loop) | Family 1 |
| RequestIdMonotonic | Safety | request_id only increases during an exchange; DELIVER response param1 always matches stored request_id | Family 1 |
| AuthStateConsistency | Safety | If encap flow fails, `mutually_authenticated` must not be set | Family 2 |
| NoPartialAuthState | Safety | `response_state=NORMAL` implies `cur_op=0` (no half-reset encap context) | Family 4 |
| ChallengeAuthBinding | Safety | CHALLENGE_AUTH accepted implies cert_hash_ok ∧ slot_id_ok ∧ slot_mask_ok (all three) | Family 3 |
| CertHashMatchesCertChain | Safety | cert_chain_hash in CHALLENGE_AUTH equals hash of chain received in GET_CERTIFICATE for the same req_slot_id | Family 3 |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Family |
|----|-------------|------------------------------|--------|
| MC-1 | Does encap mutual auth failure (CHALLENGE_AUTH verif failure) leave `connection_state == AUTHENTICATED` while `mutually_authenticated == false`? | AuthStateConsistency | 2 |
| MC-2 | In the `WITH_GET_DIGESTS` variant, does the state machine correctly accept request_id=0 in the first DELIVER_ENCAPSULATED_RESPONSE and advance to GET_CERTIFICATE? Can any other variant also produce request_id=0 for the first message, causing cross-variant confusion? | RequestIdMonotonic | 1 |
| MC-3 | After a non-NOT_READY error from `libspdm_process_encapsulated_response`, is `response_state=NORMAL` but `cur_op!=0`? Does this inconsistent state persist and affect a subsequent encap exchange on the same context? | NoPartialAuthState | 4 |
| MC-4 | For the three-step basic mutual auth sequence (GET_DIGESTS → GET_CERTIFICATE → CHALLENGE), can the CHALLENGE be processed without GET_CERTIFICATE having completed (i.e., `cert_chain_received[slot_id] == false`)? | CertHashMatchesCertChain | 3 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|------------------------|
| TV-1 | `req_context` in encap CHALLENGE is never freshly randomized; same value used across multiple exchanges if context is reused | Unit test: initialize context, run two basic mut auth flows, verify that req_context differs between them (or document that all-zero is intentional) |
| TV-2 | `cert_chain_total_len` in `encap_context` is not reset in init functions; stale value survives re-initialization | Unit test: run GET_CERTIFICATE, then re-init context, then run GET_CERTIFICATE again; verify `cert_chain_total_len` is re-computed from the new first chunk |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | `req_context` in `libspdm_encap_context_t` not explicitly zeroed in `libspdm_init_basic_mut_auth_encap_state` or `libspdm_init_mut_auth_encap_state`; relies on calloc-zero of outer context | Add `libspdm_zero_mem(&spdm_context->encap_context.req_context, SPDM_REQ_CONTEXT_SIZE)` to both init functions; or document the zero-init guarantee |
| CR-2 | `libspdm_get_response_encapsulated_response_ack` (v1.1) returns UNEXPECTED_REQUEST when state is NORMAL, but does not version-gate (v1.3+ should return NoPendingRequests); possible wrong error code on version boundary | Compare with `libspdm_get_response_encapsulated_request` lines 305–318 which does version-gate; apply same pattern |
| CR-3 | `libspdm_init_mut_auth_encap_state` does not initialize `cert_chain_total_len` or `use_large_cert_chain` in `encap_context`; these could be stale from a previous exchange | Add explicit zero of those fields in init |

---

## 7. Reference Pointers

**Key source files**:
- `library/spdm_responder_lib/libspdm_rsp_encap_response.c` — State machine core (614 lines): init functions, `libspdm_process_encapsulated_response`, `libspdm_encap_move_to_next_op_code`, GET_ENCAPSULATED_REQUEST and ENCAPSULATED_RESPONSE_ACK handlers
- `library/spdm_responder_lib/libspdm_rsp_encap_challenge.c` — CHALLENGE generation + CHALLENGE_AUTH validation (270 lines)
- `library/spdm_responder_lib/libspdm_rsp_encap_get_certificate.c` — Certificate chunk accumulation (343 lines)
- `library/spdm_responder_lib/libspdm_rsp_encap_get_digests.c` — Digests response processing (245 lines)
- `library/spdm_requester_lib/libspdm_req_encap_request.c` — Requester-side encap loop + `WITH_GET_DIGESTS` fast-path (479 lines)
- `library/spdm_requester_lib/libspdm_req_challenge.c` — AUTHENTICATED state transition at line 380; encap trigger at line 389

**Internal header**:
- `include/internal/libspdm_common_lib.h` — `libspdm_encap_context_t` struct (lines 478–493): `request_op_code_sequence`, `cur_op`, `request_id`, `req_slot_id`, `req_context`, `cert_chain_total_len`

**GitHub issues and PRs**:
- Issue #1013 (22fce3eb): slot mask bug — all slots not included
- Issue #1791 (58bf6bff): ResponseNotReady not handled in encap flow
- Issue #2689 (999ed70e): cert verify called on failed cert chain
- Issue #3031 (3401f214): missing NoPendingRequests error code
- Issue #3059 (b1942fee): AUTHENTICATED state set before encap mutual auth
- Issue #3455 (5bb9df0f): random failure returns wrong status in encap

**Reference algorithm**: SPDM DSP0274 specification, section on mutual authentication and encapsulated requests
