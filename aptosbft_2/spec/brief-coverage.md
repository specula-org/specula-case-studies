# Brief Coverage Self-Audit — Aptos BFT (round 2)

This document maps the modeling brief's §2 Bug Families, §5 Proposed
Invariants, and §6.1 Model-Checkable Findings to the spec/MC artifacts
generated in this round.  Filled from the actual `.cfg` file contents,
not from intent.

System category recorded in the brief: **Category A (distributed /
message-passing) with a BFT Byzantine adversary overlay**.

## Table 1 — Bug Families (brief §2 → hunt cfg)

| Brief Family | Hunt cfg file | Family-relevant invariants enabled in that cfg | If skipped, why? |
|---|---|---|---|
| Family 1 — Crash-window double vote with Byzantine equivocating proposer | `MC_hunt_family1.cfg` | `NoDoubleVote`, `RecoverPreservesLastVote`, `Agreement`, `CommitSafety` | — |
| Family 2 — Order-vote vs regular-vote / timeout guard asymmetry | `MC_hunt_family2.cfg` | `NoCrossPathSign`, `OrderVoteAggregatorDedup`, `Agreement`, `CommitSafety` | — |
| Family 3 — Certificate / message value-binding gaps | `MC_hunt_family3.cfg` | `QCValueBound`, `TCQuorumPower`, `CommitEpochBound`, `Agreement`, `CommitSafety` | — |
| Family 4 — Cross-epoch replay | `MC_hunt_family4.cfg` | `OrderVoteEpochBound`, `Agreement`, `CommitSafety` | — |
| Family 5 — Pipeline race / decoupled-execution non-atomicity | `MC_hunt_family5.cfg` (narrow MC subset only) | `CommitEpochBound`, `Agreement`, `CommitSafety` | Brief §2 explicitly says the MC-suitable subset of Family 5 is the commit-vote signing-without-persist gap; the deeper persistence and lock-ordering issues are tagged §6.2 test-verifiable.  The narrow subset is targeted by this cfg via `Crash + SignCommitVote` composition; deeper findings (T-1..T-9) are deferred to integration tests. |
| Family 6 — Recovery / sync state divergence | (merged into `MC_hunt_family1.cfg`) | (covered by `NoDoubleVote` + `RecoverPreservesLastVote` under `Crash; Recover`) | Brief explicitly says Family 6 is *largely covered by composing Crash (5.1) with Snapshot/StateTransfer (5.6)*; we model the Crash/Recover composition in Family 1's hunt cfg so a separate `family6.cfg` would be a duplicate.  Documented merger. |
| Family 7 — Optimistic-proposal bypass | (no dedicated hunt cfg) | (covered by `ProposeOpt` action existing in base spec; `Agreement` invariant in convergence cfg) | Brief tags Family 7 as Low-Medium with no §5 invariant and no §6.1 finding.  The brief's modeling guidance ("model `ProposeOpt` as a distinct proposal action without an author signature") is realised in the base spec.  No MC-N finding to hunt; remaining concern relies on network-layer authentication assumptions outside the scope of this spec. |

## Table 2 — Proposed Invariants (brief §5 → hunt cfg enablement)

| Brief invariant | Defined at | Wired in MC.tla? | Enabled in which hunt cfg(s)? | If skipped, why? |
|---|---|---|---|---|
| `Agreement` | `base.tla:732` | yes (inherited via `EXTENDS base`) | `MC.cfg`, `MC_hunt_family1.cfg`, `MC_hunt_family2.cfg`, `MC_hunt_family3.cfg`, `MC_hunt_family4.cfg`, `MC_hunt_family5.cfg` | — |
| `NoDoubleVote` | `base.tla:741` | yes | `MC_hunt_family1.cfg` | — |
| `NoCrossPathSign` | `base.tla:747` | yes | `MC_hunt_family2.cfg` | — |
| `OrderVoteAggregatorDedup` | `base.tla:758` | yes | `MC_hunt_family2.cfg` | — |
| `QCValueBound` | `base.tla:771` | yes | `MC_hunt_family3.cfg` | — |
| `TCQuorumPower` | `base.tla:781` | yes | `MC_hunt_family3.cfg` | — |
| `CommitEpochBound` | `base.tla:787` | yes | `MC_hunt_family3.cfg`, `MC_hunt_family5.cfg` | — |
| `OrderVoteEpochBound` | `base.tla:797` | yes | `MC_hunt_family4.cfg` | — |
| `RecoverPreservesLastVote` | `base.tla:810` | yes | `MC_hunt_family1.cfg` | — |
| `CommitSafety` (standard) | `base.tla:818` | yes | `MC.cfg` + every hunt cfg | — |

Line numbers above are 1-indexed approximations of where the invariant
definition begins; precise locations can be checked with grep against
`base.tla`.  Every §5 Safety invariant is enabled in ≥1 hunt cfg.

## Table 3 — Model-Checkable Findings (brief §6.1 → hunt cfg)

| Finding ID | Trigger mechanism (action / fault) | Expected violated invariant | Hunt cfg targeting it |
|---|---|---|---|
| MC-1 | `ByzEquivocateProposer(s, r, v1, v2)` at round r + `Crash(h)` between `SignVote(h)` and `CompletePersistVote(h)` + `Recover(h)` + `SignVote(h)` again with v2 | `NoDoubleVote`, `RecoverPreservesLastVote` | `MC_hunt_family1.cfg` |
| MC-2 | `SignVote(h, r, v1)` then Byzantine supplies a different proposal at r and h calls `SignOrderVote(h, r)` with v2 (no last_voted_round guard on order-vote path) | `NoCrossPathSign` | `MC_hunt_family2.cfg` |
| MC-3 | `ByzEquivocateOrderVote(byz, r, v1, v2)` contributes one Byzantine signature to two distinct digests' aggregators | `OrderVoteAggregatorDedup` (and propagates to `Agreement`) | `MC_hunt_family2.cfg` |
| MC-4 | `ByzReuseRealCertificate(byz, cert, v_rebound)` mutates `vote_data` on a real WrappedLedgerInfo; an honest node accepts the rebound order-vote message | `QCValueBound` | `MC_hunt_family3.cfg` |
| MC-5 | `SignCommitVote(h, r, e_bad)` where `e_bad /= persistedSafetyData[h].epoch` — sign_commit_vote has no verify_epoch | `CommitEpochBound` | `MC_hunt_family3.cfg`; also in `MC_hunt_family5.cfg` |
| MC-6 | `ByzCrossEpochReplay(byz, cert, newEpoch)` + `ReceiveOrderVoteWeakEpoch(h, m)` accepts a message with `mInnerQCEpoch /= mepoch` | `OrderVoteEpochBound` | `MC_hunt_family4.cfg` |
| MC-7 | `SignTimeout(h, r)` then `Crash(h)` then `Recover(h)` then `EchoTimeout(h, r)` re-signs at the same round (safe_to_timeout admits `round == last_voted_round`) | `NoDoubleVote` (timeout variant) | `MC_hunt_family1.cfg` |

## Coverage Summary

```
Families: 5 / 7 implemented + 2 merged
  - Family 1, 2, 3, 4, 5 each have a dedicated hunt cfg.
  - Family 6 merged into Family 1 (Crash; Recover composition).
  - Family 7 covered by ProposeOpt action in base; no §5 invariant.
Proposed Safety Invariants: 10 / 10 enabled in ≥1 hunt cfg.
  (Agreement, NoDoubleVote, NoCrossPathSign, OrderVoteAggregatorDedup,
   QCValueBound, TCQuorumPower, CommitEpochBound, OrderVoteEpochBound,
   RecoverPreservesLastVote, CommitSafety.)
Model-Checkable Findings: 7 / 7 targeted by a hunt cfg.
Hunt cfg files: 5 (family1..family5).
```

No invariant is defined-but-not-enabled.  Every brief §5 Safety invariant
appears in the `INVARIANTS` section of at least one hunt cfg, verified
by reading the actual `.cfg` file contents.
