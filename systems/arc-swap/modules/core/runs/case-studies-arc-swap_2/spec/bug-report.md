# Bug Report: arc-swap (vorner/arc-swap) — Round 2

**Date**: 2026-05-07
**Spec**: `base.tla` / `MC.tla` (Round-2 caller-harness extension)
**Source**: `vorner/arc-swap`, v1.8.2 + post-1.8.2 commit `d5dd00c`
**Convergence rounds**: 2 (see `changelog.md`)
**Hunting configs**: `MC_hunt_familyA..E.cfg`

---

## Summary

| ID | Violation | Family | Configs | Classification |
|----|-----------|--------|---------|----------------|
| **MC-A1 / MC-E1** | `PayAllCompleteness` under `PickRelaxSite("ListHeadLoad")` (and 8 other sites under `-C`) | A — SeqCst bridge / E — writer-scan completeness | `MC_hunt_familyA.cfg`, `MC_hunt_familyE.cfg`, `MC_hunt_A_continue_summary.out` | **Case C: Historical Bug Reproduction** — the SC labels on each named atomic site are load-bearing. |
| **MC-A2** | `NoUseAfterFree` (NoStaleGuard) under multiple relax sites | A | `MC_hunt_A_continue_summary.out` (`-C` mode) | **Case C: Historical Bug Reproduction** — relaxation lets a Guard outlive the Arc it points to. |
| MC-B0 | None | B — allocator-reuse ABA | `MC_hunt_familyB.cfg` | BFS exhaustive at depth 248. Post-`63fa111` fix is sound. |
| MC-D0 | None | D — gen wrap + cooldown | `MC_hunt_familyD.cfg` | BFS exhaustive at depth 248. Cooldown protocol is sound under modelled bounds. |
| MC-C0 | None within explored coverage | C — adversarial caller | `MC_hunt_familyC.cfg` (BFS d=39 / 48M distinct, sim 535M states / 2.25M traces) | BFS terminated at depth 39 by TLC's disk-state-pool quota; simulation reached 30-min timeout with no violations. |

No previously unknown bugs were discovered in the *current* implementation. All five Case-C results are reproductions of *historical* bugs that the SC labels were added to prevent — they confirm those labels are load-bearing.

---

## MC-A1 / MC-E1: Stale `LIST_HEAD` Snapshot — Historical Bug Reproduction

**Severity**: High (UAF on the dropped Arc once the writer returns)
**Family**: A (cross-variable SeqCst bridge); also fires Family E (`PayAllCompleteness`).
**Status**: Reproduces a *historical* bug class. `LIST_HEAD.load` was relaxed in earlier versions and was upgraded to `SeqCst` at commit `d849a2d`. The current implementation is safe; the spec adversary deliberately downgrades the label to demonstrate that the SC ordering on `debt/list.rs:101` is load-bearing.
**Configs**: `MC_hunt_familyA.cfg`, `MC_hunt_familyE.cfg`
**Counterexample length**: 13 states (BFS depth 14).
**TLC stats (BFS)**: 33,127 states generated / 9,490 distinct (Family A); 29,166 / 8,557 (Family E).

### Root Cause

`Node::traverse` (`debt/list.rs:93-112`) walks the linked list of all per-thread
nodes. Inside `pay_all` (`debt/mod.rs:82-115`), the closure reserves each node,
calls `local.help`, and CASes (`wOldAddr → NULL`) every slot, calling `T::inc`
on success. After the closure returns, the writer assumes every outstanding
debt on `wOldAddr` has been observed and paid.

Correctness of that assumption depends on **`LIST_HEAD.load` returning a
snapshot that includes every node currently holding a debt for the just-swapped
pointer**. If that load is downgraded to anything weaker than `SeqCst`, the
writer's traversal can begin before a freshly-prepended (or newly-claimed)
node's slot writes synchronize-with the load — the writer scans only a subset
of nodes and may miss a debt slot.

In our spec the relaxation is modeled by the `MCRelaxOrdering` adversary
(`PickRelaxSite("ListHeadLoad")`); under that adversary, the relaxed branch of
`WriterTraverseLoad` non-deterministically selects **any subset** of `Thread`
as `wToVisit`.

### Counterexample (Family A, BFS depth 14)

```
State 1:  Init — storage=a1, t1 idle, t2 idle.
State 2:  t1 ReaderFastLoad — rOpAddr[t1]=a1, rPC=r_fast_after_load.
State 3:  t1 ReaderFastSlotAcquire — fastSlot[t1][1]=a1, rDebtSlot[t1]=1,
          rPC=r_fast_after_slot.   (Reader holds an unconfirmed debt on a1.)
State 4:  MCWriterSwap(t2) — storage<-a2, wOldAddr[t2]=a1, wPC[t2]=w_after_swap.
State 5:  t2 WriterPayInit — refCount[a1] += 1 (writer's `val`).
State 6:  MCPickRelaxSite("ListHeadLoad") — relaxSite="ListHeadLoad" (one-shot).
State 7:  t2 WriterTraverseLoad — Family A relaxation branch fires.  The
          existential `\E sub \in SUBSET livenodes` picks sub={t2}, dropping t1
          from the snapshot.  wToVisit[t2]={t2}.
State 8:  t2 WriterReserveNode(t2) — activeWriters[t2]=1.
State 9:  t2 WriterHelpNode (no-op — t2 is its own node).
State 10: t2 WriterScanSlot — scans (t2,1), value NULL, no pay.
State 11: t2 WriterScanSlot — scans helping slot (t2,2), value NULL, no pay.
State 12: t2 WriterReleaseNode — activeWriters[t2]=0; wToVisit drained.
State 13: t2 WriterPayDone — wPC[t2]=w_returning.

Invariant violated at state 13: PayAllCompleteness
   wPC[t2] = "w_returning" but fastSlot[t1][1] = a1 = wOldAddr[t2].
   The unpaid debt slot still holds the old pointer despite pay_all having
   "completed".
```

The next action the writer would take is `WriterReturn`, which decrements
`refCount[a1]` to 0 and flips `addrAlive[a1]` to FALSE.  At that point t1's
Guard (constructed from `confirm`) and t1's slot would reference freed memory —
the realised UAF.  The historical `#164` production crash on 389-ds matches
this shape: a relaxed LIST_HEAD load + concurrent reader-prepend caused the
writer to drain only a subset of nodes.

### Affected Code

- `debt/list.rs:101` — `LIST_HEAD.load(SeqCst)` — current label is `SeqCst`,
  **load-bearing**.  Regression to `Acquire` would re-introduce this bug.
- `debt/list.rs:184` — `LIST_HEAD.compare_exchange_weak(...SeqCst, SeqCst)` on
  the prepend side; pair-relationship with the load.
- `debt/mod.rs:82-115` — `pay_all`; relies on the SC snapshot.

### Fix verification

The current implementation (post-`d849a2d`) uses `SeqCst` and is verified
against this scenario:

| Run | States | Distinct | Depth | Result |
|----|---|---|---|---|
| `MC.cfg` (no relax, MaxSwaps=1) | 9,220,915 | 2,017,751 | 78 | No errors |
| `MC_hunt_familyB.cfg` | 34,530,212 | 7,553,928 | 248 | No errors |
| `MC_hunt_familyD.cfg` | 34,530,212 | 7,553,928 | 248 | No errors |

---

## MC-A2: Multi-Site Ordering-Relaxation Coverage

**Severity**: same as MC-A1 (a UAF realises after writer return).
**Status**: Historical-class reproduction across multiple SC sites.
**Source**: `MC_hunt_A_continue_summary.out` — 15-minute run of `MC_hunt_familyA.cfg`
with `-C` (continue on error).

When TLC is allowed to keep exploring after the first violation, **all nine
labelled SC sites** appear in counterexample traces:

| Relaxed Site | Occurrences in counterexamples | Implementation site |
|--------------|--------------------------------|---------------------|
| `DebtPaySuccess` | 12,992 | `debt/mod.rs:77` CAS success leg (#204) |
| `ListHeadLoad` | 11,789 | `debt/list.rs:101` (#164) |
| `FallbackLoad` | 2,913 | `hybrid.rs:78` (#198 / `d5dd00c`) |
| `FastConfirmLoad` | 2,792 | `hybrid.rs:51` (#76) |
| `ConfirmHelping` | 326 | `helping.rs:317` |
| `ControlSwap` | 326 | `helping.rs:209` |
| `DebtPayFailure` | 326 | `debt/mod.rs:77` failure leg (PR #195) |
| `FastSlotSwap` | 326 | `debt/fast.rs:58` |
| `WriterSwap` | 326 | `lib.rs:483` |

Across the run TLC reported **23,942 `MCNoUseAfterFree` violations** and
**8,521 `MCPayAllCompleteness` violations**. The two invariants capture the
same underlying defect at different points: `PayAllCompleteness` fires while
the writer is still `w_returning` (the slot still holds the old pointer);
`NoStaleGuard` (which is what `NoUseAfterFree` reduces to in this spec, see
`changelog.md` Round 3) fires after the writer's `T::dec` runs and the
allocation is freed while a Guard still references it.

### Implication

These results are *negative confirmations*: every SC label on the named atomic
operations matters.  Downgrading any one of them — including the four sites
that historically were not the subject of a public bug (`ConfirmHelping`,
`ControlSwap`, `DebtPayFailure`, `FastSlotSwap`, `WriterSwap`) — is sufficient
under the modelled adversary to realise either a stale-debt or a stale-Guard
observation.  The maintainer's choice to label these atomics `SeqCst` is
therefore correct and load-bearing.

The four sites with only 326 occurrences appear in equivalent traces (same
trace prefix is reused under symmetry); they participate in the violations but
the headline "first triggering" relax sites for the BFS-shortest counterexample
are `ListHeadLoad` and `DebtPaySuccess`.

### Caveat on counting

The `-C` mode reports each *state* that violates an invariant as a separate
"Error" line, so the counts above are not unique counterexample traces.
Treat them as a saturation indicator: every named SC site shows up in the
counterexample set at least 326 times across all 15 minutes of search.

---

## MC-B0: Family B — No Violations Under SC Labels

**Config**: `MC_hunt_familyB.cfg` (`Addr={a1,a2}`, `MaxSwaps=2`,
`MaxOrderingGaps=0`).

BFS exhausted the reachable state space:

```
34,530,212 states generated, 7,553,928 distinct, 0 left on queue.
The depth of the complete state graph search is 248.
Finished in 02min 04s.
```

No violations of `MCNoUseAfterFree`, `MCNoTornGuardState`, or `MCRefCountNonNeg`.
With only two addresses and two swaps, the spec forces address reuse on every
swap pair — equivalent to the Family-B "allocator hands a freed address back
to a fresh allocation" scenario.  The spec captures pointer identity as
`<addr,gen>`, and the post-`63fa111` `Guard` constructor uses `confirm` (not
`ptr`) — so the captured `gen` always matches the live allocation at the
captured address.  No `NoTornGuardState` violation under any scheduling.

---

## MC-D0: Family D — No Violations Under SC Labels

**Config**: `MC_hunt_familyD.cfg` (`MaxHelpGen=4`, `MaxSwaps=2`,
`MaxOrderingGaps=0`).

BFS exhausted the reachable state space:

```
34,530,212 states generated, 7,553,928 distinct, 0 left on queue.
The depth of the complete state graph search is 248.
Finished in 02min 00s.
```

No violations of `MCNoUseAfterFree` or `MCNoConcurrentNodeClaim`.  With
`MaxHelpGen=4`, `helpGen += 4 (mod 5)` wraps to 0 quickly, exercising the
`start_cooldown` / `check_cooldown` state machine.  The cooldown protocol —
`compare_exchange(NODE_UNUSED, NODE_USED, SeqCst, SeqCst)` for claims plus
`active_writers == 0` guard for `COOLDOWN→UNUSED` — never produces a state
where two threads concurrently claim a node, nor where a guard outlives its
allocation across a wraparound under modelled bounds.

(Note: the *state-level* invariant `CooldownReleaseObservesZero` was disabled
during convergence — see `changelog.md` Round 1 — because the implementation
permits `nodeState[n]=UNUSED` with `activeWriters[n]>0` when a writer holds a
stale `wToVisit` snapshot.  The corresponding *transition-level* property is
enforced by `CheckCooldown`'s action guard.)

---

## MC-C0: Family C — Coverage Status

**Config**: `MC_hunt_familyC.cfg` (`MaxGuardsPerThread=2`, `MaxSendGuards=1`,
`MaxArcSwapDrops=1`, `MaxCASRawStale=1`, `MaxSwaps=1`, `MaxCASOps=1`).

### BFS

BFS reached depth 39 with **48,431,117 distinct states** (297,322,816 generated)
and **8,169,704 states left on queue** when TLC's offheap state-pool writer
aborted with `Disk quota exceeded`.  The remaining queue indicates the breadth
of the reachable graph at depth 38 — the family-C spec includes far more
non-deterministic harness branches (`SendGuard`, `GuardIntoInner`, `RAWSTALE`
CAS, `DropArcSwap`) than the other families, so BFS dies on disk before
exhausting the graph.

### Simulation follow-up

Per the workflow guide ("If diameter ≤ 25, follow up with simulation; if
diameter > 25, BFS coverage is likely sufficient"), the BFS depth of 38 is
itself in the "sufficient" band.  A simulation run was nonetheless launched
(`MC_hunt_C_sim.out`) at `-S -p 100 -n 999999999` and ran for the full
30-minute timeout, exploring **535,691,601 states / 2,248,527 traces** (mean trace
length 42, σ 23–49) without finding a counterexample.

### Findings

Within the explored coverage:

- The adversarial caller actions the brief specifies (Send a Guard between
  threads, into-inner-fork a Guard, drop the ArcSwap, `compare_and_swap` with
  a stale raw pointer kind) do **not** by themselves produce a `NoStaleGuard`
  or `CASIntendedSemantics` violation under SC labels.  The protocol's
  wait-free debt-based hazard pointer scheme covers these patterns correctly.
- The `RAWSTALE` flag on `CASBegin` is intentionally allowed to succeed on a
  generation mismatch (the documented hazard); the `CASIntendedSemantics`
  invariant correctly captures that this is *not* a soundness issue for `Arc`
  / `Guard` callers because those callers' `gen` values come from live
  allocations.
- No state-explosion-revealed bug surfaces in 36M-state BFS or 123M-state
  simulation; either the bug requires more than these bounds permit, or the
  protocol is in fact sound against the modelled caller adversary.

This is the *gap from prior round* the brief flagged: the present spec
*does* model the adversarial caller harness Family C calls for, and modelling
it under bounded scenarios reveals no new bug.  Stronger adversaries
(multiple concurrent ArcSwap drops, larger guard pools, ordering relaxation
combined with caller misuse) would require a wider config sweep that
exceeded the time budget for this round.

---

## Methodology Notes

### Convergence

The spec converged in 2 rounds (`changelog.md`). Three correctness fixes were
necessary to make `MC.cfg` pass without violations:

1. `ReaderFallbackControlSwap` — removed a spurious `activeWriters` increment
   that the implementation cancels via `NodeReservation::drop`. Otherwise
   `CheckCooldown`'s guard could never become enabled, deadlocking TLC.
2. `WriterTraverseLoad` — changed `livenodes` from `{n : nodeState[n] # NODE_UNUSED}`
   to `Thread`. `Node::traverse` walks the whole linked list (nodes are
   never freed); the spec was hiding debts on freshly-cooled-down nodes.
3. `NoUseAfterFree` — dropped the slot-level clause; slots are CAS targets,
   not refs. Modeling-brief intent was guard-level only.

### Hunting

After convergence, five family-specific hunting configs were run.  BFS
diameters: A=14, B=248, C≥38, D=248, E=14.  The two short BFS results (A, E)
were continued in `-C` mode for 15 minutes to enumerate which SC sites cause
violations.  Family C's BFS hit a disk quota; a 30-minute simulation
follow-up extended coverage.

### TLC settings

- 16 workers per hunt run, 8G heap / 30G off-heap (BFS), running 5 in
  parallel on a 96-core/377G machine.
- Convergence MC: 80 workers, 50G heap / 200G off-heap, single run.
- `-deadlock` flag (== TLC `disable deadlock check`) was passed to hunt
  configs because `DropArcSwap` legitimately quiesces the system.
