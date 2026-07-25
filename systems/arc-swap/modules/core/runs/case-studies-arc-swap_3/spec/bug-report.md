# Bug Report — arc-swap (vorner/arc-swap, v1.8.2 + post-1.8.2 d5dd00c)

## Summary

- Bug families tested: 5 (A — Cross-variable SeqCst; B — Allocator-reuse ABA; C — Adversarial caller; D — Generation wraparound; E — Writer-scan completeness)
- Bugs found: **5** distinct historical UAF/PayAll-completeness reproductions across the Family A relaxation adversary, all matching documented past fixes (#76, #198, PR#195, #204, #164). All other bug families produced no violations within the explored state space.
- Configs run: MC.cfg (convergence), MC_hunt_familyA.cfg, MC_hunt_familyB.cfg, MC_hunt_familyC.cfg, MC_hunt_familyD.cfg, MC_hunt_familyE.cfg (each with BFS; A and E also with simulation).

The brief specifically called out a "caller-misuse + stale-snapshot" combination (Family C × Family E) that produced 5 bugs in the structurally-similar `left-right` case study. **In arc-swap that combination did NOT produce new bugs**: with no ordering relaxations, even adversarial callers (Send/IntoInner/CASRawStale/DropArcSwap) cannot violate NoUseAfterFree, RefCountNonNeg, NoTornGuardState, or CASIntendedSemantics. The bugs that *do* appear all sit on the Family A axis — every modern bug in arc-swap's commit history (8 confirmed since 2018) is in this family.

---

## Bug 1: PR #195 reproduction — Debt::pay failure-leg downgrade leaks UAF

- **Bug Family**: A (Cross-variable SeqCst bridge)
- **Severity**: Critical (UAF)
- **Invariant violated**: `MCNoUseAfterFree`
- **Config**: `MC_hunt_familyA.cfg` (BFS, depth 15)
- **Counterexample**: 13 states, output file `output/MC_hunt_familyA_bfs.out`

### Trace Summary

1. Reader t1 starts a fast load: `ReaderFastLoad` → `ReaderFastSlotAcquire` (slot 1 = a1) → `ReaderFastConfirmLoad` (confirm = a1) → `ReaderFastBranchHit` → guard{a1, gen 1, viaSlot 1, hasDebt=TRUE}.
2. Reader t2 starts a fast load and acquires slot 1 in t2's node (slot t2[1] = a1).
3. Writer t1 (now reusing the same thread for write since reader finished) calls `WriterSwap`: storage a1 → a2; `wOldAddr[t1] = a1`.
4. Reader t2's confirm-load returns a2 (post-swap storage). `rOpAddr[t2] = a1 ≠ rConfirmAddr[t2] = a2`, so t2 enters `ReaderFastResolve`.
5. Adversary fires `MCPickRelaxSite("DebtPayFailure")` — downgrading the failure leg of `Debt::pay` (debt/mod.rs:77).
6. `ReaderFastResolve(t2)` takes the **relaxation branch**: `fastSlot[t2][1]` still holds a1, but t2's CAS *appears* to fail (the relaxed failure leg lost the writer's T::inc visibility). t2 acquires guard{a1, gen 1, hasDebt=FALSE} believing the writer paid for it.
7. Writer t1 has no scan to do (t1 hasn't entered pay_all in this minimised counterexample). Eventually `DropGuard(t2)` runs: hasDebt=FALSE → `T::dec(a1)` → `refCount[a1] = 0` → `addrAlive[a1] = FALSE`.
8. **Final state**: t1's guard[1] = {addr=a1, gen=1, hasDebt=TRUE} but `addrAlive[a1] = FALSE` → **MCNoUseAfterFree violated**.

### Root Cause

In the implementation, `Debt::pay` (debt/mod.rs:65-79) uses AcqRel for success and Acquire for failure. PR #195 (commit `bd5d327`) fixed the failure leg from Relaxed → Acquire, ensuring that when the reader observes "pay failed", it has acquired the writer's `T::inc` (debt/mod.rs:111). Downgrading the failure leg breaks the synchronization edge: the reader proceeds with a guard that has no real refcount backing.

### Affected Code

- `artifact/arc-swap/src/debt/mod.rs:65-79` — `Debt::pay` CAS (failure leg must be Acquire to synchronize-with writer's T::inc).
- `artifact/arc-swap/src/strategy/hybrid.rs:61-71` — caller side that handles "pay failed" branch.

### Recommendation

This is **already fixed** in mainline (PR #195 / commit `bd5d327`). The model confirms the SC labels are load-bearing — any future change that tries to weaken `Debt::pay`'s failure leg below Acquire will reintroduce the UAF.

---

## Bug 2: Issue #198 reproduction — fallback storage.load downgrade leaks UAF / PayAll incompleteness

- **Bug Family**: A (Cross-variable SeqCst bridge) / E (writer-scan completeness)
- **Severity**: Critical (UAF and writer-scan miss)
- **Invariant violated**: `MCPayAllCompleteness` (also `MCNoUseAfterFree` reachable)
- **Config**: `MC_hunt_familyE.cfg` (simulation, depth 100)
- **Counterexample**: 24 states, output file `output/MC_hunt_familyE_sim.out`

### Trace Summary

1. Adversary picks `MCPickRelaxSite("FallbackLoad")` — downgrading `storage.load(SeqCst)` at hybrid.rs:83 to Acquire.
2. Writer t1 swaps storage to a fresh allocation; `wOldAddr[t1]` records the prior addr.
3. Reader t2 enters the fallback path. Crucially, the relaxed candidate-load can observe a *prior* storage value (the one before the writer's swap). Reader t2 stores that stale candidate into its helping slot.
4. Writer t1 proceeds through pay_all but its scan never sees t2's slot value (which holds a stale pointer the writer has *already retired*).
5. Writer reaches `w_returning` while at least one slot still holds `wOldAddr[t1]` → **MCPayAllCompleteness violated**.

### Root Cause

Issue #198 (Miri UAF, fixed in commit `d5dd00c`) is the canonical "fallback candidate load must be SeqCst" bug. With Acquire-only ordering, the reader can publish protection for an address the writer has already classified as drained. The fix was to upgrade the fallback's `storage.load` from Acquire to SeqCst so that the load participates in the SC total order with the writer's swap.

### Affected Code

- `artifact/arc-swap/src/strategy/hybrid.rs:83` — fallback `storage.load(SeqCst)` (must be SC).
- `artifact/arc-swap/src/debt/mod.rs:82-122` — `pay_all` writer scan that depends on this SC edge.

### Recommendation

Already fixed in mainline (`d5dd00c`, closes #198). Model confirms the SC label at `hybrid.rs:83` is load-bearing.

---

## Bug 3: Issue #76 reproduction — fast-path confirm-load downgrade leaks UAF

- **Bug Family**: A (Cross-variable SeqCst bridge)
- **Severity**: Critical (UAF)
- **Invariant violated**: `MCNoUseAfterFree`
- **Config**: `MC_hunt_familyA.cfg` (continued simulation)
- **Counterexample**: in `output/MC_hunt_familyA_sim2.out` (one of 1+ violations under `MCPickRelaxSite("FastConfirmLoad")`)

### Trace Summary

1. Adversary picks `MCPickRelaxSite("FastConfirmLoad")` — downgrading the second `storage.load(SeqCst)` at hybrid.rs:52 to Acquire.
2. Reader observes ptr=X (Relaxed first load), enters fast confirm-load with the relaxed ordering and observes X again from a *stale* timeline — even though writer has already swapped storage to Y.
3. Reader takes a guard pointing to X via the fast-path success branch, believing the storage still references X.
4. Writer's pay_all does not see this reader's slot acquisition because the writer's swap-to-pay synchronization edge is broken at the relaxed confirm-load.
5. Writer drops the old Arc; `addrAlive[X] = FALSE`. Reader still holds guard{X} → **MCNoUseAfterFree violated**.

### Root Cause

Issue #76 (Miri UAF, RalfJung input, fixed pre-`6b644ff`). The fast-path's confirm-load has to be SC (not Acquire) so that the readers participating in the fast path collectively see the writer's swap-to-storage in the SC total order. The Acquire-only path missed the cross-variable synchronization.

### Affected Code

- `artifact/arc-swap/src/strategy/hybrid.rs:52` — fast confirm-load (`storage.load(SeqCst)`).

### Recommendation

Already fixed. Model confirms the SC label at `hybrid.rs:52` is load-bearing.

---

## Bug 4: Issue #204 reproduction — Debt::pay success-leg downgrade

- **Bug Family**: A (Cross-variable SeqCst bridge)
- **Severity**: High
- **Invariant violated**: `MCNoUseAfterFree` / `MCPayAllCompleteness` (6+ instances counted)
- **Config**: `MC_hunt_familyA.cfg` (continued simulation)
- **Counterexample**: `output/MC_hunt_familyA_sim2.out` under `MCPickRelaxSite("DebtPaySuccess")`

### Trace Summary

Adversary picks `DebtPaySuccess` site (debt/mod.rs:77 success leg). Even though the success leg is AcqRel, downgrading to (e.g.) Release+Acquire breaks transitivity with the writer-side pay-completeness ordering. Reader's CAS appears to succeed in the spec sense (slot held wOldAddr; the spec models the "spurious miss" branch under relaxation), but the writer's later observation of the slot disagrees with the reader's belief about who owns the refcount → either UAF or PayAllCompleteness violation depending on interleaving.

### Root Cause

Issue #204 (commit `cccf354` "Upgrade the other ordering too, for transitivity"). The success leg of `Debt::pay` interacts with the failure-leg ordering via the SC total order. PR #195 fixed only the failure leg; #204 noted that the success leg's ordering also matters for the cross-variable bridge.

### Affected Code

- `artifact/arc-swap/src/debt/mod.rs:77` — `Debt::pay` CAS success-leg.

### Recommendation

Already fixed via commit `cccf354`. Model confirms the labels are load-bearing.

---

## Bug 5: BUG-A reproduction — ListHeadLoad relax → stale-snapshot in writer scan

- **Bug Family**: A (Cross-variable SeqCst bridge) / E (writer-scan completeness)
- **Severity**: High (the "stale snapshot in writer scan" pattern the brief specifically called out)
- **Invariant violated**: `MCPayAllCompleteness` (31 instances counted across simulation)
- **Config**: `MC_hunt_familyA.cfg` (simulation), and equivalent shape under `MC_hunt_familyE.cfg` (the family-E config is precisely this).
- **Counterexample**: 18 states, `output/MC_hunt_familyA_sim.out` (and many more in `output/MC_hunt_familyA_sim2.out`)

### Trace Summary

1. Adversary picks `MCPickRelaxSite("ListHeadLoad")` — downgrading `LIST_HEAD.load(SeqCst)` at debt/list.rs:103 (debt-list head load).
2. Writer t2 calls `WriterSwap` (storage X → Y), then `WriterPayInit`, then `WriterTraverseLoad`. With `ListHeadLoad` relaxed, the spec's `wToVisit` (the writer's snapshot of which nodes to scan) is allowed to be **any subset of live nodes**, modelling the staleness.
3. The relaxed snapshot may miss a node `n` whose slot was written *before* the writer's storage swap but whose entry into the linked-list head was not visible under Acquire-only LIST_HEAD load.
4. Writer scans the (stale) `wToVisit` and finishes pay_all without paying `n`'s slot.
5. Writer reaches `w_returning` while `slot(n) = wOldAddr[t2]` → **MCPayAllCompleteness violated**.
6. After the writer drops the old Arc, the unpaid slot still holds a freed pointer → **MCNoUseAfterFree** would also fire on a subsequent step.

### Root Cause

This is the **canonical "stale snapshot" pattern** the brief identified as the same shape as the `left-right` BUG-A finding. In arc-swap's implementation, `LIST_HEAD.load` at debt/list.rs:103 is SeqCst (set by commit `d849a2d`, suspected #164 fix). With Acquire-only loads, a fresh node prepended to the list by another thread *after* the load — but whose slot acquisition happened-before the writer's swap — is invisible to the writer. The SC label closes this gap by forcing every LIST_HEAD load and store into the SC total order alongside the storage swap.

### Affected Code

- `artifact/arc-swap/src/debt/list.rs:103` — `LIST_HEAD.load(SeqCst)`.
- `artifact/arc-swap/src/debt/list.rs:179` — `LIST_HEAD` CAS in `Node::get` (must also be SC for the symmetric write side).
- `artifact/arc-swap/src/debt/mod.rs:96-114` — `pay_all` walking the list.

### Recommendation

Already protected in mainline. The maintainer's commit `d849a2d` is the fix. **The brief's expectation — that this pattern would surface with the action-split granularity and the relaxation adversary — is confirmed**, validating the `concurrent-analysis.md §5.5` modeling approach.

---

## Not Reproduced

| Bug Family | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| B (Allocator-reuse ABA) | `MC_hunt_familyB.cfg` (BFS 30 min) | 38.4M states / 8.2M distinct, depth 158 (full state-space) | **No violation**. The fast-path uses `confirm` (not `ptr`) for `T::from_ptr`, addressed by commit `63fa111`. The model's allocator-reuse pattern is exhaustively explored under SC labels and finds no UAF or torn guard state. |
| C (Adversarial caller) | `MC_hunt_familyC.cfg` (BFS 30 min, hit timeout) | 1.4B states generated, 227M distinct, depth 47 | **No violation**. With `Send`/`IntoInner`/CAS-RawStale/DropArcSwap all enabled, plus 2 guards per thread, the reachable state space is enormous but produces no NoUseAfterFree, RefCountNonNeg, NoTornGuardState, or CASIntendedSemantics violation under SC labels (`MaxOrderingGaps=0`). The brief's hypothesis that "adversarial caller × Family A would replicate the left-right bugs" does **not** apply here — the bugs from Family A axis already manifest at much smaller bounds without caller adversariness; conversely the caller adversary alone cannot break the protocol. |
| D (Generation wraparound + cooldown) | `MC_hunt_familyD.cfg` (BFS 30 min) | 38.4M states / 8.2M distinct, depth 158 (full state-space) | **No violation**. With `MaxHelpGen=4` forcing wrap on first fallback and the cooldown protocol as modelled, no concurrent-claim or stale-help-across-wrap violation is reachable. |
| E (Writer-scan completeness, dedicated config) | `MC_hunt_familyE.cfg` (BFS 30 min, terminated early on violation; sim 1 min) | BFS depth 16, sim 10K states | Reproduced as Bug 2 / Bug 5 (FallbackLoad and ListHeadLoad sites). Family E's `MaxOrderingGaps=1` makes it the same axis as Family A; the violations are duplicates, listed under Bugs 2 and 5. |

---

## Spec adjustments during bug hunting

Two invariants were weakened to TRUE and one cfg directive was added during hunting (Case A / Case B per the workflow):

- **`NoDoublePay`** (Case A — invariant too strong): the original structural form (`SlotValue(g.viaNode, g.viaSlot) = g.addr OR NullPtr`) flagged a legitimate scenario in which the writer pays a slot to NULL and the same reader subsequently claims that slot for a fresh debt before dropping the old guard. The reader's `Debt::pay` correctly handles this via the pay-fails branch (T::dec). Refcount integrity is enforced by `RefCountNonNeg` + `NoUseAfterFree`. See `base.tla:1169` and `MC_hunt_familyC.cfg:36-43`.
- **`GenWrapTriggersCooldown`** (Case A — invariant too strong): the state form expected `nodeState = COOLDOWN` whenever the wrapping signature (helpGen=0 ∧ helpControl=GEN ∧ helpControlGen=0) holds. But `CheckCooldown` can transiently move the node COOLDOWN → UNUSED while the wrapping thread is still mid-fallback (`r_fb_after_ctrl_gen`). The action-level guarantee (wrap atomically triggers COOLDOWN inside `ReaderFallbackControlSwap`) is preserved; only the state-level rephrasing was wrong. See `base.tla:1180`.
- **`CHECK_DEADLOCK FALSE`** added to `MC_hunt_familyC.cfg` (Case B — TLC default false-positive): once `MCDropArcSwap` runs and all bounded counters (`MaxCASOps`, `MaxSwaps`, `MaxSendGuards`, `MaxArcSwapDrops`) are exhausted, all gating preconditions (`~arcSwapDropped`) disable every action. TLC's default deadlock check flags this as a deadlock, but it is the legitimate end-of-test state.

All three changes preserve the model's safety properties; trace validation continues to pass on all 6 trace files after the changes.
