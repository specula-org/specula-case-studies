# Bug Report — arc-swap (Round 4)

## Summary

- Bug families tested: 5
- Real bugs (Case C) found: 1 (Family 5 — documented MC5 panic)
- Expected sensitivity findings (Case A, counter-factual to past upstream fixes): 4 historical Family-1-style UAFs + 1 Family 4 design-pattern reachability
- Configs run: MC_hunt_family1.cfg, MC_hunt_family2.cfg, MC_hunt_family3.cfg, MC_hunt_family4.cfg, MC_hunt_family5.cfg
- All 5 hunt configs were exercised with BFS; high-priority Family 2 and Family 3 also exercised with simulation.
- The implementation under current SeqCst ordering is sound for Families 2 and 3 (no SC-only violations across BFS-depth-44 / 198M distinct states for F2 and 78,459 sensitivity-traced violations for F3 — every F3 violation requires one explicit relaxation).

---

## Bug 1: Family 5 — Generation Wrap Panic in `confirm_helping`

- **Bug Family**: F5 — Action Granularity Audit (`new_helping` / `confirm_helping` split)
- **Severity**: Medium (panic surface; practically unreachable on 64-bit, reachable on 32-bit after 2^30 fallback calls)
- **Invariant violated**: `MCNoDanglingTransaction`
- **Config**: `MC_hunt_family5.cfg` (MaxHelpGen=4)
- **Counterexample**: 28 states, BFS, 6s — `output/MC_family5_bfs.out`

### Trace Summary

The BFS counterexample drives reader `t1` through the helping path with `MaxHelpGen=4`,
forcing `helpGen.wrapping_add(4) % 5 == 0` on the first fallback call:

1. State 1–N: t1 enters the fallback path. `ReaderFallbackActiveAddr(t1)` writes `helpActiveAddr[t1]`.
2. `ReaderFallbackControlSwap(t1)` swaps `control` to `gen | GEN_TAG`. `pendingHelpingTx[t1] = TRUE`. The new `gen = 0` because of wrap, so `rWrapDiscard[t1] = TRUE`.
3. `ReaderFallbackDiscardNode(t1)` runs `start_cooldown + self.node.take()`:
   - `nodeState[t1] = COOLDOWN`
   - `localNode[t1] = NoneGid`
   - `nodeOwner[t1] = NoneGid`
   - `pendingHelpingTx[t1]` remains TRUE
4. State 28 (violation): `pendingHelpingTx[t1] = TRUE ∧ localNode[t1] = NoneGid` — `NoDanglingTransaction` is violated.

### Root Cause

In `LocalNode::confirm_helping` (`debt/list.rs:312`), the very first line is:
```rust
let node = &self.node.get().expect("LocalNode::with ensures it is set");
```

But after `LocalNode::new_helping` (`debt/list.rs:288–298`) takes the discard path, it
calls `self.node.take()`, leaving `self.node = None`.  The next call to `confirm_helping`
panics at `expect()`.

The split between control-swap (`helping.rs:213`) and node-take (`list.rs:296`) is a
genuine action-granularity hole: the implementation separated the previously-atomic
acquire (`08efd1f`) and forgot to gate the subsequent `confirm_helping` on
`self.node.is_some()`.

### Affected Code

- `src/debt/helping.rs:191–217` — `Slots::get_debt` writes control before computing `discard`.
- `src/debt/list.rs:288–298` — `LocalNode::new_helping` calls `self.node.take()` on discard.
- `src/debt/list.rs:312` — `LocalNode::confirm_helping` immediately re-reads `self.node`.

### Recommendation

Either:
1. Move `self.node.take()` to AFTER `confirm_helping` returns (defer the take), or
2. Add an early-return path in `LocalNode::confirm_helping` if `self.node.is_none()`,
   returning `Err` (caller-side cleanup) instead of panicking.

Triggering requires `2^62` fallback calls per thread on 64-bit (effectively unreachable),
or `2^30` on 32-bit (≈1 billion calls — reachable in long-lived stress). Mainline
maintainer triage: the closed issue is consistent with treating this as a hardening
defect rather than a hot-path bug.

---

## Bug 2: Family 4 — CooldownDrainSafety Violated Under SC (MC4 Precondition)

- **Bug Family**: F4 — Generation Wraparound + Cooldown ABA Window
- **Severity**: Low–Medium (precondition for documented ABA; not exploited under SC + 2 threads)
- **Invariant violated**: `MCCooldownDrainSafety` (steady-state form)
- **Config**: `MC_hunt_family4.cfg` (MaxHelpGen=4, MaxOrderingGaps=0)
- **Counterexample**: 33 states, BFS, 6s — `output/MC_family4_bfs.out`

### Trace Summary

1. States 1–27: t1 enters helping path; helpGen wraps; `ReaderFallbackControlSwap(t1)` triggers wrap-discard.
2. State 27→28: `ReaderFallbackDiscardNode(t1)` — `nodeState[t1] = COOLDOWN`, `localNode[t1] = NoneGid`, `nodeOwner[t1] = NoneGid`. `activeWriters[t1]` is still 0 in the model (start_cooldown's net-zero abstraction).
3. State 28→29: `CheckCooldown(t1)` succeeds (`activeWriters[t1] = 0 ∧ nodeState = COOLDOWN`) → `nodeState[t1] = UNUSED`.
4. State 29→30: `WriterSwap(t2)` — t2 swaps storage to a new pointer.
5. State 30→32: t2 progresses through `WriterPayInit → WriterTraverseLoad`. `wToVisit[t2] = {t1, t2}` (the writer's pay_all walks all nodes via `Node::traverse`).
6. State 32→33: `WriterReserveNode(t2)` reserves node t1 (UNUSED). `activeWriters[t1] = 1`, `inflightHelp[t1] = {t2}`. **Invariant `nodeState[n] = UNUSED ⇒ inflightHelp[n] = ∅` is violated.**

### Root Cause

This is the precondition documented in modeling-brief §2 Family 4: the implementation's
`Node::traverse` (`debt/list.rs:93–112`) walks the *entire* linked list on every
`pay_all`, including nodes whose `in_use` field is `UNUSED`. `reserve_writer`
(`debt/list.rs:148–152`) does `active_writers.fetch_add(1, Acquire)` *unconditionally*
— there is no `nodeState != UNUSED` guard.

The cooldown mechanism's safety claim is narrower than the steady-state form of the
spec invariant: cooldown only prevents *claims* (`Node::get`'s `compare_exchange(UNUSED,
USED, …)`) while a writer is mid-scan. Once `active_writers` drops to 0 and
`check_cooldown` transitions COOLDOWN→UNUSED, both **a new claim AND a new writer
reservation** become legal. The implementation relies on:
- The slot-pay CAS at `debt/mod.rs:109` matching exactly on `wOldAddr` (so a new
  owner's later writes to slots don't get "paid" by the original writer's pay_all).
- The help CAS at `helping.rs:235–238` matching exactly on `(gen, GEN_TAG)` (so stale
  GEN tags from a wrap-discarded reader don't get answered to a new owner).

Both checks rely on SC ordering. Under SC + 2 threads, the spec's BFS does not exhibit
an actual safety violation downstream of this state.

### Classification

This violation is **Case A (invariant too strong)** with respect to the
implementation's actual semantics. The brief's intent (per §2 Family 4) was the
*transition* form: "*at the moment* of COOLDOWN→UNUSED, `inflightHelp = {}`" — which
is implied by `InflightHelpBounded`+ the `activeWriters = 0` precondition of
`CheckCooldown`. The spec's steady-state form is aspirational and rules out a state
the implementation deliberately allows.

The PRECONDITION for the F4 ABA (writer reservation + UNUSED + leftover GEN tag) IS
reachable. With ≥3 threads and either (a) Family 1 relaxation of `helpControl`'s gen
bits or (b) a missing exact-gen check in `WriterHelpNode`, the actual ABA could
manifest. Our model (Threads = {t1, t2}, MaxOrderingGaps = 0) does not exhibit the
downstream unsafety.

### Affected Code

- `src/debt/list.rs:93–112` — `Node::traverse` walks all nodes (including UNUSED).
- `src/debt/list.rs:148–152` — `reserve_writer` has no nodeState guard.
- `src/debt/list.rs:115–145` — `start_cooldown` / `check_cooldown` lifecycle.

### Recommendation

- **Spec**: change `CooldownDrainSafety` from steady-state to transition form, OR keep
  it steady-state and expand the model to {t1, t2, t3} + Family 1 relaxation to expose
  the downstream ABA. The current form catches the precondition but cannot witness the
  actual unsafety in 2-thread + SC mode.
- **Implementation**: no change recommended without seeing an exhibitor. The current
  design is sound under SC; documenting that "writers may reserve UNUSED nodes during
  pay_all, relying on slot-CAS exact-match for safety" would clarify the invariant.

---

## Sensitivity Findings (Case A — Confirm Spec Faithfulness Against Past Fixes)

These violations are **expected by design** (per modeling-brief §2 Family 1 and §6.1
MC2/MC3): each represents a counter-factual downgrade of an SC site that was upgraded
in mainline (PR #195, PR #203, PR #204, #76, #164). The fact that the spec exhibits
these violations under the corresponding relaxation confirms it is faithful enough to
expose pre-fix bugs; absence of any SC-only counterexample (`relaxSite = NoneSite`)
across all hunts confirms the current SC saturation is sufficient.

### F1 — DebtPayFailure Relaxation → UAF

- **Trigger**: `MCPickRelaxSite("DebtPayFailure")` → `~IsSC("DebtPayFailure")`
- **Mechanism**: `Debt::pay`'s failure leg with Relaxed ordering. The reader's
  spurious-failure leg (`base.tla:450–462`) creates a `Guard` with `hasDebt=FALSE`
  (impl thinks "writer paid me — refcount bumped"), but the writer's `T::inc` is
  not yet visible to the reader. When the reader drops the guard, `T::dec` decrements
  an unincremented refcount → UAF on `wOldAddr`.
- **Counter-factual to**: PR #195 / commit `bd5d327` (Relaxed → Acquire), later
  strengthened by PR #204 / `cccf354` (Acquire → AcqRel for transitivity).
- **Output**: `output/MC_family1_bfs.out`, 12 states, depth 15.

### F1 / F3 — FallbackLoad Relaxation → UAF / StaleSnapshot / PayAllCompleteness

- **Trigger**: `MCPickRelaxSite("FallbackLoad")` → `~IsSC("FallbackLoad")`
- **Mechanism**: `hybrid.rs:83` `storage.load(SeqCst)` downgraded to `Acquire`. The
  reader's fallback `candidate` load returns a stale (already-freed) address, and
  the slot-store publishes a debt on a freed pointer (`base.tla:580–590`). When the
  next writer scans, it cannot see this slot's debt → frees the still-alive stale
  pointer → UAF.
- **Counter-factual to**: PR #203 / commit `d5dd00c` (Acquire → SeqCst).
- **Output**: `output/MC_family3_sim.out` shows the dominant per-site count
  (FallbackLoad → 59,444 `MCStaleSnapshotSafety` + 18,489 `MCPayAllCompleteness` + 1,246 `MCNoUseAfterFree` = 79,179 violations of which all require a relaxation).

### F1 / F3 — ListHeadLoad Relaxation → PayAllCompleteness

- **Trigger**: `MCPickRelaxSite("ListHeadLoad")` → `~IsSC("ListHeadLoad")`
- **Mechanism**: `WriterTraverseLoad` (`base.tla:848–863`) accepts a strict subset of
  `Thread` for `wToVisit` when ListHeadLoad is downgraded — modeling that the writer's
  `LIST_HEAD.load` may miss recently-prepended nodes (#164). The missed node's slots
  hold debts on `wOldAddr`, and the writer never pays them.
- **Counter-factual to**: commit `d849a2d` (#164 — debt-list CAS upgraded to SeqCst-on-failure).
- **Output**: 801 PayAllCompleteness violations in `output/MC_family3_sim.out`.

### F1 — DebtPaySuccess / FastConfirmLoad Relaxations

- **Trigger**: `MCPickRelaxSite("DebtPaySuccess")` / `MCPickRelaxSite("FastConfirmLoad")`
- **Mechanism**: 
  - DebtPaySuccess: writer's pay-CAS spuriously fails to see a debt the reader published
    with full SC (`base.tla:933–937`).  Recreates #76 / #204.
  - FastConfirmLoad: reader's confirm load returns a stale value (`base.tla:391`), can
    let the reader carry an already-freed pointer past the confirm.
- **Counter-factual to**: #76 (FastConfirmLoad) and #204 / `cccf354` (DebtPaySuccess).
- **Output**: visible in `output/MC_family3_sim.out` via per-site violation breakdown
  (185 + 134 + 62 traces).

---

## Not Reproduced

| Bug Family | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| F2 — Caller misuse | `MC_hunt_family2.cfg` BFS | 1.34B states, 198M distinct, depth 44, 30 min | No violation |
| F2 — Caller misuse | `MC_hunt_family2.cfg` simulation | 489M states / 1.84M traces, sim depth 100, ~10 min | No violation |
| F3 — Stale snapshot under SC | `MC_hunt_family3.cfg` BFS | 27,803 states, depth 15, 5 s before any-relaxation violation hit | No SC-only violation; all 80,430 sim violations require a relaxation site |
| MC1 (debt accounting on guard fork) | F2 — Caller misuse harness with `GuardClone` × `SendGuard` × `DropArcSwap` × `CASRawStale` | 198M+ distinct states across BFS+sim | Did not produce `RefCountAccounting` / `NoOrphanedDebt` violation under SC |
| MC6 (concurrent CAS pay_all) | F2 hunt | covered by `MaxCASOps=1 + MaxSwaps=1` interleavings | Did not produce double/missed pay |
| MC4 (full ABA exhibition) | F4 hunt | depth-33 BFS counterexample exhibits the *precondition* (Bug 2 above) but not the downstream ABA on a third thread; would need Threads = {t1, t2, t3} | Precondition reachable; downstream unsafety not witnessed in 2-thread + SC mode |

---

## Spec Adjustments During Hunting

None. The spec converged in Round 1 (Phase 2 found no MC.cfg violations) and was used
unchanged across all five hunt configs. All findings above stem from the bug-family
invariants enabled per cfg, not from spec modifications.
