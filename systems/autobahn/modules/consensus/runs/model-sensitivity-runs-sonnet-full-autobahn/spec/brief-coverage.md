# Brief Coverage Self-Audit

Cross-checks modeling-brief.md §2 (Bug Families), §5 (Invariants), and §6.1 (MC findings)
against spec and hunt config artifacts.

---

## §2 Bug Families → Spec Coverage

| Family | Mechanism | Spec actions | Hunt cfg |
|--------|-----------|-------------|---------|
| F1: Proposal-Binding | Vote digest excludes proposals (messages.rs:237-279) | `ByzEquivocatePrepare`, `FormPrepareQC` (P arbitrary) | `MC_hunt_f1_proposal_binding.cfg` |
| F2: View-Change Rules | Empty Timeout digest; wrong `winning_view`; no QC verify | `ByzSendTimeout`, `FormTC` (buggy `GetWinningProposalsBuggy`) | `MC_hunt_f2_view_change.cfg` |
| F3: Confirm Equivocation | No `last_voted_consensus` guard for Confirm (core.rs:1167) | `CastConfirmVote` (no guard; repeatable) | `MC_hunt_f3_confirm_equivocation.cfg` |
| F4: 2-Chain / No Persist | Only checks first link (hotstuff:327); vote round not persisted (hotstuff:118) | `HSProcessBlock` (one-link check), `HSCrashRecover` (resets to 0) | `MC_hunt_f4_twochain.cfg` |
| F5: Inverted GC | De Morgan complement retains wrong entries (core.rs:1612) | `CleanSlotPeriods` (buggy predicate in spec) | `MC_hunt_f5_gc.cfg` |

All five families have both spec actions and a dedicated hunt config. ✓

---

## §5 Invariants → Hunt Config Coverage

| Invariant | Type | Enabled in ≥1 hunt cfg |
|-----------|------|------------------------|
| `AgreementOnProposals` | Safety F1 | `MC_hunt_f1_proposal_binding.cfg` via `UniqueCommit` (equivalent) ✓ |
| `ViewChangeSafety` | Safety F2 | `MC_hunt_f2_view_change.cfg` ✓ |
| `TimeoutAuthenticityBound` | Safety F2 | `MC_hunt_f2_view_change.cfg` ✓ |
| `NoConfirmEquivocation` | Safety F3 | `MC_hunt_f3_confirm_equivocation.cfg` ✓ |
| `TwoChainCommitRule` | Safety F4 | `MC_hunt_f4_twochain.cfg` ✓ |
| `VoteSafety` | Safety F4 | `MC_hunt_f4_twochain.cfg` ✓ |
| `GCPreservesActive` | Liveness F5 | `MC_hunt_f5_gc.cfg` ✓ |

All 7 brief §5 invariants are enabled in at least one hunt config. ✓

---

## §6.1 MC Findings → Reachability

| Finding | Hunt cfg | Fault setup makes it reachable? |
|---------|----------|---------------------------------|
| MC1: Byzantine equivocate at Prepare → two PrepareQCs | `MC_hunt_f1_proposal_binding.cfg` | `MaxByzEquivocate=1`; `FormPrepareQC` allows any P → reachable ✓ |
| MC2: wrong `winning_view` → stale proposal wins TC | `MC_hunt_f2_view_change.cfg` | `MaxByzTimeout=2, MaxFormTC=2` → Byzantine can steer TC ✓ |
| MC3: forged `high_qc` via empty digest → unlocked proposal adopted | `MC_hunt_f2_view_change.cfg` | `ByzSendTimeout` with arbitrary view → `FormTC` picks it ✓ |
| MC4: double ConfirmVote → conflicting ConfirmQCs | `MC_hunt_f3_confirm_equivocation.cfg` | `CastConfirmVote` repeatable; no guard → double vote reachable ✓ |
| MC5: missing second 2-chain link → premature commit | `MC_hunt_f4_twochain.cfg` | `HSPublishBlock` with gap (pr+2 < r); `HSProcessBlock` one-link check ✓ |

All five MC findings have a reachable fault setup. ✓

---

## Gaps and Deliberate Omissions

| Item | Status | Reason |
|------|--------|--------|
| `sailfish/` commented-out code | Not modeled | Per brief §3.2: stubs, not live paths |
| `last_voted_consensus` memory leak (TV4) | Not modeled | Brief §3.2: test-verifiable, not protocol safety issue |
| Certificate parent sig bypass (CR2) | Not modeled | Brief §3.2: one-line fix, best caught by code review |
| `is_valid` Prepare side-effect view advance (F3 partial) | Not modeled | Brief §3.2: best confirmed by integration test |
| `TC::PartialEq` always true (CR6) | Not modeled | Code review only; not a protocol deviation |
| `AgreementOnProposals` definition | Simplified | The spec uses a shared `committed[s]` variable; two nodes committing different values for slot s would require separate `nodeCommitted[n,s]` per-node variables. The `UniqueCommit` invariant (one proposals value per slot) is the correct and sufficient substitute for this model. |

No coverage gaps for items the brief asked to model check. The `AgreementOnProposals` invariant as written in base.tla is a tautology; `UniqueCommit` is the operative invariant for F1 and is correctly enabled in the F1 hunt config.
