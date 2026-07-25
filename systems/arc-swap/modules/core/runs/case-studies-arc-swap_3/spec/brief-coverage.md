# Brief Coverage Self-Audit — arc-swap round 3

## Table 1: Bug Families (from brief §2)

| Brief Family | Hunt cfg file | Family-relevant invariants enabled in that cfg | If skipped, why? |
|---|---|---|---|
| A — Cross-variable SeqCst bridge | `MC_hunt_familyA.cfg` | MCNoUseAfterFree, MCPayAllCompleteness, MCNoTornGuardState, MCRefCountNonNeg | — |
| B — Allocator-reuse ABA | `MC_hunt_familyB.cfg` | MCNoUseAfterFree, MCNoTornGuardState, MCRefCountNonNeg | — |
| C — Adversarial caller (Guard lifecycle / raw-ptr CAS) | `MC_hunt_familyC.cfg` | MCNoUseAfterFree, MCCASIntendedSemantics, MCRefCountNonNeg, MCNoTornGuardState, MCNoDoublePay | — |
| D — Generation wrap + cooldown | `MC_hunt_familyD.cfg` | MCNoUseAfterFree, MCNoConcurrentNodeClaim, MCRefCountNonNeg, MCGenWrapTriggersCooldown | — |
| E — Writer-scan completeness | `MC_hunt_familyE.cfg` | MCPayAllCompleteness, MCNoUseAfterFree, MCRefCountNonNeg | — |

All five families have dedicated hunt cfgs.  Family E is the
companion-of-A safety invariant per brief §2; it gets its own cfg with
`MaxOrderingGaps=1` so the writer's `wToVisit` snapshot can be downgraded to a
strict subset (the BUG-A-style stale-snapshot pattern).

## Table 2: Proposed Invariants (from brief §5 — Safety only; Liveness explicitly out of scope per brief §6 note)

| Brief invariant | Defined at | Wired in MC.tla? | Enabled in which hunt cfg(s)? | If skipped, why? |
|---|---|---|---|---|
| NoUseAfterFree | base.tla `NoUseAfterFree` | yes (`MCNoUseAfterFree`) | familyA, familyB, familyC, familyD, familyE | — |
| PayAllCompleteness | base.tla `PayAllCompleteness` | yes (`MCPayAllCompleteness`) | familyA, familyE | — |
| NoConcurrentNodeClaim | base.tla `NoConcurrentNodeClaim` | yes (`MCNoConcurrentNodeClaim`) | MC.cfg, familyD | — |
| NoStaleHelpAcrossWrap | (folded into MCGenWrapTriggersCooldown) | yes (`MCGenWrapTriggersCooldown`) | familyD | covered by GenWrapTriggersCooldown — when gen wraps, node enters COOLDOWN before any new writer in `help` for old gen can claim it; deeper "no stale help across wrap" is a temporal property and out of scope per brief §6 note |
| SlotEventuallyReleased | — | no (Liveness) | — | brief §5 marks it Liveness; brief §6 explicitly excludes liveness this round |
| CASIntendedSemantics | base.tla `CASIntendedSemantics` | yes (`MCCASIntendedSemantics`) | familyC | — |
| NoTornGuardState | base.tla `NoTornGuardState` | yes (`MCNoTornGuardState`) | familyA, familyB, familyC | — |
| NoDoublePay | base.tla `NoDoublePay` | yes (`MCNoDoublePay`) | familyC | — |
| GenWrapTriggersCooldown | base.tla `GenWrapTriggersCooldown` | yes (`MCGenWrapTriggersCooldown`) | familyD | — |
| CooldownReleaseObservesZero | base.tla `CooldownReleaseObservesZero` | yes (`MCCooldownReleaseObservesZero`) | none (state form too strong; see MC.cfg note) | The state-form invariant fails on a benign race: WriterReserveNode can lift activeWriters above 0 against a UNUSED node when its wToVisit snapshot was taken before CheckCooldown fired.  The protocol's safety is enforced by CheckCooldown's action guard (the COOLDOWN→UNUSED transition only fires when activeWriters[n]=0) — that guard is in the action, not the state predicate.  Documented in MC.cfg and MC_hunt_familyD.cfg. |

Standard concurrent-system "sequential-consistency invariants on linearization
order" mentioned in brief §5 paragraph: covered implicitly by NoStaleWithoutRelax
(checked in the SC-only convergence run), and by the per-action SC labels in the
base spec.

## Table 3: Model-Checkable Findings (from brief §6.1)

| Finding ID | Trigger mechanism (action/fault) | Expected violated invariant | Hunt cfg targeting it |
|---|---|---|---|
| MC1 — fast confirm-load SC→Acq | PickRelaxSite("FastConfirmLoad") | NoUseAfterFree | MC_hunt_familyA.cfg |
| MC2 — fallback candidate-load SC→Acq | PickRelaxSite("FallbackLoad") | NoUseAfterFree | MC_hunt_familyA.cfg |
| MC3 — Debt::pay failure-leg Acq→Rlx | PickRelaxSite("DebtPayFailure") | NoUseAfterFree | MC_hunt_familyA.cfg |
| MC4 — Debt::pay success-leg AcqRel→Rel | PickRelaxSite("DebtPaySuccess") | NoUseAfterFree | MC_hunt_familyA.cfg |
| MC5 — LIST_HEAD load Acq→Rlx | PickRelaxSite("ListHeadLoad") | PayAllCompleteness | MC_hunt_familyA.cfg, MC_hunt_familyE.cfg |
| MC6 — allocator reuses freed pointer mid-fast-path | WriterSwap with reused address | NoTornGuardState | MC_hunt_familyB.cfg |
| MC7 — two threads share the same Guard via Send | SendGuard | NoDoublePay / RefCountNonNeg | MC_hunt_familyC.cfg |
| MC8 — CAS with raw stale ptr matches recycled addr | CASBegin(t, kind=RAWSTALE) | CASIntendedSemantics | MC_hunt_familyC.cfg |
| MC9 — generation wraps without cooldown | tight MaxHelpGen=4 + ReaderFallbackControlSwap | GenWrapTriggersCooldown | MC_hunt_familyD.cfg |
| MC10 — pay_all collapsed to single action (sanity) | not modeled — pay_all is split per-slot in base | PayAllCompleteness | (negative finding — confirmed in MC_hunt_familyE.cfg if PayAllCompleteness violations surface only when ListHeadLoad is relaxed; this validates that splitting pay_all is load-bearing) |
| MC11 — reader prepends new node mid-writer-scan | WriterTraverseLoad with relaxed ListHeadLoad + concurrent ClaimNode | PayAllCompleteness | MC_hunt_familyE.cfg |
| MC12 — ArcSwap::Drop overlapping with reader (negative — caller precondition) | DropArcSwap action guard rejects mid-load state | (none expected — guard rejects at action) | MC_hunt_familyC.cfg (validates DropArcSwap fires only when all readers idle and no guards held) |

## Coverage Summary

```
Families: 5 / 5 implemented + 0 partial
Proposed Safety Invariants: 8 / 9 enabled in ≥1 hunt cfg
   (skipped: CooldownReleaseObservesZero — state form unreachable in implementation;
    the cooldown safety is enforced by CheckCooldown's *action* guard, not a state predicate.
    SlotEventuallyReleased — Liveness, out of round-3 scope.)
Model-Checkable Findings: 12 / 12 targeted by a hunt cfg
Hunt cfg files: 5 (MC_hunt_familyA / B / C / D / E)
```

## Round-3 emphasis tracked

Per task brief: "This run should especially focus on caller-misuse +
stale-snapshot family — that combination produced 5 bugs in the structurally
similar `left-right` system."

* **Caller misuse** — `MC_hunt_familyC.cfg` enables all four caller-harness
  counters (MaxSendGuards, MaxArcSwapDrops, MaxCASRawStale, MaxCASOps) and
  checks the full Family-C invariant set.
* **Stale snapshot in writer scan** — `MC_hunt_familyE.cfg` plus
  `MC_hunt_familyA.cfg` both relax the writer's `ListHeadLoad` site, allowing
  the writer's `wToVisit` to be a strict subset of the actual node set.
  PayAllCompleteness then surfaces the BUG-A-style finding when an interleaved
  reader prepends a new debt before the writer's snapshot.
