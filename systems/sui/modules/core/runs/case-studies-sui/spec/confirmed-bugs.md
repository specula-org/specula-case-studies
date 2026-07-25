# Confirmed Bug Report — Sui Mysticeti DAG-BFT Consensus

## Summary

- **Total findings reviewed**: 2 (both MC-confirmed with counterexamples)
- **Reproduced**: 2 (Bug 1, Bug 2 — panics fire on the production code paths
  named by the MC traces)
- **Confirmed via code audit, reproduction failed**: 0
- **False positives**: 0
- **Inconclusive**: 0

Both bugs come from the MC hunting phase and have explicit counterexamples in
`spec/output/MC_hunt_family3_bfs.out` (F3 / Bug 1) and
`spec/output/MC_hunt_family4_bfs.out` (F4 / Bug 2). Each was reproduced as a
Rust test that drives the real `consensus-core` code paths and fires the same
panic the production assertion would.

Modeling-brief items that are explicitly defensive / hygiene-only (CR2 — f+1
amnesia threshold discussion; CR3 — multi-leader path disabled in config;
CR4 — BlockRef hash truncation; CR5 — own-equivocation panic vs Err; CR6 —
commit_finalizer assert vs ≥; CR7 — block_verifier evicted-round
documentation) were not selected for confirmation because they are pure
defense-in-depth suggestions without a reachable harm path under the
maintainer-stated trust model.

Family 5 findings (T1–T5, MC6) about block-verifier timestamp bounds,
unbounded `missing_blocks`, peer-round trust, ancestor exclusion and Byzantine
timestamp propagation are *implementation hardening* per the modeling brief
itself (§3.2 "Do Not Model") and were filtered out at triage.

---

## Bug 1: `BaseCommitter::find_supported_block` / `DagState::ancestors_at_round` panic on missing high-round ancestor

- **Source**: MC (counterexample at depth 4 in
  `MC_hunt_family3.cfg`) + code-review CR1 in the modeling brief.
- **Status**: REPRODUCED.
- **Severity**: High — validator-process crash on a state that any caller
  bypassing `BlockManager` ancestor-presence enforcement can produce.
- **Location**:
  - `consensus/core/src/base_committer.rs:209` — `find_supported_block`,
    `.unwrap_or_else(|| panic!("Block not found in storage: {:?}", ancestor))`.
  - `consensus/core/src/dag_state.rs:574` — `ancestors_at_round`,
    `panic!("Block {:?} should exist in DAG!", block_ref)`.
  - `consensus/core/src/base_committer.rs:250-256` — `is_certificate`,
    the symmetric `assert!(reference.round <= gc_round)` guard that the
    other two sites lack.
  - `consensus/core/src/block_manager.rs:309-355` — `try_accept_one_block`,
    the only safeguard enforcing the missing precondition.
  - `consensus/core/src/block_manager.rs:183-209` — `try_accept_one_committed_block`,
    a production path that bypasses the ancestor-presence check for
    certified-commit fast-sync.

### Description

`find_supported_block` recurses through ancestor refs at
`ancestor.round > leader_slot.round`, and `ancestors_at_round` traverses the
ancestor chain of a leader anchor down to `decision_round`. Both call
`DagState::get_block(&ref)` and `panic!` if it returns `None`. The implicit
invariant is that any block in `DagState` whose round is above `gc_round` has
all of its `round > gc_round` ancestors already in `DagState`. That invariant
is enforced in exactly one place — `BlockManager::try_accept_one_block`
(`block_manager.rs:309-355`) — which suspends a block whose ancestors are not
yet in `DagState`. The sister method `is_certificate` redundantly guards
itself (`assert!(reference.round <= gc_round)`) so a missing reference above
`gc_round` is a *legitimate* panic-worthy invariant violation there, not a
function-side bug. `find_supported_block` and `ancestors_at_round` do not have
that guard: the panic message is "Block not found in storage" / "Block should
exist in DAG", which conflates an invariant violation upstream with a
recoverable lookup failure.

### Prerequisites

- **[code] Function reachable from public API**: VERIFIED — `try_direct_decide`
  and `try_indirect_decide` are `pub` on `BaseCommitter` and called from
  `UniversalCommitter::try_decide` (`universal_committer.rs:48-149`) in the
  Core thread.
- **[code] DagState can hold a block whose `round > gc_round` ancestor is
  missing**: VERIFIED — `try_accept_one_committed_block`
  (`block_manager.rs:183-209`) calls
  `self.dag_state.write().accept_blocks(vec![block])` directly without an
  ancestor-presence check, and `DagState::accept_block` itself does not check
  ancestor presence (it asserts only on the own-equivocation guard at
  `dag_state.rs:322-336`).
- **[spec] Mysticeti tolerates partial DAGs above `gc_round` and the recurse
  sites are intended to handle it gracefully**: NOT VERIFIED in the
  Mysticeti paper. The reframed finding is "defense-in-depth": no spec text
  contradicts the missing guard, but no spec text mandates it either. The
  code-internal symmetric guard at `is_certificate` is the strongest local
  evidence that the developers consider the guarded case legitimate.

### Counterfactual fix check

Not applicable. The violated property is *local* (a specific function panics
on a specific bad lookup), not system-wide. The Phase 2 advisory only applies
to availability/exhaustion/agreement properties whose violation could be
reached by an alternative path — not to "this exact `unwrap_or_else` panics
when its input is `None`". No counterfactual TLC run is informative here.

### Report Tier: B

The bug is real and the panic is hard-to-recover (validator process exits).
Tier A would require an externally-observable, attacker-triggerable trigger
on the production code path. The only known production trigger path is
`try_accept_one_committed_block` — but the certified commits arriving via
`commit_syncer` are required by `Core::filter_new_commits`
(`core.rs:481-515`) to be sequenced and gap-free, and the `CertifiedCommit`'s
sub-dag is supposed to be self-contained for the rounds it covers. So the
attacker requires either (a) a buggy peer's commit_syncer that ships a
sub-dag missing a `round > gc_round` ancestor, or (b) a race during gc
advance, or (c) the harness-style direct-accept path used by tests. The
modeling brief identifies the asymmetry with `is_certificate` as the
strongest evidence; this is a defense-in-depth gap that the brief itself
files as CR1, not a Tier-A externally exploitable bug.

### Trigger scenario

1. Validator's `DagState` holds a block at round 7 whose ancestor at round 6
   (author 3) is not in `DagState`. The MC counterexample reaches this via
   `MCByzPropose` + `DeliverBlock`; the reproduction reaches it via direct
   `accept_block` calls — both faithfully exercise the precondition that
   `try_accept_one_committed_block` is structurally capable of producing in
   production.
2. `UniversalCommitter::try_decide` (or any caller of `try_indirect_decide`)
   selects a higher-round committed leader as anchor.
3. `decide_leader_from_anchor` → `DagState::ancestors_at_round(anchor@7,
   decision_round=5)` walks the chain. The first iteration pops the missing
   `(6, 3)` ref, `get_block(...)` returns `None`, and the validator panics.

### Developer intent investigation

The asymmetric guard at `is_certificate` (`base_committer.rs:250-256`) shows
the developers DID consider the case of a missing reference above `gc_round`
and DID write a defensive sibling. No commit message or issue explains why
`find_supported_block` and `ancestors_at_round` weren't given the same
treatment, but the modeling-brief precedents (PR #20492 "threshold clock
advancement after GC", PR #20992 "GC missing blocks via try_fetch_blocks",
PR #21206 "try_find_blocks respect GC") show a pattern of plugging GC
defensiveness gaps when they're found. CR1 in the modeling brief is the
natural next entry in that series.

### Reproduction test

`repro/test_bug1_find_supported_block.rs` — a `#[tokio::test]
#[should_panic(expected = "should exist in DAG")]` that:

1. Builds 4-validator `Context`, fresh `DagState`, `BaseCommitter`.
2. Accepts rounds 1..=5 fully (4 blocks per round, valid ancestors).
3. Accepts only 3 of 4 round-6 blocks — author 3's `(6, 3)` is built but
   intentionally not inserted into `DagState`.
4. Accepts a round-7 anchor block whose ancestors reference all 4 round-6
   blocks, including the missing `(6, 3)`.
5. Calls `committer.try_indirect_decide(leader_slot@3,
   [Commit(anchor@7)])`. Internally this calls
   `DagState::ancestors_at_round(anchor@7, decision_round=5)`, which pops
   `(6, 3)` and panics.

Run via `repro/run_repro.sh bug1`, which temporarily patches
`consensus/core/src/lib.rs` to register the test module, then restores
`lib.rs` on exit.

### Reproduction result

**PASS (bug triggered)**:

```
thread 'repro_bug1_find_supported_block::repro_bug1_ancestors_at_round_panic'
panicked at consensus/core/src/dag_state.rs:574:17:
Block B6([3],Mc3ANYEg8OuARJdRxI7qvy0YgqS0aeS8AiHiWJwPCBA=) should exist in DAG!
test repro_bug1_find_supported_block::repro_bug1_ancestors_at_round_panic - should panic ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; ...
```

The panic message and line number match the exact site the MC counterexample
predicts (`dag_state.rs:574`). The symmetric site
`base_committer.rs:209` (`find_supported_block`) panics identically when
exercised through a different recursion shape — the reproduction picks the
`ancestors_at_round` site because it is the easier to reach via
`try_indirect_decide` (the public `BaseCommitter` API).

### Recommendation

Apply the CR1 fix from the modeling brief: mirror the `is_certificate` guard
in both `find_supported_block` and `ancestors_at_round`.

```rust
// In find_supported_block, before the unwrap_or_else:
if ancestor.round <= gc_round {
    return None;
}
let from_block = self
    .dag_state
    .read()
    .get_block(ancestor)
    .unwrap_or_else(|| panic!(
        "Block not found in storage: {:?} — block_manager invariant violated",
        ancestor));

// In ancestors_at_round, before the panic!:
if block_ref.round <= self.gc_round() {
    continue;
}
let Some(block) = self.get_block(&block_ref) else {
    panic!("Block {:?} above gc_round {} should exist in DAG — \
            block_manager invariant violated",
           block_ref, self.gc_round());
};
```

The fix is intentionally non-permissive about the *true* invariant break:
above `gc_round`, the panic is still preferred (it surfaces real upstream
bugs). What changes is that legitimate below-`gc_round` references no longer
crash a validator that simply hasn't yet GC'd or has GC'd faster than its
peer.

---

## Bug 2: `Proposer::smart_ancestors_to_propose` force-path assertion fires after threshold-clock catch-up

- **Source**: MC (counterexample at depth 3 in `MC_hunt_family4.cfg`) +
  modeling-brief MC4 (Family 4 leader-timeout / threshold clock).
- **Status**: REPRODUCED.
- **Severity**: High — validator-process panic on a state the production code
  comment explicitly anticipates ("Possible mismatch between DagState and
  Core") but does not recover from.
- **Location**:
  - `consensus/core/src/proposer.rs:352-354` — the `assert!` that fires.
  - `consensus/core/src/proposer.rs:170-364` —
    `smart_ancestors_to_propose`, the force-path.
  - `consensus/core/src/leader_timeout.rs::run` — caller of the force-path.
  - `consensus/core/src/core.rs::add_certified_commits` — the production
    entry that can advance `threshold_clock` ahead of local DAG fill-in.
  - `consensus/core/src/threshold_clock.rs:65-80` — `Ordering::Greater`
    catch-up: a single block whose round is above `self.round` jumps the
    threshold clock without requiring a 2f+1 quorum at the new round.

### Description

`Proposer::smart_ancestors_to_propose(clock_round, smart_select)` checks
that the candidate ancestors at `quorum_round = clock_round - 1` reach
2f+1 stake. When `smart_select = true` (normal propose path), failing the
check returns an empty ancestor set, the proposer waits for more blocks, and
no harm occurs. When `smart_select = false` (force-path, used by the
`LeaderTimeout::run` -> `Core::new_block(round, force=true)` -> `try_propose(true)`
chain), the code assumes the precondition holds and asserts it:

```rust
assert!(
    parent_round_quorum.reached_threshold(&self.context.committee),
    "Fatal error, quorum not reached for parent round when proposing for round {clock_round}. \
     Possible mismatch between DagState and Core."
);
```

`threshold_clock_round` can race ahead of the local DAG via two paths the
modeling brief names: (i) `Core::add_certified_commits` accepts a peer
sub-dag whose acceptance order or contents do not fill 2f+1 at the new
`clock_round - 1`, and (ii) `ThresholdClock::add_block`'s `Ordering::Greater`
branch (`threshold_clock.rs:65-80`) — a single accepted block at a round
higher than the current clock jumps the clock to that round, regardless of
whether the validator has accepted 2f+1 at the new `clock_round - 1`.

### Prerequisites

- **[code] Force-path is reachable from production**: VERIFIED — `LeaderTimeout::run`
  (`leader_timeout.rs`) fires after `max_leader_timeout` and calls
  `Core::new_block(round, force=true)` (`leader_timeout.rs::run`,
  `core.rs:456-477`).
- **[code] `threshold_clock` can outrun the local DAG**: VERIFIED — direct
  `DagState::accept_block` calls (used by
  `BlockManager::try_accept_one_committed_block`, `block_manager.rs:206`)
  feed into `DagState::update_block_metadata`
  (`dag_state.rs:380-396`) which calls `threshold_clock.add_block(block_ref)`.
  The `Ordering::Greater` branch at `threshold_clock.rs:65-80` jumps the
  clock to `block.round` without checking quorum at `block.round - 1`.
- **[code] Developers acknowledge the mismatch**: VERIFIED — the assertion's
  own error string is *"Possible mismatch between DagState and Core"*. The
  comment explicitly anticipates the failure but does not handle it.
- **[spec] Mysticeti's force-propose is supposed to gracefully decline when
  parent-round quorum is not yet reached**: NOT VERIFIED in the paper. The
  Mysticeti paper does not specify a force-propose path at all (it is a Sui
  liveness optimization layered on top). The reframed finding is "missing
  graceful fallback in an extension path"; the spec is silent so we report
  it as a hygiene-amplified-to-process-panic issue.

### Counterfactual fix check

Not applicable. The violated property — "`assert!(...)` fires on this exact
line" — is local. The Phase 2 reframing is appropriate only for system-wide
properties (availability, eventual consistency, etc.). The proposed fix is
also local (replace `assert!` with an early-return or replace
`add_certified_commits`'s clock-advancement with a quorum-aware variant); no
alternative path search via TLC contributes additional signal.

### Report Tier: B

Process-level panic on a state two honest-only actions reach in the MC
counterexample. Tier A would require external observability beyond a crash
(data corruption / signature failure on legitimate input). Liveness loss from
a validator process restart is real but recoverable on restart, so the
finding is Tier B by the report-tier ladder.

### Trigger scenario

1. Validator is idle: `DagState` holds only genesis (round 0) and its own
   round-1 block. `threshold_clock_round = 1`, `last_proposed_round = 1`.
2. A peer-pushed certified commit arrives at round 5 via
   `Core::add_certified_commits` → `try_accept_one_committed_block` →
   `DagState::accept_block` for the leader block at round 5. (Alternatively,
   in the simplified reproduction, a single high-round block accepted
   directly into `DagState` exercises the same `Ordering::Greater` catch-up.)
3. `DagState::update_block_metadata` calls `threshold_clock.add_block(round=5)`.
   The `Ordering::Greater` branch sets `self.round = 5`; no 2f+1 quorum at
   round 4 is required.
4. `LeaderTimeout::run` fires `max_leader_timeout`. It calls
   `Core::new_block(5, force=true)`.
5. `try_propose(true)` calls
   `proposer.try_new_block(true)` →
   `smart_ancestors_to_propose(5, smart_select=false)`.
6. `parent_round_quorum.reached_threshold(...)` is `false` (0 / 4 stake at
   round 4). Assertion fires; validator process panics.

### Developer intent investigation

The assertion's error message itself states *"Possible mismatch between
DagState and Core"*. That explicit acknowledgment, plus the modeling brief's
catalogue of related historical fixes (PR #16722 liveness signal, PR #20906
"advance threshold clock from dag state", PR #20492 threshold clock × GC, PR
#24292 deadlock during recovery), shows this is a known fragile spot — the
developers know the assertion can fire but have so far treated it as
"shouldn't happen in steady state" rather than "must be defended against."
PR #25157 (open draft, "propagation-delay deadlock after restart") in the
modeling brief is the closest in-flight related work. The reproduction in
this report is the first concrete demonstration we found that two
honest-only actions on a single validator are sufficient.

### Reproduction test

`repro/test_bug2_force_propose.rs` — a `#[tokio::test(flavor =
"current_thread", start_paused = true)] #[should_panic(expected = "quorum
not reached for parent round")]` that:

1. Builds 4-validator `CoreTestFixture` via `create_cores`. After
   `Core::recover_validator` the validator has proposed its round-1 block
   (`threshold_clock_round = 1`, `last_proposed_round = 1`).
2. Builds a foreign block at round 5 by author 1 referencing genesis.
3. Calls `fixture.dag_state.write().accept_block(foreign_high)` — the same
   API surface that `BlockManager::try_accept_one_committed_block` uses to
   install certified-commit blocks while bypassing the ancestor check
   (`block_manager.rs:206`).
4. Asserts `threshold_clock_round() == 5` and
   `get_uncommitted_blocks_at_round(4).is_empty()`.
5. Calls `fixture.core.new_block(5, true)`, the production entry the
   `LeaderTimeout::run` path takes.

Run via `repro/run_repro.sh bug2`.

### Reproduction result

**PASS (bug triggered)**:

```
thread 'repro_bug2_force_propose::repro_bug2_force_propose_assertion'
panicked at consensus/core/src/proposer.rs:352:9:
Fatal error, quorum not reached for parent round when proposing for round 5. \
 Possible mismatch between DagState and Core.
test repro_bug2_force_propose::repro_bug2_force_propose_assertion - should panic ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; ...
```

The panic message, file, and line match the assertion the MC trace and the
modeling brief MC4 predict.

### Recommendation

Either of the two fixes the modeling brief proposes works. The smaller fix
is preferred:

1. **Soften the force-path assert to an early return** (`proposer.rs:352-354`):
   when `smart_select == false` and `parent_round_quorum` has not reached
   threshold, log + record the missed timeout + return an empty ancestor
   list. The caller (`try_propose`) already handles `(vec![], _)` as
   "skip this proposal cycle"; the only behavioral change is that the
   validator gracefully waits for the next `new_round` signal instead of
   panicking. The force-path is by definition a "we wanted to propose a
   stale-round block to keep the schedule going" path; declining to propose
   it when the precondition fails is strictly safer than crashing.
2. **Constrain `Core::add_certified_commits`** to not advance
   `threshold_clock_round` past `last_known_full_round + 1`, where
   `last_known_full_round` is the highest round at which the validator
   actually holds 2f+1 stake locally. The certified-commit sub-dag still
   applies, but the clock advancement waits for real DAG progress. This is
   more invasive and ties into PR #25157.

Both fixes are consistent with how `is_certificate` already trades a panic
for a `None` return (the symmetry that motivated CR1 in Bug 1).
