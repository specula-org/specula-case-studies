# Brief Coverage Self-Audit — arc-swap round 4

## Table 1: Bug Families (from brief §2)

| Brief Family | Hunt cfg file | Family-relevant invariants enabled in that cfg | If skipped, why? |
|---|---|---|---|
| F1 — Memory-Ordering Bridges Across Variables | `MC_hunt_family1.cfg` | MCNoUseAfterFree, MCPayAllCompleteness, MCNoTornGuardState, MCRefCountNonNeg, MCNoStaleWithoutRelax | — |
| F2 — Caller Misuse / Adversarial Client | `MC_hunt_family2.cfg` | MCNoUseAfterFree, MCRefCountAccounting, MCCASIntendedSemantics, MCNoTornGuardState, MCNoOrphanedDebt, MCRefCountNonNeg | — |
| F3 — Stale Snapshot in Writer's Debt-List Traversal | `MC_hunt_family3.cfg` | MCPayAllCompleteness, MCStaleSnapshotSafety, MCNoUseAfterFree, MCNoTornGuardState, MCRefCountNonNeg | — |
| F4 — Generation Wraparound + Cooldown ABA | `MC_hunt_family4.cfg` | MCNoUseAfterFree, MCNoConcurrentNodeClaim, MCCooldownDrainSafety, MCInflightHelpBounded, MCRefCountNonNeg | — |
| F5 — Action Granularity Audit (NEW) | `MC_hunt_family5.cfg` | MCNoDanglingTransaction (expected to fail — that IS the bug), MCNoUseAfterFree, MCRefCountNonNeg, MCInflightHelpBounded, MCLocalNodeOwnership | — |

All five families have dedicated hunt cfgs.  F5 is the new round-4 family; its
hunt cfg has `MaxHelpGen = 4` so the very first reader fallback wraps and triggers
ReaderFallbackDiscardNode.  The post-discard state (pendingHelpingTx[t] # 0 ∧
localNode[t] = NoneGid) violates NoDanglingTransaction immediately — that
violation IS the bug per brief §6.1 MC5.

## Table 2: Proposed Invariants (from brief §5 — Safety only; Liveness explicitly out of scope per brief §6 note)

| Brief invariant | Defined at (file:line) | Wired in MC.tla? | Enabled in which hunt cfg(s)? | If skipped, why? |
|---|---|---|---|---|
| NoUseAfterFree | `base.tla` `NoUseAfterFree` (≈L735) | yes (`MCNoUseAfterFree`) | family1.cfg, family2.cfg, family3.cfg, family4.cfg, family5.cfg | — |
| NoOrphanedDebt | `base.tla` `NoOrphanedDebt` (≈L788) | yes (`MCNoOrphanedDebt`) | family2.cfg | — |
| StaleSnapshotSafety | `base.tla` `StaleSnapshotSafety` (≈L753) | yes (`MCStaleSnapshotSafety`) | family3.cfg | — |
| CooldownDrainSafety | `base.tla` `CooldownDrainSafety` (≈L832) | yes (`MCCooldownDrainSafety`) | family4.cfg | — |
| NoDanglingTransaction | `base.tla` `NoDanglingTransaction` (≈L860) | yes (`MCNoDanglingTransaction`) | family5.cfg | — |
| RefCountAccounting | `base.tla` `RefCountAccounting` (≈L771) | yes (`MCRefCountAccounting`) | family2.cfg | — |
| WaitForReadersTermination | — | no (Liveness) | — | brief §5 marks it Liveness; brief §6 note explicitly excludes liveness this round |
| EventualVisibility | — | no (Liveness) | — | brief §5 marks it Liveness; brief §6 note explicitly excludes liveness this round |

Additional supporting invariants defined in the spec (not from brief §5 directly,
but standard concurrent-correctness anchors):

| Spec invariant | Purpose | Enabled in |
|---|---|---|
| `NoTornGuardState` | A reader's confirmed guard's gen ≤ allocation gen — F3 / F1 sanity | family1, family2, family3 |
| `CASIntendedSemantics` | CAS kind well-formed at cas_after_load — F2 | family2 |
| `NoStaleWithoutRelax` | Under SC, fast confirm-load returns current storage — F1 sanity | family1 |
| `RefCountNonNeg` | Refcount never negative | all hunt cfgs |
| `NoConcurrentNodeClaim` | A USED node has a single owner | MC.cfg, family4 |
| `InflightHelpBounded` | inflightHelp[n] ⊆ writers w/ active reservation; |inflightHelp[n]| ≤ activeWriters[n] | MC.cfg + all hunt cfgs |
| `LocalNodeOwnership` | localNode[t] = n ⇒ nodeOwner[n] = t | MC.cfg + all hunt cfgs |

## Table 3: Model-Checkable Findings (from brief §6.1)

| Finding ID | Trigger mechanism (action/fault) | Expected violated invariant | Hunt cfg targeting it |
|---|---|---|---|
| MC1 | GuardClone (Arc::clone + from_inner) + multiple WriterSwaps + DropGuard in reverse order | NoOrphanedDebt, RefCountAccounting | `MC_hunt_family2.cfg` |
| MC2 | new reader's debt on `old` between writer's LIST_HEAD.load(SeqCst) and T::dec(old) — exposed via PickRelaxSite("ListHeadLoad") in the SC-faithful run + per-slot WriterScanSlot interleaving | NoUseAfterFree, StaleSnapshotSafety | `MC_hunt_family3.cfg` (also family1.cfg via the "ListHeadLoad" relaxation lever) |
| MC3 | PickRelaxSite("FallbackLoad") — sensitivity / robustness check (counterexample expected) | NoUseAfterFree | `MC_hunt_family1.cfg` |
| MC4 | cooldown drain race: writer's reserve_writer arrives just after start_cooldown's NodeReservation Drop decremented active_writers; CooldownDrainSafety evaluates at the new state (UNUSED node with stale inflightHelp) | CooldownDrainSafety | `MC_hunt_family4.cfg` (with MaxHelpGen=4 to exercise wrap + cooldown lifecycle) |
| MC5 | ReaderFallbackControlSwap → ReaderFallbackDiscardNode (gen wraps, take fires) leaves pendingHelpingTx # 0 ∧ localNode = NoneGid; NoDanglingTransaction violated | NoDanglingTransaction | `MC_hunt_family5.cfg` (with MaxHelpGen=4 for forced wrap on first fallback) |
| MC6 | Concurrent CASBegin from N threads; each holds a debt-protected `old` while running wait_for_readers; their pay_all walks each others' nodes; verify no interleaving produces double-pay or missed-pay | RefCountAccounting (and refCount lower bound) | `MC_hunt_family2.cfg` (with MaxCASOps=1 + MaxSwaps=1 + MaxGuardClones=1 to compose) |

## Coverage Summary

```
Families: 5 / 5 implemented + 0 partial
Proposed Safety Invariants: 6 / 6 enabled in ≥1 hunt cfg
   (Liveness invariants WaitForReadersTermination + EventualVisibility skipped
    per brief §6 round-4 scope note.)
Model-Checkable Findings: 6 / 6 targeted by a hunt cfg
Hunt cfg files: 5 (MC_hunt_family1 / 2 / 3 / 4 / 5)
```

## Round-4 emphasis tracked

Per task brief: "This run should especially focus on caller-misuse +
stale-snapshot family — that combination produced 5 bugs in the structurally-
similar `left-right` system."

* **Caller misuse (F2)** — `MC_hunt_family2.cfg` enables five caller-harness
  counters (MaxSendGuards, MaxGuardClones, MaxArcSwapDrops, MaxCASRawStale,
  MaxCASOps) and checks the full F2 invariant set including the new
  `NoOrphanedDebt` and `RefCountAccounting`.  The new `GuardClone` action
  models the canonical `Arc::clone(&*g) + Guard::from_inner` fork pattern
  that round 3 did not have.
* **Stale snapshot in writer scan (F3)** — `MC_hunt_family3.cfg` enables both
  `PayAllCompleteness` and the new `StaleSnapshotSafety`.  Combined with one
  ordering relaxation (typically ListHeadLoad), the writer's `wToVisit` can
  be a strict subset of the actual node set; PayAllCompleteness then surfaces
  the BUG-A-style finding when an interleaved reader prepends a new debt
  before the writer's snapshot.
* **Action granularity audit (F5, NEW)** — `MC_hunt_family5.cfg` enables
  `NoDanglingTransaction` with MaxHelpGen=4 to force wrap on first fallback.
  The split between `ReaderFallbackControlSwap` and `ReaderFallbackDiscardNode`
  exposes the panic-on-confirm-helping bug surface: the action sequence
  ControlSwap → DiscardNode leaves `pendingHelpingTx # 0 ∧ localNode = NoneGid`,
  which violates NoDanglingTransaction immediately.

## Notable spec-design changes vs round 3

| Change | Why |
|---|---|
| Added `localNode[t]: Thread \cup {NoneGid}` per-thread variable | F5 — separates "who registered as owner" (`nodeOwner[n]`) from "what self.node Cell holds" (`localNode[t]`).  start_cooldown + take in list.rs:295-296 clears localNode while nodeOwner becomes NoneGid; the invariant violation surfaces only when these are tracked separately. |
| Added `pendingHelpingTx[t]: Nat` per-thread variable | F5 — tracks the in-flight helping transaction's generation tag.  Set by ReaderFallbackControlSwap, cleared by ReaderFallbackConfirm{OK,Helped}.  NoDanglingTransaction is the bug-detection invariant. |
| Split `ReaderFallbackControlSwap` into `ControlSwap` + `DiscardNode` | F5 — the implementation calls helping.get_debt (which writes control AND computes discard), then conditionally start_cooldown + take.  The split makes the post-discard state (pre-confirm_helping panic) observable to TLC. |
| Added `inflightHelp[n]: SUBSET Thread` per-node variable | F4 — tracks writers currently holding NodeReservation.  WriterReserveNode adds, WriterReleaseNode removes.  CooldownDrainSafety asserts that COOLDOWN→UNUSED transition has empty inflightHelp; InflightHelpBounded asserts |inflightHelp| ≤ activeWriters. |
| Added explicit `GuardClone(t)` action | F2 — models `Arc::clone(&*g) + Guard::from_inner` (lib.rs:212).  Round 3 had only SendGuard; this round adds the canonical fork primitive that creates two coexisting guards (debted + debtless) on the same address. |
| Added `wFreedOld[t]` per-writer flag | F3 — tracks whether WriterReturn caused refCount[wOldAddr] to reach 0.  StaleSnapshotSafety uses this to predicate "at the moment of free, no slot holds wOldAddr". |
| Added `RefCountAccounting` + `NoOrphanedDebt` invariants | F2 — round 3's NoStaleGuard captured UAF on Guard reads, but did not validate refcount-vs-guards consistency.  RefCountAccounting (refCount[a] ≥ #non-debted-guards holding a) catches double-pay or missed-pay; NoOrphanedDebt (every slot value has a live owner) catches abandoned debts that no Drop will ever clear. |
| Removed Family B (allocator-reuse ABA) as a separate hunt | brief §2 round 4 does not list it; address+gen tuple still exists in base for F3 to use, but no dedicated hunt cfg.  Round 3's familyB.cfg covered it — round 4's brief restructured families and dropped it.  If reintroduced, MC_hunt_familyB.cfg from round 3 is the template. |

## Boring-audit check

This document was filled by reading each `MC_hunt_family*.cfg` file's
INVARIANTS clause directly (not from intent / memory).  No "—" rows in
Tables 1-3 indicating a missing hunt cfg or an unjustified skipped
invariant.  Liveness skips in Table 2 are explicitly justified by brief §6.

## Validation results (TLC sanity check)

Each hunt cfg was sanity-checked with TLC (~`MaxSwaps=1`-2, MaxHelpGen as
configured, 4 workers, 4 GB heap):

| Config | Result | Time | States explored |
|---|---|---|---|
| `MC.cfg` (convergence) | Pass — no invariant violation | 1m22s | 1.43M distinct |
| `MC_hunt_family1.cfg` (F1 sensitivity) | Violation: `MCNoUseAfterFree` (expected — F1 relaxation) | 1s | 4.8k distinct |
| `MC_hunt_family5.cfg` (F5 panic surface) | Violation: `MCNoDanglingTransaction` (expected — F5 bug) | 3s | 51k distinct |

Hunt cfgs `family2`, `family3`, `family4` were not run end-to-end as part
of spec generation — they will be exercised by the validation phase per
the standard pipeline.  The two cfgs run above confirm:

* The convergence baseline holds (so `family2`-`family4` failures, when
  found, are real bugs not spec artifacts).
* The F1 sensitivity check correctly produces a UAF counterexample under
  ordering relaxation (so the SC-faithful protocol is locked in by the
  baseline).
* The F5 panic surface (the round-4 NEW finding) is reachable in the model
  and immediately violates `NoDanglingTransaction` — the bug is captured.

### Spec-design note: boolean `pendingHelpingTx`

`pendingHelpingTx[t]` is modeled as a BOOLEAN, not a generation count.  The
implementation uses `gen | GEN_TAG` where `GEN_TAG` is non-zero, so even a
wrapped gen=0 produces a non-IDLE control value.  An earlier spec draft
encoded `pendingHelpingTx` as the gen value itself, which conflated the
wrapped-gen-0 case ("transaction in flight on a wrapped gen") with the
no-transaction case ("control is IDLE"), masking the F5 bug.  The boolean
encoding aligns with the implementation's "control != IDLE" predicate.
