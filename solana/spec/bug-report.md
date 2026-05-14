# Bug Report — Solana Tower BFT (anza-xyz/agave)

## Summary

- **Bug families tested**: 5 (per `modeling-brief.md`)
- **Bugs found**: 2 (both Case C, both in Family 4)
- **Configs run**: `MC.cfg` (convergence), `MC_hunt_family1_tower_adoption.cfg`,
  `MC_hunt_family2_switch_threshold.cfg`, `MC_hunt_family3_oc_equivocation.cfg`,
  `MC_hunt_family3_f2.cfg` (Byzantine-stake-boundary probe),
  `MC_hunt_family4_dup_confirm.cfg`, `MC_hunt_family4_mc6.cfg` (MC-6 probe),
  `MC_hunt_family5_lockout_depth.cfg`.
- **Total states explored**: ≈ 15 billion across all simulation runs.
- **Method**: TLC simulation, 30 min × run, 48 workers, 30G heap / 100G off-heap.
  BFS was used for MC.cfg convergence (140M states at depth 16 before resource limit) and
  simulation for the bounded-fault hunting configs.

The two findings — MC-5 (dual-hash duplicate-confirm panic) and MC-6 (tower
stranding via purge) — are the two model-checkable hazards the brief
(§6.1) flagged for Family 4. Both correspond to known/historical implementation
behaviors; neither is a previously-unknown safety violation.

---

## Bug 1: Dual-Hash Duplicate-Confirm Panic (MC-5)

- **Bug Family**: 4 — Duplicate-Slot Reconciliation & Fork-Choice State Hazards
- **Severity**: High (process-death liveness halt)
- **Invariant violated**: `NoDualHashDuplicateConfirm`
- **Config**: `MC_hunt_family4_dup_confirm.cfg`
- **Counterexample**: 9 states. Output: `spec/output/MC_hunt_family4_sim3.out`.

### Trace Summary

| Step | Action | Effect |
|------|--------|--------|
| 1 | `MCInit` | initial state, all towers empty |
| 2 | `ByzVoteOnBothForks(v4, 2, hB, hA)` | Byzantine v4 emits two vote-tx for slot 2 on conflicting hashes; both land in `msgs` |
| 3 | `RecordVote(v3, 3, hB)` | honest v3 votes for (3, hB) — irrelevant decoration |
| 4 | `RecordVote(v4, 1, hA)` | v4 votes (1, hA) — irrelevant decoration |
| 5 | `ByzInjectDupConfirmSignal(2, hA)` | Byzantine injects a `DupConf(2, hA)` message |
| 6 | `ByzInjectDupConfirmSignal(2, hB)` | Byzantine injects a *second* `DupConf(2, hB)` for the SAME slot, different hash |
| 7 | `ByzInjectDupConfirmSignal(3, hA)` | irrelevant decoration |
| 8 | `ProcessDuplicateConfirmedSignal(v3, 2, hB)` | v3 consumes the first signal: `duplicateConfirmed[2] := {hB}` |
| 9 | `ProcessDuplicateConfirmedSignal(v1, 2, hA)` | v1 consumes the second signal: `duplicateConfirmed[2]` already contains `hB`, new hash `hA` arrives → `assert_eq!` site fires → v1 panics. `duplicateConfirmed[2] := {hA, hB}` — INVARIANT VIOLATED |

### Root Cause

`core/src/replay_stage.rs:2205-2254` — `process_duplicate_confirmed_slots`
contains the panic site at line 2231:

```rust
assert_eq!(prev_hash, duplicate_confirmed_hash,
    "Additional duplicate confirmed notification for slot {} with a different hash");
```

This `assert_eq!` panics the validator process when two duplicate-confirmed
notifications for the same slot arrive carrying different bank hashes. Per the
brief's Family 4 analysis, "stake threshold (≥0.52 per side) means panic fires
precisely under ≥1/3 Byzantine equivocation". A Byzantine coalition that can
drive the cluster to duplicate-confirm two distinct hashes for the same slot
forces every honest validator that observes both signals to panic.

The spec abstracts the cluster's 0.52 dup-conf threshold by allowing
`ByzInjectDupConfirmSignal` to directly inject a `DupConfMsg` (modeling either a
Byzantine validator with ≥0.52 stake or coordinated Byzantine+honest split that
satisfies the threshold). The counterexample thus represents a real-world
attack surface even though our 1-Byzantine config (Byzantine = {v4}, 25% stake)
is below 0.52 by itself.

### Affected Code

- `core/src/replay_stage.rs:2205-2254` — `process_duplicate_confirmed_slots` (panic site at :2231)
- `core/src/cluster_info_vote_listener.rs:144-155` — `purge_stale_state` (root-tied cleanup, does not catch dual-hash before assert)
- `core/src/consensus/vote_stake_tracker.rs:14-38` — per-(slot, hash) stake accumulator (no cross-hash dedup at this layer)

### Recommendation

Replace `assert_eq!` with a warn-and-discard behavior that records the
dual-hash event in a metric, drops the second signal, and proceeds. The
existing `BankHashCache` removal commit `207fb1d00` (#10594, 2026-02-19) shows
the team is actively reworking this path; converting the panic to a
non-fatal slashable-equivocation report is the impl-friendly form of the
fix the spec invariant requires.

---

## Bug 2: Tower-Stranding via PurgeUnconfirmedSlot (MC-6)

- **Bug Family**: 4 — Duplicate-Slot Reconciliation & Fork-Choice State Hazards
- **Severity**: Medium (liveness hazard — validator stranded but no safety violation; recovery requires the historical `c2bb2b8e60` reset path)
- **Invariant violated**: `TowerVotesAreOnExistingForks`
- **Config**: `MC_hunt_family4_mc6.cfg` (variant of family 4 hunt with `NoDualHashDuplicateConfirm` disabled so the MC-6 trace isn't preempted by MC-5)
- **Counterexample**: 11 states. Output: `spec/output/MC_hunt_family4_mc6_sim.out`.

### Trace Summary

| Step | Action | Effect |
|------|--------|--------|
| 1 | `MCInit` | initial state |
| 2 | `ByzVoteOnBothForks(v4, 2, hB, hA)` | Byzantine v4 equivocates on slot 2 |
| 3 | `RecordVote(v3, 1, hA)` | honest v3 votes (1, hA) — the canonical hash |
| 4 | `RecordVote(v1, 1, hA)` | honest v1 votes (1, hA); tower[v1] = [(1, hA)] |
| 5 | `RecordVote(v2, 3, hB)` | irrelevant decoration |
| 6 | `ByzInjectDupConfirmSignal(1, hB)` | Byzantine injects `DupConf(1, hB)` — **hB ≠ CanonicalSlotHash[1] = hA**, so this represents a "different-than-my-vote" hash |
| 7 | `ProcessDuplicateConfirmedSignal(v1, 1, hB)` | v1 records `duplicateConfirmed[1] := {hB}` |
| 8 | `RecordVote(v4, 1, hA)` | v4 also votes (1, hA) — irrelevant |
| 9 | `ByzInjectDupConfirmSignal(2, hA)` | irrelevant |
| 10 | `PurgeUnconfirmedSlot(v4, 1)` | v4 purges slot 1 |
| 11 | `PurgeUnconfirmedSlot(v1, 1)` | v1 purges slot 1. After: `tower[v1].votes = [(1, hA)]` AND `1 ∈ purgedView[v1]` — INVARIANT VIOLATED |

### Root Cause

`core/src/replay_stage.rs:2019-2124` — `purge_unconfirmed_slot` clears
`bank_forks`, `ancestors`, `descendants`, `progress`, and the blockstore for
the slot **but does not mutate the Tower struct**. The Tower retains its vote
on the slot whose bank has just been removed. From this stranded state:

- `select_vote_and_reset_forks` (fork_choice.rs) picks a heaviest bank to
  reset to. Per `core/src/consensus.rs:1100-1109`, the assertion `"Should
  never consider switching to ancestor"` can fire if the heaviest pick is an
  ancestor of `tower.last_voted_slot` — a state the purge made reachable.
- Recovery requires the manual "reset to slot which matches their last voted
  slot" path added by commit `c2bb2b8e60` (PR #28172, 2022-10-03), which is
  precisely the impl-side fix that the brief cites as direct evidence of
  this hazard.

### Affected Code

- `core/src/replay_stage.rs:2019-2124` — `purge_unconfirmed_slot` (the asymmetric mutation; does not touch tower)
- `core/src/replay_stage.rs:1809` — `dump_then_repair_correct_slots` (call site that triggers the purge)
- `core/src/consensus.rs:1100-1109` — "Should never consider switching to ancestor" panic site that the stranded tower can trigger
- Historical: PR #28172 / commit `c2bb2b8e60` — the reset-to-last-voted-slot fix

### Recommendation

Two layered fixes:

1. **Atomic purge+tower-adjust**: when `purge_unconfirmed_slot(s)` removes
   slot `s` from `bank_forks`, simultaneously roll the Tower back to the
   deepest non-purged vote (or trigger the `c2bb2b8e60` reset path) so the
   invariant `last_voted_slot ∉ purgedView` holds by construction.

2. **Defensive assertion at the next vote**: `record_bank_vote_and_update_lockouts`
   (`consensus.rs:700`) should refuse to vote when `tower.last_voted_slot`
   refers to a slot not in `bank_forks`, surfacing the stranded state as a
   loud error instead of silently piling up further votes that then trip
   the line 1100 panic.

---

## Not Reproduced

| Bug Family | Brief Hypothesis | Config | States | Result |
|------------|------------------|--------|--------|--------|
| 1 — Tower adoption/crash recovery | MC-2 (crash between record/persist/broadcast + AdoptOnChainTower poisons tower), MC-8 (future-tower from snapshot evades empty-ancestor suspension) | `MC_hunt_family1_tower_adoption.cfg` | 1.49 B states / 24 M traces, 30 min sim | No invariant violation. `LockoutSafety`, `TowerConsistentWithPersistedAfterCrash`, `AdoptOnChainTowerNoLossOfDurableVote` all hold. (BFS hit JVM crash at depth 16 with 779 M states; simulation followed up — also clean.) |
| 2 — Switch-threshold manipulability | MC-3 (Byzantine fake gossip latest-vote inflates switch-threshold), MC-7 (stale gossip vote reuse after root advance) | `MC_hunt_family2_switch_threshold.cfg` | 1.86 B states / 8.24 M traces, 30 min sim | No invariant violation. `SwitchProofRequiresRealLockout`, `LockoutSafety` hold. |
| 3 — OC equivocation accounting (f = 1) | MC-1 (dual-hash OC reaches 2/3), MC-4 (OC rollback bound) | `MC_hunt_family3_oc_equivocation.cfg` | 2.88 B states / 17.35 M traces, 30 min sim | No invariant violation at f=1. Expected: under f < n/3 = 1.33, NoDualHashOC holds; this is consistent. |
| 3 — OC equivocation accounting (f = 2 boundary) | MC-1 stretched to f = ⌈n/3⌉ | `MC_hunt_family3_f2.cfg` (Byzantine = {v3, v4}, `MaxByzEquivLimit = 4`) | 3.81 B states / 14.83 M traces, 30 min sim | No invariant violation. **This is an abstraction limitation**: the spec models `RecordVote(v, slot, hash)` with the precondition `voteHash = CanonicalSlotHash[voteSlot]`, so honest validators always vote on a single shared canonical hash. The only way to reach dual-hash OC under f-Byzantine is to have honest validators split between hashes (network partition / re-leader). The spec's PoH-oracle assumption (per brief §"Out of scope") collapses this. To reproduce MC-1, the spec needs a per-validator-view CanonicalSlotHash or an explicit `LeaderEquivocation` action — neither was modeled. |
| 5 — Lockout defense-in-depth | LockoutSafety + RootedSlotsForkConsistent + NoEquivocatingVoteFromHonest under combined Byzantine+crash+adopt | `MC_hunt_family5_lockout_depth.cfg` | 1.46 B states / 15.27 M traces, 30 min sim | No invariant violation. The single-site lockout check is structurally adequate at the modeled abstraction; the brief's "future-refactor risk" remains a code-review-only concern (R-7). |

---

## Spec Fixes Applied During Hunting

These changes are documented in `changelog.md` (Round 2 — Bug Hunting); they
were necessary to bring the spec in line with the implementation before the
real Case C bugs were observable:

1. **`MC.cfg` + `MC_hunt_*.cfg`: `CHECK_DEADLOCK FALSE`** (Case A).
   Bounded-counter exhaustion is the expected terminal state of a finite
   Byzantine + crash search; TLC's default deadlock detector reported it as
   an error.
2. **`RecordVote`: added `voteSlot ∉ purgedView[v]`** (Case B).
   The implementation removes the slot's bank from `bank_forks` during
   `purge_unconfirmed_slot`, so `select_vote_and_reset_forks` cannot pick a
   purged slot. Without this guard the spec admitted purge-then-vote
   sequences that are impl-impossible.
3. **`PurgeUnconfirmedSlot`: tightened precondition to
   `\E h \in duplicateConfirmed[slot] : h /= CanonicalSlotHash[slot]`** (Case B).
   `replay_stage.rs:1809` (`dump_then_repair_correct_slots`) only purges when
   v's local bank hash disagrees with the duplicate-confirmed hash. Without
   the tightening, purge fired even when v's local bank matched the
   cluster's dup-conf — a state in which the implementation does nothing.

After these fixes the trace re-validation suite (all 4 scenarios) still
passes, confirming that no real implementation behavior was excluded.

---

## Abstraction Limitations (For Future Iteration)

The following brief hypotheses are *unfalsifiable in the current spec
abstraction* and would require modeling extensions to test:

- **MC-1 / MC-4 (dual-hash OC at f = ⌈n/3⌉)**: spec assumes a global
  `CanonicalSlotHash[slot]`. Real Solana can have leader equivocation or
  partition-driven divergent leader-frozen hashes that split honest votes.
  Extension: per-validator-view leader hash, or an explicit
  `LeaderEquivocation(slot)` action that admits ≥2 canonical hashes.
- **`ByzInjectDupConfirmSignal` stake-threshold**: the spec injects DupConf
  signals without enforcing the 0.52 stake threshold. The MC-6 finding is
  reachable under this over-approximation; the impl-realistic version would
  require coordinating Byzantine + honest-split votes. Extension: derive
  `DupConfMsg` only when `\E h : StakeExceedsDup(StakeOf(ocStake[slot][h]))`.
- **Family 1 adoption chain**: the spec models `AdoptOnChainTower` and
  `ByzCraftBankVoteState` separately. Real adoption pulls vote-state from a
  bank that integrates ALL prior vote-txs; a true Byzantine bank-builder
  attack composes block-construction with vote-account state-rewrite.
  Extension: model `BuildByzantineBank` that synthesizes a bank embedding
  arbitrary vote-account state for the target validator.

These are forward-looking extensions, not gaps that invalidate the current
findings. The two reported Case C bugs (MC-5, MC-6) hold under the current
abstraction and correspond to known implementation behaviors.
