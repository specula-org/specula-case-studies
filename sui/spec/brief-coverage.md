# Brief Coverage Self-Audit — Sui Mysticeti

This audit maps the modeling brief's §2 Bug Families, §5 Proposed
Invariants, and §6.1 Model-Checkable Findings to the spec/MC artifacts
generated in this directory.

The "Enabled in which hunt cfg(s)" column reflects what is *actually
listed* in each cfg file (verified by inspection), not what was intended.

## Table 1: Bug Families (brief §2)

| Brief Family | Hunt cfg file | Family-relevant invariants enabled | If skipped, why? |
|---|---|---|---|
| F1 Equivocation handling at slot | `MC_hunt_family1.cfg` | `TypeOK`, `CommitAgreement`, `CommitDigestAgreement`, `LeaderCommitMonotonic` | — |
| F2 Amnesia recovery (f+1 vs 2f+1) | `MC_hunt_family2.cfg` | `TypeOK`, `NoOwnEquivocation` | — |
| F3 GC × Commit Rule interactions | `MC_hunt_family3.cfg` | `TypeOK`, `CommitRecursionDecidable` | — |
| F4 Leader timeout / threshold clock / proposer | `MC_hunt_family4.cfg` (assertion) + `MC_hunt_family4_multileader.cfg` (latent path) | `TypeOK`, `ForcePropose2f1Parents`; `MultiLeaderCommitOrdering` | — |
| F5 Byzantine input validation gaps | (none — out of modeling scope) | — | Per brief §2 Family 5 priority "Low for modeling": items #1,#3,#4,#5 are implementation-only; only #2 (commit-vote equivocation) is protocol-relevant, and the modeling brief §2 explicitly defers it to test-verifiable T4 (commit_vote_monitor.rs:33-40 max-only tracking). The commit-vote field is carried in the block schema (`commitVotes`) so a future hunt cfg can be added without spec changes. |

## Table 2: Proposed Invariants (brief §5)

| Brief invariant | Defined at | Wired in MC.tla? | Enabled in which hunt cfg(s)? | If skipped, why? |
|---|---|---|---|---|
| **CommitAgreement** | `base.tla:854` | yes (extends base) | `MC_hunt_family1.cfg` | — |
| **CommitDigestAgreement** | `base.tla:865` | yes | `MC_hunt_family1.cfg` | — |
| **NoOwnEquivocation** | `base.tla:886` | yes | `MC_hunt_family2.cfg` | — |
| **CommitRecursionDecidable** | `base.tla:898` | yes | `MC_hunt_family3.cfg` | — |
| **ForcePropose2f1Parents** | `base.tla:916` | yes | `MC_hunt_family4.cfg` | — |
| **LeaderCommitMonotonic** | `base.tla:873` | yes | `MC_hunt_family1.cfg` | — |
| **CommitTimestampMonotonic** | (not defined) | n/a | (none) | Brief §5 explicitly marks this "test-verifiable, not modeled" (F5). Linearizer's `.max(last_commit_timestamp_ms)` is enforced post-hoc; the borderline finding MC6 demotes it to test-verifiable. The block schema carries `timestamp` so a future re-modeling can add this without spec changes. |
| **DAGEventualConsensus** | `base.tla:957` | wired as Liveness | (none) | Liveness invariant — out of audit scope per `brief-coverage-checklist.md`. Defined in base for documentation. |
| **AmnesiaRecoveryProgress** | `base.tla:951` | wired as Liveness | (none) | Liveness invariant — out of audit scope. |
| **NoStuckProposer** | (not defined as named invariant) | n/a | (none) | Liveness invariant — out of audit scope. ForcePropose2f1Parents is the safety counterpart and is enabled in F4 hunt. |

## Table 3: Model-Checkable Findings (brief §6.1)

| Finding ID | Trigger mechanism (action / fault) | Expected violated invariant | Hunt cfg targeting it |
|---|---|---|---|
| **MC1** | `MCByzPropose` (≥2 distinct digests at same slot) + 2 honest validators with different `MCDeliverBlock` orderings + `MCLinearize` | `CommitDigestAgreement` (or `CommitAgreement`) | `MC_hunt_family1.cfg` (`MaxByzProposeLimit=4`, `MaxDigest=2`) |
| **MC2** | `MCCrash(s)` (s honest) + `MCRecoverAmnesia(s)` with f+1 responders underreporting (Byzantine + un-informed-honest) + post-recovery `MCHonestPropose(s)` re-signing prior round | `NoOwnEquivocation` | `MC_hunt_family2.cfg` (`MaxCrashLimit=1`, `MaxRecoverLimit=1`) |
| **MC3** | Asymmetric `MCLinearize` progress → divergent `gcRound[s]` across honest validators + `MCByzPropose` with fabricated ancestor digests + `MCTryDirectDecide` recursing through missing block | `CommitRecursionDecidable` | `MC_hunt_family3.cfg` (`GCDepth=1` to surface divergent gc rounds) |
| **MC4** | `MCAddCertifiedCommit(s, R)` advances `clockRound[s]` past local DAG completeness + `MCForcePropose(s)` fires before `MCDeliverBlock` catches up | `ForcePropose2f1Parents` | `MC_hunt_family4.cfg` (`MaxCertCommitLimit=2`, `MaxForceProposeLimit=2`) |
| **MC5** | Multi-leader election (`MultiLeaderOf` with offset 0..1) + commit at high offset before low offset visited | `MultiLeaderCommitOrdering` | `MC_hunt_family4_multileader.cfg` |
| **MC6** | `MCByzPropose` with `timestamp = MaxTimestamp` becoming honest leader's parent | `CommitTimestampMonotonic` (preserved post-hoc) — borderline | (none — demoted to test-verifiable per brief §6.1 last row, "may demote to test-verifiable"). Block schema carries `timestamp` if re-modeled. |

## Coverage Summary

```
Families:           4 / 5 implemented + 0 partial  (skipped: F5 — protocol-out-of-scope per brief §2 priority "Low for modeling")
Proposed Safety Invariants: 6 / 7 enabled in ≥1 hunt cfg  (skipped: CommitTimestampMonotonic — brief explicitly marks test-verifiable, not modeled)
Model-Checkable Findings:  5 / 6 targeted by a hunt cfg   (skipped: MC6 — brief §6.1 marks borderline / demote-to-test)
Hunt cfg files:     5 (MC_hunt_family1.cfg, MC_hunt_family2.cfg, MC_hunt_family3.cfg, MC_hunt_family4.cfg, MC_hunt_family4_multileader.cfg)
```

## Notes on skip justifications

- **F5 (Byzantine input validation gaps)**: brief §2 explicitly tags this
  family as "Low for modeling, High for code review." Items 1, 3, 4, 5
  are implementation-level (timestamp validation gap, OOM, round-prober
  bias, ancestor exclusion) — none are protocol invariants. Item 2
  (commit-vote equivocation) is a single line of monitor code; the brief
  routes it to T4 test-verifiable. The `commitVotes` field on `Block` is
  in the spec schema so a future hunt cfg can enable it without
  refactoring.
- **CommitTimestampMonotonic**: brief §5 row explicitly notes "already
  enforced post-hoc; the question is whether a Byzantine far-future
  timestamp can stick permanently. F5 (mark as test-verifiable, not
  modeled)". Linearizer's `timestamp_ms.max(last_commit_timestamp_ms)`
  guarantees the monotonic property structurally; the F5 client-impact
  question is observational, not a protocol invariant.
- **Liveness invariants** (`DAGEventualConsensus`,
  `AmnesiaRecoveryProgress`, `NoStuckProposer`): out of audit scope per
  `brief-coverage-checklist.md`. The first two are defined in `base.tla`
  for completeness; enabling them in hunt cfgs requires fairness
  annotations that would conflict with bounded fault counters.
