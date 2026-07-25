# Bug Report: libspdm-cert-auth Model Checking

**Target**: libspdm v4.0.0-pre  
**Spec**: `spec/MC.tla` + `spec/base.tla`  
**Model checker**: TLC 2.20 (BFS)  
**Date**: 2026-06-08

---

## Summary

Five confirmed implementation bugs found across four invariant violations. All bugs are **Case C** (real implementation defects), confirmed by cross-referencing libspdm source code.

| ID | Invariant | Family | Severity | Status |
|----|-----------|--------|----------|--------|
| BUG-001 | MCAuthImpliesCertFetched | F2/MC1 | CRITICAL | Confirmed |
| BUG-002 | MCCertInTranscriptOnAuthenticated | F1/MC3 | HIGH | Confirmed |
| BUG-003 | MCMutAuthCompleteBeforeStayAuthenticated | F1/MC2 | HIGH | Confirmed |
| BUG-004 | MCEncapMutCCleanAfterFailure | F1/TV1 | MEDIUM | Confirmed |
| BUG-005 | MCNoPartialTranscriptOnChallenge | F4 | MEDIUM | Confirmed |

### Spec fixes applied during convergence

Two spec modeling issues (Case B) were fixed during the base MC run to converge the spec:

1. **Duplicate `faultVars` declaration** (MC.tla): `faultVars` was declared as both a `VARIABLE` and an operator — removed the conflicting operator definition.
2. **Send actions lacked `msgs = {}` guard** (base.tla): `ReqGetDigests`, `ReqGetCertificate`, `ReqChallenge`, and `RspEncapChallengeSend` could fire while a message was already in the channel, violating `AtMostOneInFlight`. Added `msgs = {}` precondition to all four.
3. **IF-THEN-ELSE in `ReqSetAuthenticatedPrematurely`** (base.tla): `(s = NullSlot \/ cert_hash_valid[s])` evaluated `cert_hash_valid[NullSlot]` because TLC does not short-circuit `\/`. Changed to `IF s = NullSlot THEN TRUE ELSE cert_hash_valid[s]`.
4. **Missing `ReqEncapChallengeAuthSend` action** (base.tla + MC.tla): No action consumed `ENCAP_CHALLENGE_MSG` and sent `ENCAP_CHALLENGE_AUTH_MSG`, causing deadlock. Added the missing action and guarded `ReqEncapRequestSuccess/Fail` with `msgs = {}`.
5. **`CertInTranscriptOnAuthenticated` invariant too broad** (base.tla): The original invariant fired for NullSlot paths and for cases where no certificate was ever fetched. Narrowed to require `challenge_slot \in SlotIDs /\ cert_fetched[challenge_slot]` so it specifically targets the F1/MC3 session-path bug.

---

## BUG-001 — CHALLENGE Precondition Guard Too Weak (F2/MC1)

**Severity**: CRITICAL  
**Category**: Authentication bypass  
**Invariant**: `MCAuthImpliesCertFetched`

### Root Cause

`libspdm_try_challenge()` at `libspdm_req_challenge.c:89` checks:
```c
if (spdm_context->connection_info.connection_state < LIBSPDM_CONNECTION_STATE_NEGOTIATED) {
    return LIBSPDM_STATUS_INVALID_STATE_LOCAL;
}
```
The guard permits CHALLENGE when `connection_state >= NEGOTIATED`, meaning the requester can send CHALLENGE **without** having completed GET_DIGESTS or GET_CERTIFICATE. For a real certificate slot, the peer cert chain hash is never stored.

In `RECORD_TRANSCRIPT=0` production mode, the `LIBSPDM_ASSERT` in `libspdm_com_crypto_service.c:920–921` is compiled out. The verify-hash function compares against a zero-initialized buffer. An adversary can craft `ChallengeAuth.CertChainHash = Hash("")` (or the zero-hash value) and the comparison succeeds, yielding `connection_state = AUTHENTICATED` with `cert_fetched[slot] = FALSE`.

**Correct guard** should be: `>= LIBSPDM_CONNECTION_STATE_AFTER_CERTIFICATE` for non-NullSlot challenges.

### Counterexample (6 states)

```
State 1: Init — NOT_STARTED, msgs={}
State 2: MCNegotiate — both NEGOTIATED
State 3: MCReqChallenge(s0) — CHALLENGE sent; connection_state guard weak (>= NEGOTIATED)
State 4: MCRspChallengeAuth(s0) — Responder AUTHENTICATED; sig_computed=TRUE
State 5: MCReqChallengeAuthVerifyPass(s0) — verify "passes" with cert_hash_valid[s0]=FALSE
                                            (adversarial hash match, faultVars.verifyPass=1)
State 6: VIOLATION — connection_state[Requester]=AUTHENTICATED, auth_slot=s0,
                     cert_fetched[s0]=FALSE
```

**Violated invariant**:  
`(connection_state[Requester] = AUTHENTICATED /\ auth_slot /= NullSlot) => cert_fetched[auth_slot]`  
→ `TRUE /\ TRUE => FALSE` — violated.

### Affected Code

- `library/spdm_requester_lib/libspdm_req_challenge.c:89` — weak state guard
- `library/spdm_common_lib/libspdm_com_crypto_service.c:920–921` — ASSERT compiled out in production; zero-buffer comparison

### Impact

A requester can reach `LIBSPDM_CONNECTION_STATE_AUTHENTICATED` for a real certificate slot without having verified the peer's identity via GET_CERTIFICATE. Authentication is trivially bypassable when `RECORD_TRANSCRIPT=0`.

---

## BUG-002 — Session-path GET_CERTIFICATE Skips message_b Append (F1/MC3)

**Severity**: HIGH  
**Category**: Transcript desynchronization  
**Invariant**: `MCCertInTranscriptOnAuthenticated`

### Root Cause

In `libspdm_rsp_certificate.c`, the message_b transcript append is conditional on `session_info == NULL`:

```c
// Lines 224–249: message_b append (session_id == NULL path only)
if (session_info == NULL) {
    // append GET_CERTIFICATE request to message_b  (line ~228)
    // append CERTIFICATE response to message_b      (line ~235)
}
// Line 253: state advance is UNCONDITIONAL
if (connection_state < LIBSPDM_CONNECTION_STATE_AFTER_CERTIFICATE) {
    libspdm_set_connection_state(spdm_context, LIBSPDM_CONNECTION_STATE_AFTER_CERTIFICATE);
}
```

When called inside an SPDM session (`session_id != NULL`), the message_b append block is skipped but `connection_state` still advances to `AFTER_CERTIFICATE`. The requester fetches the certificate (setting `cert_hash_valid`), enabling the CHALLENGE to proceed. The subsequent CHALLENGE_AUTH signature is computed over a transcript that lacks the certificate exchange data.

### Counterexample (10 states)

```
State 1:  Init
State 2:  MCNegotiate — both NEGOTIATED
State 3:  MCReqGetDigests — GET_DIGESTS sent
State 4:  MCRspGetDigests — Responder AFTER_DIGESTS
State 5:  MCReqDigestsRecv — Requester AFTER_DIGESTS
State 6:  MCReqGetCertificate(s0) — GET_CERTIFICATE(s0) sent
State 7:  MCRspGetCertificateInSession(s0) — F1/MC3 fault fires:
              Responder AFTER_CERTIFICATE; cert_in_transcript_b=FALSE (skipped)
State 8:  MCReqCertificateRecv(s0) — cert_fetched[s0]=TRUE, cert_hash_valid[s0]=TRUE
State 9:  MCReqChallenge(s0) — CHALLENGE(s0) sent
State 10: MCRspChallengeAuth(s0) — Responder AUTHENTICATED; sig_computed=TRUE
VIOLATION: challenge_slot=s0∈SlotIDs, cert_fetched[s0]=TRUE, cert_in_transcript_b=FALSE
```

**Violated invariant**:  
`(connection_state[Responder]=AUTHENTICATED /\ challenge_slot∈SlotIDs /\ cert_fetched[challenge_slot]) => cert_in_transcript_b`

### Affected Code

- `library/spdm_responder_lib/libspdm_rsp_certificate.c:224–253` — conditional message_b append vs. unconditional state advance

### Impact

CHALLENGE_AUTH signature is computed over an incomplete transcript when GET_CERTIFICATE is processed inside a session. The certificate chain's authenticity guarantee in the signature is weakened or absent.

---

## BUG-003 — Premature AUTHENTICATED Before Mutual Auth Completes (F1/MC2)

**Severity**: HIGH  
**Category**: Connection state desynchronization  
**Invariant**: `MCMutAuthCompleteBeforeStayAuthenticated`

### Root Cause

In `libspdm_try_challenge()`:
```c
// libspdm_req_challenge.c:404
spdm_context->connection_info.connection_state = LIBSPDM_CONNECTION_STATE_AUTHENTICATED;
// ... 24 lines later ...
// libspdm_req_challenge.c:428
status = libspdm_encapsulated_request(...);
if (LIBSPDM_STATUS_IS_ERROR(status)) {
    // Lines 429-432: reset message_c (transcript) but NOT connection_state
    libspdm_reset_message_c(spdm_context);
    return status;
}
```

`connection_state` is set to `AUTHENTICATED` at line 404, **before** `libspdm_encapsulated_request()` at line 428. If the encapsulated request fails, the error path (lines 429–432) resets `message_c` but **does not reset** `connection_state`. The connection remains marked as AUTHENTICATED despite the mutual authentication having failed.

### Counterexample (6 states)

```
State 1: Init
State 2: MCNegotiate — both NEGOTIATED
State 3: MCReqChallenge(NullSlot) — CHALLENGE(NullSlot) sent
State 4: MCRspChallengeAuth(NullSlot) — Responder AUTHENTICATED
State 5: MCReqSetAuthenticatedPrematurely(NullSlot) — F1/MC2 fault:
             connection_state[Requester]=AUTHENTICATED, mut_auth_in_progress=TRUE
State 6: MCReqEncapRequestFail — encap fails; mut_auth_failed=TRUE
         BUG: connection_state[Requester] stays AUTHENTICATED
VIOLATION: mut_auth_failed=TRUE, connection_state[Requester]=AUTHENTICATED
```

**Violated invariant**:  
`mut_auth_failed => connection_state[Requester] /= AUTHENTICATED`  
→ `TRUE => FALSE` — violated.

### Affected Code

- `library/spdm_requester_lib/libspdm_req_challenge.c:404` — premature state set
- `library/spdm_requester_lib/libspdm_req_challenge.c:429–432` — error path omits state rollback

**WG-approved fix** (referenced in spec comment): Move line 404 assignment to after the line 428 success check.

### Impact

After a failed mutual authentication, the requester believes the connection is authenticated. Subsequent operations that require mutual auth may proceed incorrectly. A peer that fails mutual auth can still be treated as authenticated.

---

## BUG-004 — message_mut_c Not Reset on Encap Signature Failure (F1/TV1)

**Severity**: MEDIUM  
**Category**: Transcript buffer state corruption  
**Invariant**: `MCEncapMutCCleanAfterFailure`

### Root Cause

In `libspdm_rsp_encap_challenge.c` (lines 248–260):
```c
// Line 248: append ENCAP_CHALLENGE_AUTH to message_mut_c
status = libspdm_append_message_mut_c(spdm_context, ...);
// Line 257: verify signature
status = libspdm_verify_challenge_auth_signature(spdm_context, ...);
if (LIBSPDM_STATUS_IS_ERROR(status)) {
    return status;  // Line 259: ERROR RETURN — no libspdm_reset_message_mut_c() call!
}
```

After appending to `message_mut_c` (line 248), if signature verification fails (line 257), the function returns an error **without** calling `libspdm_reset_message_mut_c()`. This leaves `message_mut_c` containing unverified data. Compare with the requester path in `libspdm_req_challenge.c:365` which **correctly** calls `libspdm_reset_message_c()` on failure.

### Counterexample (20 states)

```
States 1–13: Negotiate → DIGESTS → CERTIFICATE(s0) → CHALLENGE(s0) → CHALLENGE_AUTH(s0)
State 14:    MCReqSetAuthenticatedPrematurely(s0) — F1/MC2: Requester prematurely AUTHENTICATED
States 15–17: Re-fetch CERTIFICATE(s0) (for encap flow)
State 18:    MCRspEncapChallengeSend — Responder sends ENCAP_CHALLENGE
State 19:    MCReqEncapChallengeAuthSend — Requester replies with ENCAP_CHALLENGE_AUTH
State 20:    MCRspEncapChallengeAuthFail — sig verify fails:
                 mut_c_has_unverified_data=TRUE, encap_sig_verified=FALSE
VIOLATION: ~encap_sig_verified /\ ENCAP_CHALLENGE_AUTH_MSG ∉ msgs /\ mut_c_has_unverified_data
```

**Violated invariant**:  
`(~encap_sig_verified /\ ENCAP_CHALLENGE_AUTH_MSG ∉ msgs /\ CHALLENGE_AUTH_MSG ∉ msgs) => ~mut_c_has_unverified_data`

### Affected Code

- `library/spdm_responder_lib/libspdm_rsp_encap_challenge.c:248–260` — missing `libspdm_reset_message_mut_c()` on sig-verify failure

### Impact

After an encapsulated challenge authentication failure, `message_mut_c` retains partial data. A subsequent retry of the mutual authentication flow will operate on a transcript that includes data from the failed attempt. This can allow transcript manipulation or enable replay-style attacks on the mutual authentication handshake.

---

## BUG-005 — Partial Transcript on Failed GET_DIGESTS Response Append (F4)

**Severity**: MEDIUM  
**Category**: Transcript integrity under error recovery  
**Invariant**: `MCNoPartialTranscriptOnChallenge`

### Root Cause

In `libspdm_rsp_digests.c` (lines 173–180):
```c
// Line 173: append GET_DIGESTS request to message_b (hash extend — IRREVERSIBLE)
status = libspdm_append_message_b(spdm_context, request, request_size);
...
// Line 180: append DIGESTS response to message_b
status = libspdm_append_message_b(spdm_context, response, response_size);
if (LIBSPDM_STATUS_IS_ERROR(status)) {
    return libspdm_generate_error_response(...);  // No cleanup of partial message_b
}
```

If the response append at line 180 fails, `message_b` is left with only the request appended (partial state). Because `message_b` uses a hash-extend operation, the request append at line 173 cannot be undone. The connection continues with a corrupted transcript. If a CHALLENGE is subsequently sent, `RspChallengeAuth` computes the CHALLENGE_AUTH signature over this corrupted `message_b`.

The same pattern appears in `libspdm_rsp_certificate.c:228–235` for GET_CERTIFICATE exchanges.

### Counterexample (8 states)

```
State 1: Init
State 2: MCNegotiate — both NEGOTIATED
State 3: MCReqChallenge(s0) — CHALLENGE(s0) sent early (F2 weak guard)
State 4: MCRspChallengeAuth(s0) — sig_computed=TRUE; Responder AUTHENTICATED
State 5: MCReqChallengeAuthVerifyFail(s0) — Requester fails verify (cert not fetched)
State 6: MCReqGetDigests — Requester retries: sends GET_DIGESTS; msgs={}
State 7: MCAppendResponseFail_GetDigests — F4 fault:
             transcript_partial[Responder][MSG_B]=TRUE (request appended, response failed)
State 8: VIOLATION — sig_computed=TRUE (from step 4), transcript_partial[Responder][MSG_B]=TRUE
```

**Violated invariant**:  
`sig_computed => ~transcript_partial[Responder][MSG_B]`

**Note**: The invariant fires at the PRECURSOR state — `sig_computed=TRUE` from an earlier challenge and `transcript_partial=TRUE` from the failed GET_DIGESTS. A subsequent CHALLENGE would compute a new signature directly over the partial transcript, realizing the full F4 attack. The `sig_computed` flag is monotone (never reset) so the invariant detects the dangerous reachable state before the second challenge.

### Affected Code

- `library/spdm_responder_lib/libspdm_rsp_digests.c:173–180` — response append failure leaves partial transcript (referenced in issue #524)
- `library/spdm_responder_lib/libspdm_rsp_certificate.c:228–235` — same pattern for GET_CERTIFICATE

### Impact

A CHALLENGE_AUTH signature is computed over a transcript that includes only one side of a protocol exchange (request without response, or partial certificate data). This corrupts the cryptographic binding between the authentication exchange and the transcript. If an adversary can induce the response-append failure, they can potentially influence the authenticated transcript content.

---

## Model Checking Statistics

| Config | States Generated | Distinct States | Result |
|--------|-----------------|-----------------|--------|
| MC_base (r4) | 4,810 | 2,967 | ✓ No violations |
| MC_hunt_family1 (final) | 1,299 | 1,028 | ✗ 3 invariants violated |
| MC_hunt_family2 (r2) | 84 | 65 | ✗ 1 invariant violated |
| MC_hunt_family4 (r2) | — | — | ✗ 1 invariant violated |

## Spec Changes Made During Analysis

All changes are in `spec/base.tla` and `spec/MC.tla`.

### base.tla

1. Added `msgs = {}` precondition to `ReqGetDigests`, `ReqGetCertificate`, `ReqChallenge`, `RspEncapChallengeSend` — ensures sequential send discipline.
2. Changed `(s = NullSlot \/ cert_hash_valid[s])` → `(IF s = NullSlot THEN TRUE ELSE cert_hash_valid[s])` in `ReqSetAuthenticatedPrematurely` — avoids domain-error on NullSlot.
3. Added `msgs = {}` precondition to `ReqEncapRequestSuccess` and `ReqEncapRequestFail` — ensures encap exchange completes before result is signaled.
4. Added `ReqEncapChallengeAuthSend` action — models requester consuming `ENCAP_CHALLENGE_MSG` and sending `ENCAP_CHALLENGE_AUTH_MSG`.
5. Narrowed `CertInTranscriptOnAuthenticated` invariant — conditioned on `challenge_slot ∈ SlotIDs /\ cert_fetched[challenge_slot]` to target F1/MC3 exclusively.

### MC.tla

1. Removed duplicate `faultVars == [...]` operator definition.
2. Uncommented extension invariants (`MCAuthImpliesCertFetched` etc.) for hunt configs.
3. Added `MCReqEncapChallengeAuthSend` wrapper and included it in `MCNext`.
