# Brief Coverage Self-Audit

Mapping of brief §2 (Bug Families), §5 (Invariants), and §6.1 (Model-Checkable Findings)
to spec artifacts. Generated as part of Phase 2 spec generation.

---

## §2 Bug Families → Hunt Configs

| Family | Description | Hunt Config | Spec Action(s) | Spec Invariant(s) |
|--------|-------------|-------------|----------------|-------------------|
| 1 | Encap op-code sequence state machine | `MC_hunt_family1.cfg` | `GetEncapsulatedRequest`, `DeliverEncapResponseDigests`, `DeliverEncapResponseCertificate`, `EncapResponseNotReady` | `EncapSequenceTerminates`, `RequestIdMonotonic` |
| 2 | Authentication state ordering vs. protocol completion | `MC_hunt_family2.cfg` | `VerifyResponder`, `EncapError` | `NoPhantomAuth`, `AuthStateConsistency`, `FullMutualAuthRequiresEncapComplete` |
| 3 | CHALLENGE_AUTH response validation inconsistency | `MC_hunt_family3.cfg` | `DeliverEncapResponseChallengeAuth` | `ChallengeAuthBinding`, `CertChainReceivedBeforeChallenge` |
| 4 | Encap error code path / state reset completeness | `MC_hunt_family4.cfg` | `EncapError` | `NoPartialAuthState` |
| 5 | Certificate chain slot ID binding across multi-step exchange | *Out of scope* (see below) | — | — |

**Family 5 out-of-scope note**: The modeling brief rated Family 5 priority **Low** and noted
"better verified by code review of slot_id usage." The core bug (commit 6674aa87) is fixed;
the remaining concern is a transitive slot binding invariant that requires modeling
`cert_chain_total_len` arithmetic which the brief explicitly excludes from scope
(§3.2: "Chunk reassembly arithmetic … not suitable for TLA+"). No hunt config generated.

---

## §5 Invariants → Spec and Hunt Configs

| Brief Invariant | Spec Invariant | Defined in base.tla | Enabled in ≥1 hunt cfg | Hunt cfg |
|-----------------|---------------|---------------------|------------------------|----------|
| EncapSequenceTerminates | `EncapSequenceTerminates` | ✓ | ✓ | `MC_hunt_family1.cfg` |
| RequestIdMonotonic | `RequestIdMonotonic` | ✓ | ✓ | `MC_hunt_family1.cfg` |
| AuthStateConsistency | `AuthStateConsistency` | ✓ | ✓ | `MC_hunt_family2.cfg` |
| NoPartialAuthState | `NoPartialAuthState` | ✓ | ✓ | `MC_hunt_family4.cfg` |
| ChallengeAuthBinding | `ChallengeAuthBinding` | ✓ | ✓ | `MC_hunt_family3.cfg` |
| CertHashMatchesCertChain | `CertChainReceivedBeforeChallenge` (proxy) | ✓ | ✓ | `MC_hunt_family3.cfg` |

**CertHashMatchesCertChain note**: The brief's original invariant requires modeling `cert_hash`
as a concrete value and comparing it to the hash of the received chain. The brief also excludes
crypto and hash computation from scope (§3.2). The proxy invariant
`CertChainReceivedBeforeChallenge` captures the structural precondition (cert chain must be
present before CHALLENGE_AUTH is accepted) without requiring hash modeling. This covers MC-4
from §6.1.

---

## §6.1 Model-Checkable Findings → Hunt Configs

| Finding | Description | Reachable via | Hunt Config | Invariant |
|---------|-------------|---------------|-------------|-----------|
| MC-1 | CHALLENGE_AUTH failure leaves `connection_state == AUTHENTICATED` while `mutually_authenticated == FALSE` | `VerifyResponder` → encap starts → `EncapError` fires with `cur_op = OP_CHALLENGE` | `MC_hunt_family2.cfg` | `NoPhantomAuth` |
| MC-2 | WITH_GET_DIGESTS accepts `request_id=0`; cross-variant `request_id=0` confusion? | `DeliverEncapResponseDigests` precondition `(variant = VAR_WITH_GET_DIGESTS => request_id = 0)` enforced; other variants have `request_id >= 1` after `GetEncapsulatedRequest` | `MC_hunt_family1.cfg` | `RequestIdMonotonic`, `EncapSequenceTerminates` |
| MC-3 | After non-NOT_READY error: `response_state=NORMAL` but `cur_op!=0` | `EncapError` leaves `cur_op` unchanged, sets `response_state=RS_NORMAL` | `MC_hunt_family4.cfg` | `NoPartialAuthState` |
| MC-4 | CHALLENGE processed without `cert_chain_received == FALSE` | `DeliverEncapResponseChallengeAuth` can fire after `EncapError` aborts GET_CERTIFICATE (cert_chain_received stays FALSE) — but note: the spec's precondition `response_state = RS_PROCESSING_ENCAP` prevents this in the current model (EncapError sets RS_NORMAL). MC-4 is better exercised by checking `CertChainReceivedBeforeChallenge` under all paths. | `MC_hunt_family3.cfg` | `CertChainReceivedBeforeChallenge` |

**MC-4 clarification**: In the current model, `DeliverEncapResponseChallengeAuth` requires
`response_state = RS_PROCESSING_ENCAP`, so it cannot fire after `EncapError` (which sets
`RS_NORMAL`). The scenario "CHALLENGE without GET_CERTIFICATE" can arise if the *spec* were
to allow skipping GET_CERTIFICATE — which would require `variant = VAR_BASIC_PK` (CHALLENGE-only).
For `VAR_BASIC_PK`, `cert_chain_received` is always FALSE, but `CertChainReceivedBeforeChallenge`
only requires the cert to be received for variants `{VAR_WITH_ENCAP_REQUEST, VAR_WITH_GET_DIGESTS,
VAR_BASIC_CERT}`. So the invariant is correctly scoped. The MC hunt will exhaustively verify this.

---

## Summary: All Invariants Enabled in ≥1 Hunt Config

| Invariant | MC_hunt_family1.cfg | MC_hunt_family2.cfg | MC_hunt_family3.cfg | MC_hunt_family4.cfg |
|-----------|:-------------------:|:-------------------:|:-------------------:|:-------------------:|
| TypeOK | ✓ | ✓ | ✓ | ✓ |
| EncapSequenceTerminates | ✓ | | | |
| RequestIdMonotonic | ✓ | | | |
| AuthStateConsistency | | ✓ | | |
| NoPhantomAuth | | ✓ | | |
| FullMutualAuthRequiresEncapComplete | | ✓ | | |
| ChallengeAuthBinding | | | ✓ | |
| CertChainReceivedBeforeChallenge | | | ✓ | |
| NoPartialAuthState | | | | ✓ |

All nine invariants are enabled in at least one hunt config. No invariant is defined but never hunted.

---

## Known Gaps and Limitations

1. **No multi-exchange modeling**: The spec models a single encap flow from init to completion. It does not model context reuse across multiple exchanges (TV-1, TV-2 from brief §6.2). These are test-verifiable items; adding them to the spec would require a "re-init" action and stale-state tracking.

2. **Crypto abstracted away**: Hash verification is modeled as a BOOLEAN (`cert_hash_ok`) set non-deterministically to TRUE on success. Concrete hash mismatch scenarios (commit 999ed70e / Issue #2689) are out of scope per brief §3.2.

3. **No version-gating for NoPendingRequests vs UnexpectedRequest**: CR-2 from brief §6.3 notes that `libspdm_get_response_encapsulated_response_ack` does not version-gate the error code (v1.3+ should return NoPendingRequests). This is a code-review-only finding and cannot be modeled without version state — out of scope for this spec.

4. **EncapError fault injection is unbounded in base spec**: The spec's `EncapError` action can fire from any `RS_PROCESSING_ENCAP` state. In `MC.cfg` and hunt configs, `MaxEncapErrLimit` bounds it. MC_hunt_family4.cfg uses limit=1 to minimize state space while still reaching the violation in 2 steps.
