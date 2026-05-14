# Brief Coverage Self-Audit — Solana Tower BFT

This document maps the modeling brief's §2 (Bug Families), §5 (Proposed Invariants), and §6.1 (Model-Checkable Findings) to the spec artifacts in this directory.

Brief: `/home/ubuntu/Specula/case-studies/solana/.specula-output/modeling-brief.md`

## Table 1: Bug Families (from brief §2)

| Brief Family | Hunt cfg file | Family-relevant invariants enabled in that cfg | If skipped, why? |
|---|---|---|---|
| Family 1 — Tower Adoption & Crash-Recovery Hazards | `MC_hunt_family1_tower_adoption.cfg` | LockoutSafety, TowerConsistentWithPersistedAfterCrash, AdoptOnChainTowerNoLossOfDurableVote | — |
| Family 2 — Switch-Threshold Manipulability via Gossip Latest Votes | `MC_hunt_family2_switch_threshold.cfg` | SwitchProofRequiresRealLockout, LockoutSafety | — |
| Family 3 — Optimistic Confirmation Equivocation Accounting | `MC_hunt_family3_oc_equivocation.cfg` | NoDualHashOC, OCRollbackBounded, NoEquivocatingVoteFromHonest | — |
| Family 4 — Duplicate-Slot Reconciliation & Fork-Choice State Hazards | `MC_hunt_family4_dup_confirm.cfg` | NoDualHashDuplicateConfirm, TowerVotesAreOnExistingForks, NoHonestPanic | — |
| Family 5 — Lockout Defense-in-Depth Gaps | `MC_hunt_family5_lockout_depth.cfg` | LockoutSafety, RootedSlotsForkConsistent, NoEquivocatingVoteFromHonest | — |
| Family 6 — Migration & Identity-Swap Window | (no hunt cfg) | n/a | Brief §2.6 explicitly says "Do not model". Operational concerns; well-covered by integration tests. |

## Table 2: Proposed Invariants (from brief §5)

| Brief invariant | Defined at (file:line) | Wired in MC.tla? | Enabled in which hunt cfg(s)? | If skipped, why? |
|---|---|---|---|---|
| LockoutSafety | base.tla:858 | yes (inherited via EXTENDS) | `MC_hunt_family1_tower_adoption.cfg`, `MC_hunt_family2_switch_threshold.cfg`, `MC_hunt_family5_lockout_depth.cfg` | — |
| NoDualHashOC | base.tla:865 | yes | `MC_hunt_family3_oc_equivocation.cfg` | — |
| OCImpliesEventualRoot (Liveness) | n/a — phrased as `OCEventuallyRooted` in MC.tla | yes (PROPERTIES, commented out in MC.cfg) | none (liveness, out of audit scope per `brief-coverage-checklist.md` §"Liveness... explicitly out of scope") | Liveness only; check via simulation, not BFS hunt |
| OCRollbackBounded | base.tla:871 | yes | `MC_hunt_family3_oc_equivocation.cfg` | — |
| NoDualHashDuplicateConfirm | base.tla:882 | yes | `MC_hunt_family4_dup_confirm.cfg` | — |
| SwitchProofRequiresRealLockout | base.tla:891 | yes | `MC_hunt_family2_switch_threshold.cfg` | — |
| TowerConsistentWithPersistedAfterCrash | base.tla:903 | yes | `MC_hunt_family1_tower_adoption.cfg` | — |
| AdoptOnChainTowerNoLossOfDurableVote | base.tla:909 | yes | `MC_hunt_family1_tower_adoption.cfg` | — |
| TowerVotesAreOnExistingForks | base.tla:916 | yes | `MC_hunt_family4_dup_confirm.cfg` | — |
| NoEquivocatingVoteFromHonest | base.tla:852 | yes | `MC_hunt_family3_oc_equivocation.cfg`, `MC_hunt_family5_lockout_depth.cfg` | — |
| RootedSlotsForkConsistent | base.tla:923 | yes | `MC_hunt_family5_lockout_depth.cfg` | — |

## Table 3: Model-Checkable Findings (from brief §6.1)

| Finding ID | Trigger mechanism (action / fault) | Expected violated invariant | Hunt cfg targeting it |
|---|---|---|---|
| MC-1 | `MCByzVoteOnBothForks` (Byzantine equivocation, ≥1/3 stake) + multiple `ReachOC` | `NoDualHashOC` | `MC_hunt_family3_oc_equivocation.cfg` |
| MC-2 | `MCCrash` between `RecordVote`/`PersistTower`/`BroadcastVote` + `Restart` + `MCAdoptOnChainTowerIfBehind` + `MCByzCraftBankVoteState` | `LockoutSafety` (and `AdoptOnChainTowerNoLossOfDurableVote`) | `MC_hunt_family1_tower_adoption.cfg` |
| MC-3 | `MCByzGossipFakeLatestFrozenVote` campaign + `CastSwitchVote` | `SwitchProofRequiresRealLockout` | `MC_hunt_family2_switch_threshold.cfg` |
| MC-4 | Same as MC-1 plus `RootSlot` on a different hash | `OCRollbackBounded` | `MC_hunt_family3_oc_equivocation.cfg` |
| MC-5 | `MCByzInjectDupConfirmSignal` with two distinct hashes for one slot | `NoDualHashDuplicateConfirm`, `NoHonestPanic` (liveness halt) | `MC_hunt_family4_dup_confirm.cfg` |
| MC-6 | `PurgeUnconfirmedSlot` (with tower retaining the purged slot) then `CastSwitchVote` | `TowerVotesAreOnExistingForks`, `NoHonestPanic` | `MC_hunt_family4_dup_confirm.cfg` |
| MC-7 | `MCByzReuseStaleGossipVote` (stale gossip-vote replay across root advances) | `SwitchProofRequiresRealLockout` | `MC_hunt_family2_switch_threshold.cfg` (via `MaxByzReuseLimit > 0`) |
| MC-8 | Crash-before-fsync (`MCCrashBeforeFsync`) with a future tower (`MCByzCraftBankVoteState`) + same-fork CastVote | `LockoutSafety` | `MC_hunt_family1_tower_adoption.cfg` |

## Coverage Summary

```
Families: 5 / 6 implemented + 0 partial (skipped: Family 6 — explicitly out of scope per brief §2.6)
Proposed Safety Invariants: 10 / 11 enabled in >=1 hunt cfg
  - 10 safety invariants from brief §5 are enabled in at least one hunt cfg.
  - 1 brief §5 entry is liveness (OCImpliesEventualRoot, listed as `OCEventuallyRooted` in MC.tla)
    and is out of audit scope per `brief-coverage-checklist.md` — checked via PROPERTIES in simulation.
Model-Checkable Findings: 8 / 8 targeted by a hunt cfg
Hunt cfg files: 5 (one per implemented bug family)
```

## Notes

1. **MC.cfg vs hunt cfgs.** `MC.cfg` is the convergence config — it disables all extension invariants and runs only structural / sanity invariants, in line with `mc-spec-pattern.md` §"Config Pattern". Bug-family invariants are listed but commented out, and are explicitly re-enabled in each `MC_hunt_*.cfg`.

2. **Per-family bound philosophy.** Each `MC_hunt_<family>.cfg` zeroes the counters for adversary actions not relevant to that family (`MaxByzEquivLimit = 0` in `MC_hunt_family1`, etc.) so the focused state space is reachable. The relevant counters are set to 1-3 depending on the depth of attack the brief identifies.

3. **`NoHonestPanic` semantics.** Family 4's `assert_eq!` at `replay_stage.rs:2226` triggers process-death; we encode this as `panicked[v] := TRUE` and `alive[v] := FALSE`. The hunt cfg uses `NoHonestPanic` as a structural safety invariant whose violation means "the dual-hash duplicate-confirm sequence reached the panic site for an honest validator". This is the model-checkable analog of the liveness halt brief §6.1 MC-5 / MC-6 identify.

4. **`SwitchProofRequiresRealLockout` interpretation.** The brief states the goal as: "`SwitchProof(s)` decision requires ≥38% real on-chain locked-out stake (not gossip-only claims)". The spec encodes this as a post-state invariant on the tower: any cross-fork vote in v's tower must have been backed by ≥38% real (on-chain) lockout stake. A violation means a Byzantine gossip campaign convinced an honest validator to cast a switch vote that would have failed if only on-chain votes were counted.

5. **`OCRollbackBounded` interpretation.** Brief §6.1 MC-4 asks the model to find "the exact OC-rollback bound". The invariant is phrased as: if `(s, h) ∈ ocConfirmed` and `rooted[s] = TRUE` with `rootedHash[s] /= h`, then ≥1/3 of stake is Byzantine. Violations under f < n/3 are forward-looking findings (no such finding has been previously documented for Tower BFT).

6. **Family 6 deferral.** The brief explicitly says "Do not model" for the Alpenglow/Votor migration and identity-swap races. No hunt cfg targets Family 6.

7. **Adversary categorization.** The Byzantine actions defined in `base.tla` map to `bft-analysis.md` adversary categories as documented in the `MC.tla` header (2.1 Equivocation, 2.5 Replay, 2.6 Amnesia, 2.7 Cert manipulation). Each is counter-bounded by a dedicated `MaxByz*Limit`.
