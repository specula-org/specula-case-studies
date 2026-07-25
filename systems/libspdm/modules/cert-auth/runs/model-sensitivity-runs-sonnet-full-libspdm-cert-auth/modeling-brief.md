# Modeling Brief: DMTF/libspdm Certificate-Based Authentication (CHALLENGE Flow)

## 1. System Overview

- **System**: libspdm — DMTF reference C library for the Security Protocol and Data Model (SPDM), v4.0.0 (pre-release)
- **Language**: C, ~7,000 LOC in the cert-auth core (requester + responder libs + common crypto)
- **Protocol**: SPDM certificate-based authentication — VCA (Version/Capabilities/Algorithms negotiation) → GET_DIGESTS → GET_CERTIFICATE → CHALLENGE / CHALLENGE_AUTH
- **Category**: **Category A (Distributed / Message-Passing)** — explicit protocol state machine driven by request-response message pairs between a Requester and a Responder. No background threads; state transitions are caller-driven and single-threaded per connection context.
- **Key architectural choices**:
  - Seven explicit connection states: `NOT_STARTED → AFTER_VERSION → AFTER_CAPABILITIES → NEGOTIATED → AFTER_DIGESTS → AFTER_CERTIFICATE → AUTHENTICATED`
  - Four transcript buffers accumulate messages for M1/M2 hash: `message_b` (GET_DIGESTS / GET_CERTIFICATE exchanges), `message_c` (CHALLENGE / CHALLENGE_AUTH), `message_mut_b` / `message_mut_c` (encap mutual auth exchanges)
  - Two compile-time modes: `LIBSPDM_RECORD_TRANSCRIPT_DATA_SUPPORT=0` (default) stores only the cert chain hash; `=1` stores the full buffer. The two modes have different security properties.
  - Requester sets `connection_state` via **direct struct write** (`libspdm_req_challenge.c:380`); Responder uses `libspdm_set_connection_state()` which fires a callback. Asymmetric state management.
- **Bug archaeology coverage**: 15 bug issues deeply read (issues #27, #93, #181, #449, #524, #600, #605, #655, #1603, #2114, #2303, #2395, #2610, #2689, #3059); confirmed bug-prone mechanism groups across connection state management and transcript integrity.

---

## 2. Bug Families

### Family 1: Connection State / Transcript Desynchronization (HIGH)

**Mechanism**: The connection state (`connection_info.connection_state`) and the transcript buffers (`message_b`, `message_c`, `message_mut_b`, `message_mut_c`) are logically coupled — the state encodes which exchanges have occurred, and the transcript captures the actual bytes for M1/M2 signing. Multiple code paths advance the connection state without updating the transcript, or fail to roll back the state when subsequent operations fail.

**Evidence**:
- Historical: Issue #3059 (CLOSED, WG-approved fix) — `libspdm_req_challenge.c:380` sets `connection_state = AUTHENTICATED` before `libspdm_encapsulated_request()` completes; on mutual auth failure (line 392), `message_c` is reset but `connection_state` is not rolled back. SPDM WG approved moving the state assignment; fix not yet in this codebase.
- Historical: Issue #524 (OPEN, years-old) — Responder appends request to transcript before response; if response append fails, request remains in transcript. Maintainer discussion shows no clear resolution.
- Code analysis: `libspdm_rsp_certificate.c:243–246` — when GET_CERTIFICATE arrives inside an established session (`session_info != NULL`), `message_b` is not appended (guarded by `session_id == NULL` at lines 224–241) but `connection_state` is unconditionally advanced to `AFTER_CERTIFICATE`. State says cert was exchanged; transcript does not reflect it.
- Code analysis: `libspdm_rsp_encap_challenge.c:248–260` — in the encap mutual auth path, `message_mut_c` is appended at line 248 **before** the requester's signature is verified at line 257. On verification failure (line 259), no `libspdm_reset_message_mut_c()` call. Compare: non-encap requester path (`libspdm_req_challenge.c:365`) **does** call `libspdm_reset_message_c()` on failure. This asymmetry is a confirmed copy-paste omission.

**Affected code paths**:
- `libspdm_try_challenge()` (`libspdm_req_challenge.c:43–405`)
- `libspdm_get_response_certificate()` (`libspdm_rsp_certificate.c:27–251`)
- `libspdm_process_encap_response_challenge_auth()` (`libspdm_rsp_encap_challenge.c:163–342`)

**Suggested modeling approach**:
- Variables: `connection_state[Requester|Responder]`, `message_b[R|S]`, `message_c[R|S]`, `message_mut_c[S]` (as abstract "what's been appended" sets, not buffers)
- Actions: Model the session GET_CERTIFICATE path as a separate action that updates state but not `message_b`. Model `EncapChallengeVerifyFail` that leaves `message_mut_c` dirty.
- Key invariant: `ConnStateAuthenticated => message_c Consistent with CertFetched`

**Priority**: High
**Rationale**: Issue #3059 confirms a real protocol-level discrepancy in connection state semantics recognized by the SPDM WG. The state/transcript desync after session-path GET_CERTIFICATE is a new finding; the encap mut_c rollback omission is independently confirmed by code comparison. Three distinct confirmed-or-likely sites sharing the same mechanism.

---

### Family 2: CHALLENGE Precondition Guards Too Weak (HIGH)

**Mechanism**: CHALLENGE is accepted when `connection_state >= NEGOTIATED`, not when `connection_state >= AFTER_CERTIFICATE`. This means `libspdm_verify_certificate_chain_hash()` can be called when the peer cert chain buffer is empty (never fetched), leading to different failure modes depending on build configuration.

**Evidence**:
- Code analysis: `libspdm_req_challenge.c:89` — precondition check: `if (connection_state < LIBSPDM_CONNECTION_STATE_NEGOTIATED)`. No `AFTER_CERTIFICATE` guard.
- Code analysis: `libspdm_rsp_challenge_auth.c:64` — same weak guard on responder side.
- Code analysis: `libspdm_com_crypto_service.c:882–938` — `libspdm_verify_certificate_chain_hash()` in `RECORD_TRANSCRIPT=1` mode: calls `libspdm_get_peer_cert_chain_buffer()` which returns `buffer_size=0` if no GET_CERTIFICATE was done, then passes a 0-byte buffer to `libspdm_hash_all()`. An adversary who provides `Hash("")` in CHALLENGE_AUTH passes this check.
- Code analysis: `libspdm_com_crypto_service.c:920–921` — in `RECORD_TRANSCRIPT=0` (default) mode: `LIBSPDM_ASSERT(buffer_hash_size != 0)` — assertion fires in debug but in production builds with `LIBSPDM_ASSERT` compiled out, `buffer_hash_size=0` causes comparison with whatever is in the zero-initialized hash buffer (32 bytes of zeros vs the provided cert hash).
- Related: Issue #449 (OPEN) — leaf cert algorithm not validated against negotiated `BaseAsymSel` until signature verification.

**Affected code paths**:
- CHALLENGE: `libspdm_try_challenge()` → `libspdm_verify_certificate_chain_hash()` (slot_id != 0xFF path, `libspdm_req_challenge.c:252`)
- `libspdm_verify_certificate_chain_hash()` (`libspdm_com_crypto_service.c:882`)

**Suggested modeling approach**:
- Variables: `cert_chain_fetched[slot_id]` boolean per slot, `cert_chain_hash_stored[slot_id]`
- Actions: `GetCertificate(slot_id)` sets `cert_chain_fetched[slot_id]`. `Challenge(slot_id)` calls `VerifyCertHash(slot_id)`.
- Invariant: `VerifyCertHashPass(slot_id) => cert_chain_fetched[slot_id]`
- Granularity: Model `Challenge` as a single action, with the guard `cert_chain_fetched[slot_id]` as a precondition to check whether the implementation violates it.

**Priority**: High
**Rationale**: The weak guard is present on both sides symmetrically. In `RECORD_TRANSCRIPT=1` mode (supported build config), the empty-hash attack is a concrete auth bypass. In the default mode, an unchecked ASSERT makes behavior undefined in release builds. The cert precondition weakness directly undermines the purpose of the CHALLENGE protocol.

---

### Family 3: Asymmetric Error Handling Between Code Path Pairs (MEDIUM)

**Mechanism**: The requester/responder sides and the normal/encap variants of the CHALLENGE flow were written as copies, with inconsistent error handling added or omitted.

**Evidence**:
- Code analysis: `libspdm_req_challenge.c:380` — direct struct write (`connection_state = AUTHENTICATED`) bypasses the `libspdm_set_connection_state()` callback mechanism. Responder at `libspdm_rsp_challenge_auth.c:337` uses `libspdm_set_connection_state()` correctly. Application callbacks registered by the integrator will NOT fire for the requester's AUTHENTICATED transition.
- Code analysis: `libspdm_rsp_encap_challenge.c:259` — no `libspdm_reset_message_mut_c()` on signature verification failure (see Family 1). Symmetric path in `libspdm_req_challenge.c:365` does call `libspdm_reset_message_c()`. This is a structural asymmetry between the two halves of the same protocol operation.
- Historical: Issue #2689 (CLOSED, re-opened) — `libspdm_verify_peer_cert_chain_buffer_authority()` called unconditionally even when `verify_peer_spdm_cert_chain` callback is registered; same bug confirmed in `libspdm_rsp_encap_get_certificate.c:290`.

**Affected code paths**:
- Requester challenge: `libspdm_req_challenge.c:380`
- Responder encap challenge: `libspdm_rsp_encap_challenge.c:248–260`
- Authority + integrity verify: `libspdm_req_get_certificate.c:474–497`, `libspdm_rsp_encap_get_certificate.c:275–295`

**Suggested modeling approach**: Not a TLA+ target — these are code-level asymmetries better caught by systematic side-by-side code comparison and testing. The connection state callback omission is a low-severity integration issue, not a protocol safety violation.

**Priority**: Medium (code review), Low (TLA+)
**Rationale**: These are implementation asymmetries, not protocol logic bugs. They would produce observable failures only for integrators relying on the connection state callback. The encap mut_c omission overlaps with Family 1 and is the higher-value modeling target.

---

### Family 4: Transcript Integrity Under Error Recovery (MEDIUM)

**Mechanism**: The transcript append operation is non-atomic (request appended first, then response). Failures after the first append but before the second leave the transcript inconsistent, which corrupts all future M1/M2 hashes for the same connection.

**Evidence**:
- Historical: Issue #524 (OPEN, long-standing) — maintainers acknowledge the problem; maintainer comment: "it is hard to *remove* or *shrink* because we use hash extend." No fix merged; unresolved design discussion.
- Code analysis: `libspdm_rsp_digests.c:173–180` — request appended at line 173, response at line 180. If line 180 fails, line 173's write persists in `message_b`.
- Code analysis: `libspdm_rsp_certificate.c:228–235` — same pattern for certificate exchange.
- Code analysis: `libspdm_req_challenge.c:348–357` — request appended at line 348 (`message_c`), response appended at line 352. If response append fails (line 354), `libspdm_reset_message_c()` is called at line 355. This is the **correct** rollback — but it erases the entire `message_c`, not just the partial append, potentially including data from prior exchanges if `message_c` were ever reused (it's reset at the start of CHALLENGE by `libspdm_reset_message_buffer_via_request_code` at line 93, so this is safe in practice).

**Affected code paths**:
- GET_DIGESTS transcript (`libspdm_rsp_digests.c:173–180`)
- GET_CERTIFICATE transcript (`libspdm_rsp_certificate.c:228–235`)

**Suggested modeling approach**:
- Variables: `transcript_partial[message_b]` boolean — set when request appended but response not yet appended
- Actions: Split transcript append into `AppendRequestToTranscript` and `AppendResponseToTranscript` with a crash window between them
- Invariant: `ChallengeSignatureValid => NOT transcript_partial[message_b]`

**Priority**: Medium
**Rationale**: Open issue #524 is a long-standing known limitation confirmed by maintainers. The partial-transcript window is present in both GET_DIGESTS and GET_CERTIFICATE, directly feeding into the M1/M2 hash used for CHALLENGE authentication. A crash between the two appends produces an M1/M2 that includes the request but not the response, or vice versa.

---

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Connection state machine (7 states) | Both bug families center on state transitions; invariants need to reference state | `connection_state[node]` variable with guards on each action |
| Cert chain fetch status per slot | Family 2: CHALLENGE precondition weakness requires tracking whether cert was fetched | `cert_fetched[slot_id]` boolean; guard on `VerifyCertHash` |
| Transcript buffer membership (abstract) | Family 1 + 4: invariants link "cert was fetched" to "cert hash in transcript" | Set-valued variables `message_b_contents`, `message_c_contents`; membership check |
| Mutual auth path (BasicMutAuth) | Family 1: premature AUTHENTICATED + no rollback on encap failure | Separate `ChallengeWithMutAuth` action; `EncapRequestFail` transition that doesn't reset state |
| Transcript rollback on failure | Family 4: partial-append window in GET_DIGESTS and GET_CERTIFICATE | Non-atomic transcript append: `AppendRequest`, crash, `AppendResponse` with rollback variant |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| `RECORD_TRANSCRIPT_DATA_SUPPORT=1` mode | Non-default build variant; the empty-hash attack in Family 2 exists but is a single-site implementation error rather than a protocol logic question |
| Async/concurrent access | libspdm is single-threaded per connection context; no races or lock issues |
| Key exchange (KEY_EXCHANGE/FINISH) session flow | Out of scope; the cert-auth CHALLENGE flow is the primary focus |
| Measurement summary hash (GET_MEASUREMENTS) | Separate transcript (message_m / L1L2) with its own reset rules; adds state space without targeting the core auth families |
| Cryptographic correctness (signature algorithms, hash size mismatch) | These produce obvious API errors, not subtle state-machine bugs |
| Transport-layer details (MCTP/PCI-DOE framing) | Below the protocol layer; not relevant to state machine invariants |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Cert-chain fetch status | `cert_fetched[slot_id]: BOOLEAN` | Track whether GET_CERTIFICATE completed for each slot | Family 2 |
| Cert hash stored | `cert_hash_valid[slot_id]: BOOLEAN` | True iff a cert hash was stored during GET_CERTIFICATE | Family 2 |
| Mutual auth in progress | `mut_auth_in_progress: BOOLEAN` | Distinguish AUTHENTICATED-before-encap from AUTHENTICATED-after-encap | Family 1 |
| Transcript partial flag | `transcript_partial[msg]: BOOLEAN` | Set between request-append and response-append | Family 4 |
| Encap mut_c dirty | `mut_c_has_unverified_data: BOOLEAN` | True if message_mut_c was appended but sig not yet verified | Family 1 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| `AuthImpliesCertFetched` | Safety | For slot_id != 0xFF: `connection_state = AUTHENTICATED => cert_fetched[slot_id]` | Family 2 |
| `ChallengeHashMatchesFetch` | Safety | `VerifyCertHashPassed(slot_id) => cert_hash_valid[slot_id]` | Family 2 |
| `NoPartialTranscriptOnChallenge` | Safety | `ChallengeSignatureComputed => NOT transcript_partial[message_b] AND NOT transcript_partial[message_c]` | Family 4 |
| `MutAuthCompleteBeforeStayAuthenticated` | Safety | After BasicMutAuth flow: `return_value = SUCCESS <=> connection_state = AUTHENTICATED` (no success/state mismatch) | Family 1 |
| `EncapMutCCleanAfterFailure` | Safety | If encap challenge auth signature verification fails: `mut_c_has_unverified_data = FALSE` after handler returns | Family 1 |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Family |
|----|-------------|------------------------------|--------|
| MC1 | Can CHALLENGE succeed (return SUCCESS and connection_state = AUTHENTICATED) without a prior GET_CERTIFICATE for the requested slot_id? Under what exact conditions does the cert hash comparison pass or fail in each build mode? | `AuthImpliesCertFetched`, `ChallengeHashMatchesFetch` | 2 |
| MC2 | If BasicMutAuth is requested and `libspdm_encapsulated_request()` fails, does `connection_state` remain AUTHENTICATED despite the error return? Can a subsequent operation that checks `< AUTHENTICATED` be incorrectly allowed? | `MutAuthCompleteBeforeStayAuthenticated` | 1 |
| MC3 | Can the responder's connection_state reach AUTHENTICATED via the session-path GET_CERTIFICATE (where message_b is not appended) followed by CHALLENGE — resulting in a CHALLENGE_AUTH signature computed over a message_b that doesn't reflect the certificate actually used? | `NoPartialTranscriptOnChallenge` | 1 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|------------------------|
| TV1 | `libspdm_rsp_encap_challenge.c:248–260`: `message_mut_c` not reset on encap CHALLENGE_AUTH signature failure | Unit test: inject a bad signature in encap path, verify `message_mut_c` is empty after the failure return |
| TV2 | `libspdm_rsp_certificate.c:243–246`: `connection_state = AFTER_CERTIFICATE` without `message_b` append when `session_info != NULL` | Integration test: GET_CERTIFICATE inside a session, verify `message_b` is unchanged while state is AFTER_CERTIFICATE |
| TV3 | `LIBSPDM_RECORD_TRANSCRIPT_DATA_SUPPORT=1`: `libspdm_verify_certificate_chain_hash()` called with zero-size cert chain | Unit test: call CHALLENGE without prior GET_CERTIFICATE in RECORD_TRANSCRIPT mode; verify the hash comparison rejects `Hash("")` |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR1 | `libspdm_req_challenge.c:380`: direct struct assignment bypasses `libspdm_set_connection_state()` callback | Replace with `libspdm_set_connection_state()` call; consistent with responder path |
| CR2 | Issue #2689 re-opened: `libspdm_rsp_encap_get_certificate.c:290` calls `libspdm_verify_peer_cert_chain_buffer_authority()` unconditionally even when `verify_peer_spdm_cert_chain` callback is registered | Add `else` guard consistent with `libspdm_req_get_certificate.c:474–497` |
| CR3 | `libspdm_rsp_handle_response_state.c:58–60`: default case returns SUCCESS without populating response buffer (silent failure for unknown `response_state` values) | Add explicit error return or ASSERT in default case |
| CR4 | `libspdm_rsp_digests.c:187`: `message_d` appended with only `multi_key_conn_rsp` guard, no `spdm_version >= 1.3` guard | Mirror the v1.3 version guard from lines 153–154 |

---

## 7. Reference Pointers

**Key source files**:
- `library/spdm_requester_lib/libspdm_req_challenge.c` (516 lines) — requester CHALLENGE main path
- `library/spdm_responder_lib/libspdm_rsp_challenge_auth.c` (347 lines) — responder CHALLENGE handler
- `library/spdm_responder_lib/libspdm_rsp_encap_challenge.c` — responder encap CHALLENGE handler (mutual auth)
- `library/spdm_requester_lib/libspdm_req_encap_challenge_auth.c` — requester encap CHALLENGE_AUTH handler
- `library/spdm_requester_lib/libspdm_req_get_certificate.c` (611 lines) — requester GET_CERTIFICATE + cert verification
- `library/spdm_responder_lib/libspdm_rsp_certificate.c` (251 lines) — responder CERTIFICATE handler
- `library/spdm_common_lib/libspdm_com_crypto_service.c` (1521 lines) — `libspdm_verify_certificate_chain_hash`, signature verify
- `library/spdm_common_lib/libspdm_com_context_data.c` (3151 lines) — transcript management, connection state, `libspdm_reset_message_buffer_via_request_code`
- `include/library/spdm_common_lib.h:201–223` — `libspdm_connection_state_t` enum

**GitHub issues**:
- Family 1 evidence: #3059 (premature AUTHENTICATED / WG-approved), #524 (partial transcript, OPEN)
- Family 2 evidence: #449 (leaf cert algorithm check, OPEN)
- Historical mechanism reference: #2689 (authority verify unconditional), #2610 (transcript size), #181 (challenge/measurements), #605/#600 (state sequencing)

**Reference spec**: DMTF DSP0274 SPDM Specification (v1.2.1 / v1.3)
- SPDM spec §10.9 (M1/M2 computation), §10.6 (CHALLENGE / CHALLENGE_AUTH flow)
