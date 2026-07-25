# Solana Tower BFT — Spec Convergence Changelog

System: anza-xyz/agave Tower BFT. Category A (distributed), Byzantine threat model.

## Round 1 - Trace Validation
- All 4 traces pass on first attempt (scenario_basic_voting_pipeline, scenario_crash_before_fsync, scenario_oc_threshold_slot1, scenario_two_fork_persistence). No fixes needed.

## Round 1 - Model Checking
- [fix-cfg] MC.cfg: added `CHECK_DEADLOCK FALSE` (Case A). Bounded-counter simulation reaches a terminal state when all Byzantine counters, crash counters, and slot-bounds (MaxSlot=3) are exhausted — TLC reported this as a deadlock, but it is the expected end of the bounded-model trace. Same change applied to all MC_hunt_*.cfg files.
- [pass] 30-min simulation run completed: 2.546B states checked, 24.87M traces generated, no invariant violations. Spec converged.

## Result
Converged in 1 round. Proceeding to bug hunting.

## Round 2 - Bug Hunting
- [fix-spec] RecordVote: added `voteSlot \notin purgedView[v]` precondition (Case B). The Family 4 simulation found a purge-then-vote sequence that violated TowerVotesAreOnExistingForks; the implementation's `purge_unconfirmed_slot` removes the slot's bank from `bank_forks`, so `select_vote_and_reset_forks` cannot pick a purged slot. The fix restores the implementation's invariant. The vote-then-purge stranding pattern (the brief's intended Case C target) is unaffected and remains detectable.
- [fix-spec] PurgeUnconfirmedSlot: tightened precondition (Case B). Previously fired on any `duplicateConfirmed[slot] /= {}`; the implementation (replay_stage.rs:1809 `dump_then_repair_correct_slots`) only purges when v's local bank hash disagrees with the duplicate-confirmed hash. Added `\E h \in duplicateConfirmed[slot] : h /= CanonicalSlotHash[slot]`. Tower-stranding via Byzantine-injected non-canonical dup-conf remains reachable as the intended Case C pattern.
- [bug] **Family 4 / MC-5 — NoDualHashDuplicateConfirm**: Case C real bug confirmed. Byzantine equivocation on slot 2 (`ByzVoteOnBothForks(v4,2,hB,hA)`) + two `ByzInjectDupConfirmSignal` messages with conflicting hashes drives two honest validators (v3, v1) to record different `duplicateConfirmed[2]` hashes. The `assert_eq!(prev_hash, duplicate_confirmed_hash)` at `core/src/replay_stage.rs:2231` panics any honest validator that receives both signals, causing a process-death liveness halt. Trace length 9. See `output/MC_hunt_family4_sim3.out`.
- [bug] **Family 4 / MC-6 — TowerVotesAreOnExistingForks**: Case C real bug confirmed via `MC_hunt_family4_mc6.cfg` (NoDualHashDuplicateConfirm temporarily disabled to expose MC-6 separately). Honest v1 votes on (1, hA) — its canonical hash. Byzantine then injects `DupConf(1, hB)` for the non-canonical hash. v1 processes it, then `purge_unconfirmed_slot(1)` runs: `bank_forks` loses slot 1 but the tower retains the (1, hA) vote — the stranded-tower hazard the brief flags. Matches the historical impl issue addressed by commit `c2bb2b8e60` / PR #28172. Trace length 11. See `output/MC_hunt_family4_mc6_sim.out`.
- [no-bug] Family 3 at f=2 (`MC_hunt_family3_f2.cfg`, Byzantine={v3,v4}): 3.8B states, NoDualHashOC holds. Spec models honest validators as voting on `CanonicalSlotHash[slot]`, so a network-partition-driven honest split (the only way to admit dual-hash OC under the f<n/3 + honest-canonical assumption) is not expressible. The MC-1 hypothesis is unfalsifiable in this abstraction — documented as a limitation in the bug report.

## Final Result
Converged in 1 round. Bug hunting: **2 Case C bugs found** (Family 4 MC-5 dual-hash dup-conf panic, Family 4 MC-6 tower stranding via purge). Both correspond to known/historical implementation issues. See `bug-report.md`. Families 1, 2, 3, 5 produced no violations across ~15B simulated states.

