# Brief Coverage Self-Audit

Maps modeling-brief.md §2 (Bug Families), §5 (Proposed Invariants), and §6.1 (Model-Checkable Findings) to spec and MC artifacts.

---

## §2 Bug Families → Hunt Configs

| Family | Hunt config | Target invariant(s) | Notes |
|---|---|---|---|
| F1: Connection State / Transcript Desync | `MC_hunt_family1.cfg` | `MCCertInTranscriptOnAuthenticated`, `MCMutAuthCompleteBeforeStayAuthenticated`, `MCEncapMutCCleanAfterFailure`, `MCNoPartialTranscriptOnChallenge` | F1 and F4 share `NoPartialTranscriptOnChallenge`; F1 hunt also covers session-path cert (MC3). F4 gets its own hunt config for the partial-append fault path. |
| F2: CHALLENGE Precondition Guards Too Weak | `MC_hunt_family2.cfg` | `MCAuthImpliesCertFetched`, `MCChallengeHashMatchesFetch` | `MCReqChallengeAuthVerifyPass` models adversarial cert-hash bypass (RECORD_TRANSCRIPT=0 ASSERT-off). |
| F3: Asymmetric Error Handling | *not a TLA+ target* | — | Brief explicitly assigns this to code-review-only (§2 priority: Low for TLA+). No hunt config. The encap mut_c overlap is covered by F1. |
| F4: Transcript Integrity Under Error Recovery | `MC_hunt_family4.cfg` | `MCNoPartialTranscriptOnChallenge` | Fault-injection: `MCAppendResponseFail_GetDigests` and `MCAppendResponseFail_GetCertificate`. |

---

## §5 Proposed Invariants → Spec + Hunt Configs

| Brief invariant | Spec invariant | Defined in | Enabled in hunt config |
|---|---|---|---|
| `AuthImpliesCertFetched` | `AuthImpliesCertFetched` | `base.tla` | `MC_hunt_family2.cfg` ✓ |
| `ChallengeHashMatchesFetch` | `ChallengeHashMatchesFetch` | `base.tla` | `MC_hunt_family2.cfg` ✓ |
| `NoPartialTranscriptOnChallenge` | `NoPartialTranscriptOnChallenge` | `base.tla` | `MC_hunt_family1.cfg` ✓ `MC_hunt_family4.cfg` ✓ |
| `MutAuthCompleteBeforeStayAuthenticated` | `MutAuthCompleteBeforeStayAuthenticated` | `base.tla` | `MC_hunt_family1.cfg` ✓ |
| `EncapMutCCleanAfterFailure` | `EncapMutCCleanAfterFailure` | `base.tla` | `MC_hunt_family1.cfg` ✓ |

All five brief §5 invariants are defined in `base.tla` and enabled in at least one hunt config. ✓

---

## §6.1 Model-Checkable Findings → Hunt Config Reachability

| Finding | Required fault setup | Hunt config | Reachable? |
|---|---|---|---|
| MC1: CHALLENGE succeeds without GET_CERTIFICATE | `MCReqChallengeAuthVerifyPass` fires with `cert_fetched[s]=FALSE` | `MC_hunt_family2.cfg` (MaxVerifyPassLimit=2) | ✓ Path: `Negotiate → ReqGetDigests → RspGetDigests → ReqDigestsRecv → ReqChallenge(s) → RspChallengeAuth → MCReqChallengeAuthVerifyPass` |
| MC2: Premature AUTHENTICATED + encap failure leaves AUTHENTICATED | `MCReqSetAuthenticatedPrematurely` + `MCReqEncapRequestFail` | `MC_hunt_family1.cfg` (MaxPrematureAuthLimit=1) | ✓ Path: `... → MCReqSetAuthenticatedPrematurely → (encap round) → MCReqEncapRequestFail → MutAuthCompleteBeforeStayAuthenticated violation` |
| MC3: Session-path GET_CERTIFICATE → CHALLENGE_AUTH over incomplete message_b | `MCRspGetCertificateInSession` fires, then `RspChallengeAuth` | `MC_hunt_family1.cfg` (MaxInSessionCertLimit=1) | ✓ Path: `... → MCRspGetCertificateInSession → RspChallengeAuth → CertInTranscriptOnAuthenticated violation` |

---

## Gap analysis

**F3 (Asymmetric Error Handling)**: Deliberately excluded from TLA+ per brief §2. Code-review items CR1-CR4 have no hunt config. The brief rationale ("implementation asymmetries, not protocol logic bugs") stands. No coverage gap.

**`AuthenticatedIsTerminal` structural invariant**: Defined in `base.tla` but not enabled in MC.cfg or hunt configs because its formulation (`~mut_auth_failed`) is conditional on the bug scenario — it would trivially hold in non-mut-auth traces. Left as documentation only.

**RECORD_TRANSCRIPT=1 mode**: Brief §3.2 explicitly excludes this as "non-default build variant / single-site implementation error." Not modeled. No gap.

**mut_auth path for F2**: MC2 + F2 interact (ReqSetAuthenticatedPrematurely requires cert_hash_valid[s] or NullSlot at its guard). The F2 hunt (MaxVerifyPassLimit=2, MaxPrematureAuthLimit=0) and F1 hunt (MaxPrematureAuthLimit=1, MaxVerifyPassLimit=0) are intentionally separated to keep invariant targets focused.
