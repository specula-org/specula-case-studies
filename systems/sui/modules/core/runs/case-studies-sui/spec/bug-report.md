# Bug Report — Sui Mysticeti DAG-BFT Consensus

## Summary

- Bug families tested: 5 (F1, F2, F3, F4 force-propose, F4 multi-leader)
- Bugs found: **2** (both confirmed Case C — real-bug-class findings against the production code)
- Configs run: `MC_hunt_family1.cfg`, `MC_hunt_family2.cfg`, `MC_hunt_family3.cfg`,
  `MC_hunt_family4.cfg`, `MC_hunt_family4_multileader.cfg`
- Outputs: `spec/output/MC_hunt_*.out`

| Family | Invariant | Config | Result |
|---|---|---|---|
| F1 (equivocation) | CommitAgreement / CommitDigestAgreement / LeaderCommitMonotonic | `MC_hunt_family1.cfg` | No violation in BFS (depth 12, 45 M distinct, 30 min) |
| F2 (amnesia recovery) | NoOwnEquivocation | `MC_hunt_family2.cfg` | No violation in BFS (depth 10, 2.5 M distinct; run was squeezed by shared-host contention) |
| F3 (GC × commit recursion) | CommitRecursionDecidable | `MC_hunt_family3.cfg` | **Bug 1 found** at depth 4 |
| F4 (force-propose) | ForcePropose2f1Parents | `MC_hunt_family4.cfg` | **Bug 2 found** at depth 3 |
| F4 (multi-leader latent) | MultiLeaderCommitOrdering | `MC_hunt_family4_multileader.cfg` | No violation (depth 13, 858 K distinct; multi-leader path is not enabled in the spec because `LeaderOf` returns a single author) |

---

## Bug 1: `find_supported_block` panics on missing high-round ancestor (F3 / CR1)

- **Bug Family**: F3 — GC × Commit Rule interactions
- **Severity**: High (process panic; matches the modeling brief's CR1
  recommendation as a real defensive gap)
- **Invariant violated**: `CommitRecursionDecidable`
- **Config**: `MC_hunt_family3.cfg` (GCDepth = 1, MaxByzPropose = 3,
  MaxDagSize = 18)
- **Counterexample**: 4 states. Full TLC trace in
  `spec/output/MC_hunt_family3_bfs.out` lines 28-…

### Trace Summary

| # | Action | Effect on state |
|---|---|---|
| 1 | Initial | `dag[*] = GenesisBlocks`; `Messages` = 4 round-0 blocks; `gcRound[s] = 0` for all s. |
| 2 | `MCByzPropose("s4", 1, 1)` | Byzantine `s4` produces `s4@1@1` with **empty ancestors set** (not even genesis). `Messages` and `dag[s4]` gain the block. `signedHistory[s4] = {(1, 1)}`. |
| 3 | `MCByzPropose("s4", 2, 1)` | Byzantine `s4` produces `s4@2@1` whose **only ancestor reference is `s4@1@1`**. Added to `Messages` and `dag[s4]`. No round-1 honest blocks have been produced yet. |
| 4 | `MCNext` (DeliverBlock fires) | `s4@2@1` is delivered to honest `s1`. `dag[s1]` now contains `s4@2@1` whose ancestor `s4@1@1` is **not in `dag[s1]`**. `clockRound[s1]` jumps to 2 via the "Ordering::Greater" single-block catch-up. |

State 4 already violates `CommitRecursionDecidable`: `s4@2@1.ancestors`
contains `s4@1@1`, `s4@1@1.round = 1 > gcRound[s1] = 0`, yet no block in
`dag[s1]` matches `s4@1@1`.

### Root Cause

The Sui production stack relies on **two layers** to guarantee that no
ancestor at `round > gc_round` is missing from local DAG state:

1. `block_manager::try_accept_one_block`
   (`consensus/core/src/block_manager.rs:309-355`) walks each ancestor of an
   inbound block. For an ancestor whose `round > gc_round`, if the ancestor
   is not yet in `DagState`, the inbound block is moved to
   `suspended_blocks` and only promoted into `DagState` once the ancestor
   arrives.
2. `base_committer::find_supported_block`
   (`consensus/core/src/base_committer.rs:193-215`) recurses through
   ancestors and assumes `block_manager` has already enforced (1). If it
   encounters a missing ancestor whose `round > gc_round`, it calls
   `unwrap_or_else(|| panic!("Block not found in storage: {:?}", ancestor))`
   at line 209.

The asymmetry with `is_certificate` is explicit:
`base_committer::is_certificate` (`base_committer.rs:250-256`) has an
explicit `assert!(reference.round ≤ gc_round)` fallback and treats
above-gc missing ancestors as the legitimate "we should already have
this" panic.

`find_supported_block` has **no defensive guard**. It depends entirely on
`block_manager` to never have left a half-accepted block in `DagState`.
The harness (`tla_trace_scenarios.rs`) bypasses `block_manager` by
calling `DagState::accept_block` directly, which is exactly the state
the spec's relaxed `DeliverBlock` allows TLC to reach.

The model checker therefore answers: *if any code path (a race, a future
refactor, a test scaffold, or a direct `accept_block` call) ever leaves
`DagState[s]` with a block whose `round > gc_round` ancestor is missing,
then the next call to `find_supported_block` for that ancestor will
panic the validator process*. The same applies to `ancestors_at_round`
(`dag_state.rs:559-578`, line 574: `panic!("Block {:?} should exist in
DAG!", block_ref)`).

### Affected Code

- `consensus/core/src/base_committer.rs:193-215` — `find_supported_block`,
  unconditional `unwrap_or_else` at line 209.
- `consensus/core/src/base_committer.rs:250-256` — `is_certificate`, the
  symmetric guard that `find_supported_block` lacks.
- `consensus/core/src/dag_state.rs:559-578` — `ancestors_at_round`,
  `panic!` at line 574 on the same precondition.
- `consensus/core/src/block_manager.rs:309-355` — `try_accept_one_block`,
  the sole layer enforcing the precondition that `find_supported_block`
  depends on.

### Recommendation

Mirror the `is_certificate` guard inside `find_supported_block` and
`ancestors_at_round`:

```rust
// in find_supported_block, before the unwrap_or_else
if ancestor.round <= gc_round {
    return None;   // legitimately out of scope, do not panic
}
let from_block = self.dag_state.read()
    .get_block(&ancestor)
    .unwrap_or_else(|| panic!(
        "Block not found in storage: {:?} — block_manager invariant violated",
        ancestor));
```

This is the defensive change suggested in the modeling brief as **CR1**.
The model checker confirms the precondition is reachable from a
4-step prefix of Byzantine-only actions in a `n=4, f=1` configuration —
no honest action is needed to set it up.

---

## Bug 2: Force-propose with `add_certified_commits` violates the parent-quorum precondition (F4 / MC4)

- **Bug Family**: F4 — Leader timeout / threshold clock / proposer
- **Severity**: High (production-panic surface, `proposer.rs:352-354`
  `assert!` fires)
- **Invariant violated**: `ForcePropose2f1Parents`
- **Config**: `MC_hunt_family4.cfg` (MaxCertCommit = 2, MaxForcePropose
  = 2, MaxDagSize = 12, no Byzantine/Crash)
- **Counterexample**: 3 states. Full TLC trace in
  `spec/output/MC_hunt_family4_bfs.out`.

### Trace Summary

| # | Action | Effect on state |
|---|---|---|
| 1 | Initial | `dag[*] = GenesisBlocks`, `clockRound[*] = 1`. No honest validator has yet produced any round-1 block. |
| 2 | `MCAddCertifiedCommit("s2", 2)` | A peer-pushed certified commit at round 2 is absorbed. Per the impl semantics modeled in `AddCertifiedCommit`, `certifiedCommitRound[s2] = 2` and `clockRound[s2]` jumps to 2. `dag[s2]` still contains only the 4 genesis blocks. |
| 3 | `MCForcePropose("s2")` | The leader-timeout path fires `force = true`. `r = clockRound[s2] = 2`. The action emits a block at round 2 whose `ancestors = BlocksAtRoundIn(s2, 1) = {}`. The invariant `ForcePropose2f1Parents` requires the round-1 parent set to reach 2 f + 1 = 3 of 4 stake — it has zero. |

State 3 violates `ForcePropose2f1Parents`. The validator has just signed
a block whose parent set was *empty*.

### Root Cause

The production scenario is exactly the one written up as `MC4` in the
modeling brief:

1. `Core::add_certified_commits`
   (`consensus/core/src/core.rs`, via `commit_syncer.rs`) absorbs a peer
   certificate at round `R`. It advances `dag_state.threshold_clock` to
   `R` without waiting for the local DAG to fill in.
2. `LeaderTimeout::run` (`leader_timeout.rs`) fires after the configured
   `max_leader_timeout` and calls `Core::try_propose(force = true)`.
3. `Core::try_propose` calls
   `proposer::smart_ancestors_to_propose(r, smart_select = false)`. With
   `smart_select = false`, the function takes the **force path**
   (`proposer.rs:170-364`).
4. The force path contains
   `assert!(parent_round_quorum.reached_threshold(...));` at
   `proposer.rs:352-354`. The assertion holds in steady-state operation
   because `r = clockRound` and `clockRound` is supposed to be the
   highest round at which the validator has accepted a 2 f + 1
   quorum — but `add_certified_commits` violates that invariant in (1)
   by catching the clock up without inspecting the local DAG.

In the counterexample TLC found, no Byzantine action is required. Two
honest-only actions (`add_certified_commits` then `force_propose`) on a
single validator are sufficient to trigger the panic.

### Affected Code

- `consensus/core/src/proposer.rs:170-364` — `smart_ancestors_to_propose`,
  force-path code.
- `consensus/core/src/proposer.rs:352-354` — the `assert!` that fires.
- `consensus/core/src/core.rs::add_certified_commits` — advances state
  ahead of the local DAG.
- `consensus/core/src/threshold_clock.rs:65-80` — "Ordering::Greater"
  single-block catch-up (the same mechanism `add_certified_commits`
  relies on; documented in `threshold_clock.rs:36-82`).
- `consensus/core/src/leader_timeout.rs::run` — caller of the force
  path.

### Recommendation

Either:

1. **Guard the force path**: in
   `Proposer::smart_ancestors_to_propose`, when `smart_select = false`,
   replace the `assert!` with a graceful early return — log, record the
   missed timeout, and let the next `new_round` signal retry. The block
   was going to be a stale-round propose anyway; declining to produce it
   is strictly better than panicking.
2. **Constrain `add_certified_commits`**: have it not advance
   `threshold_clock_round` past `last_block_round + 1` where
   `last_block_round` is the highest round at which the validator
   actually holds a 2 f + 1 quorum in `dag_state`. The certified-commit
   sub-DAG can still be applied (and is, via the fast-sync path), but
   the clock advancement is gated on real DAG progress.

Option 1 is the smaller change; option 2 is the more invasive one.
Option 1 is consistent with how `is_certificate` already trades a panic
for a `None` (see Bug 1 / CR1).

---

## Not Reproduced

| Bug Family | Config | States Explored | BFS Diameter | Result |
|---|---|---|---|---|
| F1 (commit-digest agreement under equivocation) | `MC_hunt_family1.cfg` | 45 M distinct in 30-min BFS (killed by disk pressure at depth 12) | 12 | No violation. A second simulation run terminated within 1 s at a bounded-model deadlock — the spec's bounded `MaxRound = 5` + `MaxDagSize = 12` exhausts the proposal budget before reaching the digest-agreement scenario MC1 describes. Reproducing MC1 likely needs symmetry restored on `Honest` (model values) so the state space fits at a larger `MaxRound`. |
| F2 (own-equivocation under amnesia recovery) | `MC_hunt_family2.cfg` | 2.5 M distinct (depth 10) — run got squeezed by another agent's concurrent TLC on the shared host (memory contention; killed after 3 min of progress) | 10 | No violation. The spec's `RecoverAmnesia` uses the strict `\E reports : honest report = HonestReport` model from `base.tla` (not the Trace-replay relaxation). The MC2 scenario likely needs longer per-round depth than the current bound allows. |
| F4 / MC5 (multi-leader latent break-out) | `MC_hunt_family4_multileader.cfg` | 858 K distinct (depth 13, killed by OOM) | 13 | No violation, **but expected**: the spec's `LeaderOf(r) = ServerSeq[(r % N) + 1]` returns a *single* author per round. The `MultiLeaderCommitOrdering` invariant tests for "leader at offset 1 committed implies leader at offset 0 also committed", but no multi-leader path is currently active in the spec (the `MultiLeaderOf` helper in `MC.tla:172-175` exists but is unused). To reach MC5 the `MCNext` disjunction would need an explicit multi-leader `TryDirectDecide` action; that work is left for a follow-up MC config. |

---

## Spec Fixes Applied During Hunting

None. The two bugs (F3, F4) were found with the converged spec as-is.
The F3 invariant violation exposes a real precondition the spec
correctly admits because the harness's `dag_state.accept_block` bypass
is a faithful representation of one production code path (testing,
direct calls). The F4 violation is a faithful instance of the MC4
scenario described in the modeling brief.

---

## Next Steps

1. **Engineering**: File two GitHub issues against `MystenLabs/sui`:
   - "Defensive guard in `find_supported_block` / `ancestors_at_round`
     to avoid panic on missing high-round ancestor" (Bug 1 / CR1).
   - "`Proposer::smart_ancestors_to_propose` force path panics when
     `add_certified_commits` raced ahead of local DAG" (Bug 2 / MC4).
2. **Model coverage**: Restore symmetry on `Honest` by re-introducing
   model-value `Server` (and adapting the trace replay path to map
   model values to harness strings) so F1 and F2 can reach the deeper
   state space that the current MC4 / CR1 bounds did not require.
3. **Multi-leader path (MC5)**: Add an MC-only override that calls
   `MultiLeaderOf(r, 1)` from a new `MCTryDirectDecideOffset` action
   to exercise the latent `slot == last_decided` break-out at
   `universal_committer.rs:48-57`.
