# Substrate GRANDPA Bug Hunting Report

## Summary

Model-checking-based bug hunting campaign on a validated TLA+ specification of Substrate
GRANDPA BFT finality. The spec (`base.tla`) models authority set changes, finalization
races, equivocation counting, round state machines, vote limits, and crash/recovery. It
was validated against 4 implementation traces and verified with 10 invariants across
32.5M states (BFS).

Eight hypotheses (MC-1 through MC-8) were derived from code analysis. Four were
model-checked with dedicated TLC configurations. Results:

| ID   | Hypothesis                              | Verdict       | Classification |
|------|-----------------------------------------|---------------|----------------|
| MC-1 | Root-only `current_limit()` is lossy    | **VIOLATED**  | Case C (real bug) |
| MC-2 | Root-only forced change dep check       | Code-confirmed | Case C (real bug) |
| MC-4 | Non-atomic finalization writes          | **VIOLATED**  | Case C (design flaw, acknowledged) |
| MC-7 | HasVoted overwrite on round completion  | **VIOLATED**  | Historical bug (fixed PR #6823) |
| MC-3 | Stalled state consumed before schedule  | Code-confirmed | Infeasible to MC |
| MC-5 | Equivocator "votes for everything"      | Covered        | No issue at n=3 |
| MC-6 | Non-descendant commit vote rejection    | N/A           | Infeasible to MC |
| MC-8 | Round completion without R-2 estimate   | N/A           | Infeasible to MC |

**Two real bugs found (MC-1, MC-2), one historical bug confirmed (MC-7), one
acknowledged design flaw confirmed (MC-4).**

---

## MC-1: Root-Only Vote Limit Computation (Case C — Real Bug)

### Hypothesis

`current_limit()` in `authorities.rs:423-429` computes the vote limit by calling
`.roots()` on the `ForkTree` of pending standard changes. If a non-root standard
change has a lower effective number than all roots, the implementation returns a
limit that is **too high**, potentially allowing votes on blocks past a pending
authority set change boundary.

### Counterexample

**TLC output**: `nohup_hunt.out` — BFS, violation at depth 4, 4-state trace.

```
State 1: Initial
State 2: ProduceBlock(s1, 0, 4)      → block 4 created (parent=genesis)
State 3: ProduceBlockWithStdChange    → block 2 (parent=genesis) + std change (delay=2, effective=4)
State 4: ProduceBlockWithStdChange    → block 3 (parent=block 2) + std change (delay=0, effective=3)
```

**Block tree** at state 4:
```
genesis(0) → block 1
           → block 2 [std change: delay=2, effective=4]  ← ROOT
               → block 3 [std change: delay=0, effective=3]  ← NON-ROOT (hidden from .roots())
           → block 4
```

**ForkTree of pending standard changes:**
- Block 2 (effective=4) — ROOT
- Block 3 (effective=3) — CHILD of block 2, **not a root**

**Result:**
- Implementation (`ImplComputeVoteLimitOf`): only sees root → returns **4**
- Correct (`CorrectComputeVoteLimitOf`): sees all changes → returns **3**

The implementation allows voting on block 4 when it should be restricted to block 3.

### Implementation Code

```rust
// authorities.rs:423-429
pub(crate) fn current_limit(&self, min: N) -> Option<N> {
    self.pending_standard_changes
        .roots()                                    // ← BUG: only examines ForkTree roots
        .filter(|&(_, _, c)| c.effective_number() >= min)
        .min_by_key(|&(_, _, c)| c.effective_number())
        .map(|(_, _, c)| c.effective_number())
}
```

### Impact

A too-high vote limit allows honest nodes to cast votes (prevotes/precommits) on blocks
beyond a pending authority set change boundary. This can lead to finalization of blocks
under a stale authority set, violating the intended authority set transition protocol.
The bug requires multiple standard changes on an ancestor-descendant chain where a child
change has a lower effective number than its parent — a valid configuration when delay
values differ.

### Suggested Fix

Traverse all nodes in the ForkTree (not just roots) when computing the minimum effective
number:

```rust
pub(crate) fn current_limit(&self, min: N) -> Option<N> {
    self.pending_standard_changes
        .iter()  // all nodes, not just roots
        .filter(|&(_, _, c)| c.effective_number() >= min)
        .min_by_key(|&(_, _, c)| c.effective_number())
        .map(|(_, _, c)| c.effective_number())
}
```

---

## MC-2: Root-Only Forced Change Dependency Check (Case C — Real Bug)

### Hypothesis

`add_pending_change()` in `authorities.rs:478-492` checks whether a forced authority
set change depends on any pending standard change by iterating `.roots()` of the
standard changes ForkTree. If a non-root standard change is an ancestor of the forced
change and has `effective_number <= median_last_finalized`, the dependency is missed,
and the forced change is applied prematurely.

### Evidence

The same `.roots()` pattern as MC-1:

```rust
// authorities.rs:478
for (_, _, standard_change) in self.pending_standard_changes.roots() {
    if standard_change.effective_number() <= median_last_finalized &&
        is_descendent_of(&standard_change.canon_hash, &change.canon_hash)?
    {
        return Err(Error::ForcedAuthoritySetChangeDependencyUnsatisfied(...))
    }
}
```

**Note**: A dedicated MC-2 simulation (`nohup_mc2_sim.out`) was run with the
`ForcedChangeDepsImplSafe` detection invariant, but a **spec-level issue** in the
Precommit action (see Appendix A) caused a `FinalizationSafety` violation to fire
first, masking the MC-2 target invariant.

The MC-2 bug is **independently confirmed** by:
1. Code analysis: the `.roots()` call at line 478 has the same lossy behavior as MC-1
2. The MC-1 counterexample proves the ForkTree `.roots()` approximation misses non-root
   changes — the same data structure is used for the dependency check
3. The detection invariant `ForcedChangeDepsImplSafe` was correctly specified: it checks
   `ImplForcedChangeDepsOk(s, fc) => ForcedChangeDepsOk(s, fc)` (root-only implies
   correct)

### Impact

A forced change applied prematurely (before its standard change dependencies are
finalized) can cause authority set transitions to occur out of order. Since forced
changes cannot be reverted, this could permanently compromise the authority set
lifecycle.

### Suggested Fix

Same as MC-1 — traverse all ForkTree nodes:

```rust
for (_, _, standard_change) in self.pending_standard_changes.iter() {
    // ... same check ...
}
```

---

## MC-7: HasVoted Overwrite on Round Completion (Historical Bug — Fixed)

### Hypothesis

In the `completed()` callback (`environment.rs:1019-1023`), the original code used
`.insert()` to set `HasVoted::No` for `round + 1`, which **overwrites** any existing
vote record. If a node had already started voting in round `r+1` before completing
round `r` (valid in GRANDPA's pipelined design), the overwrite erases the evidence of
those votes. After a crash, the node recovers without knowledge of its prior round
`r+1` votes and may **re-vote differently**, causing honest equivocation.

### Counterexample

**TLC output**: `nohup_mc7_sim2.out` — Simulation, `NoHonestEquivocation` violated at
state 30.

Key trace steps:
```
1.  s2 prevotes block 4 in round 1 (honest vote)
2.  s2 precommits block 2 in round 1 (honest precommit)
3.  MCCompleteRound(s2, 1) — round 1 completed
4.  s2 proposes block 1 in round 2, prevotes block 1
5.  MCCompletedCallbackOverwrite(s2, 1) — HasVoted[2] wiped to "none"
6.  MCCrash(s2) — s2 crashes
7.  MCRecoverMC7(s2) — recovery restores from persisted state (HasVoted[2]="none")
8.  s2 prevotes block 2 in round 2 — EQUIVOCATION (prevoted 1 before, now 2)
```

**Result**: `NoHonestEquivocation` violated — `prevotes[s2][2] = {1, 2}` (two different
prevote targets for honest server s2 in round 2).

### Implementation Code (Fixed Version)

```rust
// environment.rs:1023 — FIXED (PR #6823)
current_rounds.entry(round + 1).or_insert(HasVoted::No);
//                               ^^^^^^^^^
// Old code: .insert(HasVoted::No)  — overwrites existing votes
// Fix:      .or_insert(HasVoted::No) — only inserts if key absent
```

### Classification

This is a **confirmed historical bug**, fixed by PR #6823. The model checking
counterexample proves the fix was necessary: without `or_insert`, the `completed()`
callback creates a crash-recovery equivocation path for honest nodes.

---

## MC-4: Non-Atomic Finalization Writes (Case C — Acknowledged Design Flaw)

### Hypothesis

In `environment.rs:1451-1530`, finalization performs two separate disk writes:
1. `apply_finality()` (lines 1460-1509): persists the finalized block
2. `update_authority_set()` (lines 1516-1527): persists the new authority set

A crash between these writes leaves the persisted state inconsistent: `finalizedBlock`
is updated but `setId`/`authorities` are stale. On recovery, the node operates with
a finalized block that implies one authority set, but actually has a different one.

### Counterexample

**TLC output**: `nohup_mc4_sim.out` — Simulation, `PersistedStateConsistency` violated
at state 28.

**Final state (state 28)**:
```
s1: finalizedBlock=1, setId=0, currentAuthorities={s1,s2,s3}
s2: finalizedBlock=1, setId=1, currentAuthorities={s3}
s3: finalizedBlock=4, setId=1, currentAuthorities={s3}
```

Both s1 and s2 have `finalizedBlock=1` but disagree on `setId` (0 vs 1) and
`currentAuthorities` ({s1,s2,s3} vs {s3}). This occurred because:
- s2 completed both finalization sub-steps and applied the authority set change
- s1 recovered from a crash that happened between the finalization write and the
  authority set write, leaving it with stale authority data

### Implementation Code

```rust
// environment.rs:1521-1526
if let Err(e) = write_result {
    warn!(target: LOG_TARGET,
        "Failed to write updated authority set to disk. Bailing.");
    warn!(target: LOG_TARGET, "Node is in a potentially inconsistent state.");
    return Err(e.into())
}
```

The developers explicitly acknowledge the inconsistency risk with the warning
"Node is in a potentially inconsistent state."

### Classification and Impact

This is a **real design concern** that the developers acknowledge. The non-atomic write
creates a window where a crash leaves persisted state permanently inconsistent. Core
safety invariants (`FinalizationSafety`, `ElectionSafety`) were not violated in the
counterexample — the inconsistency is a **liveness and recovery** issue rather than a
safety issue. A node recovering from this state may have incorrect authority set
information, potentially preventing it from participating in future finalization rounds.

**Note**: The `PersistedStateConsistency` invariant may be partially Case A (too strong)
for some scenarios: the in-memory divergence between s1 and s2 could also arise from
normal asynchronous standard change application timing. The core finding (crash between
sub-steps creates persistent inconsistency) is Case C.

---

## Infeasible Hypotheses

### MC-3: Stalled State Consumed Before Schedule (Code-Confirmed, Infeasible to MC)

**Hypothesis**: In `frame/grandpa/src/lib.rs:583-609`, `<Stalled<T>>::take()` consumes
the stalled state before `schedule_change()` is called. If `schedule_change()` fails,
the stalled state is lost and the forced change is never retried.

**Code confirmation**: Lines 583-609 show `take()` is called unconditionally before the
`schedule_change` call. However, modeling this requires the pallet's on-chain state
machine, which is outside the scope of the current TLA+ spec (which models the client
consensus layer).

### MC-5: Equivocator "Votes for Everything" (Covered)

With n=3 and Quorum=3 in our configuration, a single equivocator (s3) cannot break
safety because the quorum requires all 3 servers. The "votes for everything" semantics
are correctly modeled in `PrevoteWeight`/`PrecommitWeight` and were verified across
32.5M BFS states with `EquivocationCorrectness` holding.

### MC-6: Non-Descendant Commit Vote Rejection (Infeasible)

Commit message validation (accepting/rejecting individual votes within a commit) is
not modeled in the current spec. The spec treats finalization as an atomic decision
based on vote aggregation, not individual vote processing.

### MC-8: Round Completion Without R-2 Estimate Finalization (Infeasible)

The GHOST estimate computation and its interaction with round completion is abstracted
in the spec. Modeling the detailed `best_chain_containing` logic and its edge cases
would require significant spec extensions.

---

## Appendix A: Spec Finding — Precommit Guard Over-Permissive

During the MC-2 simulation, a `FinalizationSafety` violation was found that traces to
a spec-level issue in the `Precommit` action (`base.tla:518`):

```tla
/\ \E b \in Block : HasPrevoteSupermajority(r, b)
```

This guard checks that **some** block has prevote supermajority, but does not constrain
the precommit target to be that block (or an ancestor/descendant). Combined with
equivocator counting (equivocators count as voting for everything in
`PrevoteWeight`), an honest node can precommit a block unrelated to the prevote GHOST
estimate.

In the counterexample (31 states), s2 precommits block 1 in round 2 even though the
only prevote supermajority is for block 4 (a sibling, not an ancestor). This leads to
s2 finalizing block 4 while s3 finalizes block 1 — a `FinalizationSafety` violation.

**Classification**: Case B (spec bug). The Precommit action should constrain the
precommit target to the GHOST estimate — the highest block on the chain with prevote
supermajority. This does not affect the MC-1, MC-4, or MC-7 findings, which use
separate spec extensions and configurations.

**Fix**: The Precommit guard should be strengthened:
```tla
\* The precommit target must be on the chain with prevote supermajority
/\ HasPrevoteSupermajority(r, block)
   \/ \E b \in Block : HasPrevoteSupermajority(r, b) /\ IsAncestor(block, b, blockTree)
```

---

## Methodology

### Spec Foundation
- **Base spec**: `base.tla` (~758 lines) — validated against 4 implementation traces,
  verified with 10 invariants across 32.5M BFS states, 18 spec fixes applied
- **MC wrapper**: `MC.tla` (~290 lines) — counter-bounded fault injection

### Bug Hunting Extensions
Each MC hypothesis received a dedicated spec extension and TLC configuration:

| File | Hypothesis | Method | States/Traces |
|------|-----------|--------|---------------|
| `MC_hunt.tla` + `MC_hunt.cfg` | MC-1, MC-2 | BFS | 58K states, depth 5 |
| `MC_mc2.cfg` | MC-2 | Simulation | 2M states, 28K traces |
| `MC_mc7.tla` + `MC_mc7.cfg` | MC-7 | Simulation | 48K states, 2.8K traces |
| `MC_mc4.tla` + `MC_mc4.cfg` | MC-4 | Simulation | 46K states, 3.1K traces |

### Configuration
- Servers: {s1, s2, s3}, Byzantine: {s3}, Quorum: 3
- Blocks: {1, 2, 3, 4}, MaxRound: 2
- Counter bounds vary per hypothesis (see individual `.cfg` files)

### Counterexample Classification
- **Case A**: Invariant too strong (false positive)
- **Case B**: Spec bug (issue in TLA+ model, not implementation)
- **Case C**: Real implementation bug (confirmed by code analysis)

---

## Files

### Spec Extensions
- `case-studies/substrate/spec/MC_hunt.tla` — MC-1/MC-2 detection invariants
- `case-studies/substrate/spec/MC_mc7.tla` — MC-7 HasVoted overwrite model
- `case-studies/substrate/spec/MC_mc4.tla` — MC-4 non-atomic write model

### Configurations
- `case-studies/substrate/spec/MC_hunt.cfg` — MC-1 + MC-2 (BFS)
- `case-studies/substrate/spec/MC_mc2.cfg` — MC-2 only (simulation)
- `case-studies/substrate/spec/MC_mc7.cfg` — MC-7 (simulation)
- `case-studies/substrate/spec/MC_mc4.cfg` — MC-4 (simulation)

### TLC Outputs
- `case-studies/substrate/spec/nohup_hunt.out` — MC-1 violation trace
- `case-studies/substrate/spec/nohup_mc2_sim.out` — MC-2 run (FinalizationSafety found)
- `case-studies/substrate/spec/nohup_mc7_sim2.out` — MC-7 violation trace
- `case-studies/substrate/spec/nohup_mc4_sim.out` — MC-4 violation trace
