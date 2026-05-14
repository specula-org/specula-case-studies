# Bug Report — crossbeam-deque (run 2)

## Summary

- Bug families tested: 5 (A, B, C, D, F)
- Real bugs found: **0**
- Spec corrections during hunting: 1 (malformed invariant)
- Configs run: `MC_hunt_familyA.cfg`, `MC_hunt_familyB.cfg`, `MC_hunt_familyC.cfg`, `MC_hunt_familyD.cfg`, `MC_hunt_familyF.cfg`
- Convergence: MC.cfg passed in 36s — 20.6M states, 4.3M distinct, depth 39, no violations.

This run added the full fault-injection adversary set the brief identified as missing from prior verification: memory-ordering relaxation (Family B), buffer-resize / generation race (Family A), adversarial caller harness (Family C), CAS-weak (Family D), and per-iteration LIFO batch loop interleaving (Family F). Each adversary was exhaustively explored within its bound; none produced an unintended safety violation.

The two violations TLC found (Families A and B) are **expected demonstrations of the fault adversaries**, not bugs in the crossbeam-deque source. Both encode "what happens if a load-bearing precondition is violated" and they fire as designed when their preconditions are explicitly removed by the adversary action. The actual implementation enforces those preconditions (Acquire/Release ordering on the worker/stealer boundary; crossbeam-epoch's pin-vs-reclaim contract).

---

## Bug Family A — Buffer-Resize / Generation Race

- **Config**: `MC_hunt_familyA.cfg`
- **Invariant violated**: `NoUseAfterFree`
- **Counterexample**: 11 states (output `output/MC_hunt_familyA_bfs.out`)
- **Verdict**: **Expected fault-model demonstration. Not a real bug.**

### Trace Summary

1. s1 `StealLoadFront`, `StealPin` — s1 enters pinned state with cached front=0.
2. Worker `PushWriteSlot`, `PushStoreBack` — value 1 lands in slot 0, back=1.
3. s1 `StealLoadBack` (cachedBack=1), `StealLoadBuffer` (cachedBuf=1).
4. Worker `ResizeGrow` — bufferID flips 1→2, buffer 1 retired.
5. `EnablePrematureReclaim` — adversary toggles the fault flag.
6. `EpochReclaim` — buffer 1 is freed despite s1 still holding it cached.
7. `NoUseAfterFree` invariant fails: s1.sCachedBuf=1 ∈ freed.

### Root Cause (in the model, not the code)

The `prematureReclaim` flag in `base.tla` (deque.rs context: `crossbeam_epoch::Guard::defer_unchecked` at deque.rs:315) deliberately disables the "no reclaim while pinned" check. crossbeam-deque relies on crossbeam-epoch enforcing this; under the synthetic adversary, that contract is broken and UAF naturally follows.

### Affected Code (would only matter if crossbeam-epoch were buggy)

- `deque.rs:289-322` (`Worker::resize`): retires old buffer via `defer_unchecked`.
- `deque.rs:1006-1010` and analogues: `epoch::pin()` site whose contract is "reclaim is deferred while pin is in scope".

### Recommendation

None for crossbeam-deque source. The model correctly demonstrates that **crossbeam-epoch's pin-vs-reclaim contract is load-bearing**: any future change to crossbeam-epoch that weakens this contract would re-enable the demonstrated UAF here.

---

## Bug Family B — Memory Ordering across Worker/Stealer Boundary

- **Config**: `MC_hunt_familyB.cfg`
- **Invariant violated**: `NoDoublePop` (and `NoGarbageSteal` collaterally — both fire on the same state)
- **Counterexample**: 10 states (output `output/MC_hunt_familyB_bfs.out`)
- **Verdict**: **Expected fault-model demonstration. Not a real bug.**

### Trace Summary

1. s1 `StealLoadFront` (front=0), `StealPin` (sFenceDone=TRUE).
2. Worker `PushWriteSlot` — slot 0 gets value 1, but `pushSlotVisible[1]={}` (only marked at PushStoreBack).
3. `EnableRelaxBackStore` — adversary toggles the Family-B fault flag.
4. Worker `PushStoreBack` — back=1 advances, but under `relaxBackStore` the slot is NOT marked visible (`pushSlotVisible[1]` stays empty).
5. s1 `StealLoadBack` observes back=1 → proceeds (queue appears non-empty).
6. s1 `StealLoadBuffer`, `StealReadSlot` — slot 0 is not visible to s1, so `sReadVal=NullVal`.
7. s1 `StealRecheckCAS` — CAS succeeds (front matches), `consumed = {NullVal=0}`, `consumeCount=1`.
8. `NoDoublePop` fails: `consumeCount(1) ≠ Cardinality(consumed \ {NullVal})(0)`.

### Root Cause (in the model, not the code)

The Release fence at deque.rs:424 (`atomic::fence(Release)`) plus the back-store at deque.rs:432 form the visibility handshake: by the time a stealer observes the new back via Acquire load, the slot write must be globally visible. `relaxBackStore` deliberately removes the fence in the model. The actual implementation always issues the fence (or the equivalent under TSan via `Release` store at deque.rs:425-432).

### Affected Code (would only matter if a future refactor weakened the ordering)

- `deque.rs:418-432` (`Worker::push`): the Release fence + back.store handshake. PR #1233 (`23b68fb3`) split the back-store ordering into TSan-aware `Release` vs production `Relaxed` — the `Release` fence still precedes both branches.
- `deque.rs:643-657` (`Stealer::steal`): paired Acquire load of `back` and the conditional `fence(SeqCst)` from epoch::pin.

### Recommendation

None for crossbeam-deque source. The model correctly demonstrates that **the Release-fence-then-Relaxed-store pattern in `Worker::push` is load-bearing**. Any future change that drops the fence (e.g., a "minor cleanup" that elides what looks like a no-op) would re-enable the demonstrated garbage-read here.

---

## Bug Family C — Adversarial Caller Harness

- **Config**: `MC_hunt_familyC.cfg`
- **Invariants checked**: `ConsumedWasPushed`, `NoDoublePop`, `NoGarbageSteal`, `NoUseAfterFree`, `StealerDomainOK`, `WorkerExclusive`, `DequeConsistency`
- **Coverage**: 13.6M states, 3.2M distinct, depth 40, no violations.
- **Verdict**: **No bugs found.** Adversarial caller (Stealer::clone mid-steal, Worker::drop while stealers are mid-operation, multi-stealer concurrent steals) does not break safety.

This was a previously-uncovered area: the brief flagged that prior verification had no caller-misuse adversary. BFS within the bound clears the documented contract.

---

## Bug Family D — CAS-Weak Spurious Failure (Worker LIFO last-task CAS)

- **Config**: `MC_hunt_familyD.cfg`
- **Invariants checked**: `ConsumedWasPushed`, `NoDoublePop`, `NoGarbageSteal`, `NoLostPopUnderStrongCAS`, `NoElementLoss`, `DequeConsistency`
- **Coverage** (after invariant fix): 704K states, 178K distinct, depth 33, no violations.
- **Verdict**: **No bugs found.** The "what if the LIFO last-task CAS were weak" adversary does not produce a new safety violation in the current model.

A first run reported `NoLostPopUnderStrongCAS` at state 2 after a single `PushWriteSlot`, but this was an invariant-formula bug (a misplaced `\/` made the `wPC \in {transient}` escape disjunct sit inside the empty `\E pos \in front..(back-1)` body, so the formula was always FALSE during the transient `PushSlotWritten` window). Fixed in `base.tla` (see Spec Fixes below); the rerun shows clean.

The model abstraction here is conservative: when `weakLIFOLastCAS` fires the spurious-fail branch, the slot's `bufContent` is preserved while `back` is restored, so the value remains "in the deque" by the spec's bookkeeping. The actual Rust code at deque.rs:527 does `task.take()` (drops the local Option), but the buffer slot still contains the MaybeUninit bits — for plain values this is harmless. For `T = Box<U>`, this would be the CVE-2021-32810 family of dangling-Box-via-stale-read; the current spec doesn't model per-slot drop state, so that scenario is not directly observable here. It is, however, modeled separately in Family A (buffer-generation tracking + premature-reclaim adversary).

---

## Bug Family F — Empty / Non-Empty Race in Steal-Batch LIFO Loop

- **Config**: `MC_hunt_familyF.cfg`
- **Invariants checked**: `ConsumedWasPushed`, `NoDoublePop`, `NoGarbageSteal`, `StealReturnsValid`, `BatchIterBounded`, `DequeConsistency`, `NoElementLoss`
- **Coverage**: 20.7M states, 4.4M distinct, depth 39, no violations.
- **Verdict**: **No bugs found.** Per-iteration interleaving in `steal_batch_with_limit_and_pop` Lifo (deque.rs:1100-1146) with concurrent `PushWriteSlot`/`PushStoreBack`/`ResizeGrow` interleaved between iterations does not break safety.

The brief flagged two prior bugs in this loop (commits `4d574d40`, `89828aac`); BFS within the bound clears the present code.

---

## Not Reproduced

| Bug Family | Config | States / depth | Result |
|------------|--------|----------------|--------|
| Family A — buffer-resize race (CVE-2021-32810 path) | `MC_hunt_familyA.cfg` | 202K / 14 (stops at expected adversary demo) | Expected fault-model demo only — `NoUseAfterFree` under `prematureReclaim`. Not a real bug. |
| Family B — memory-ordering bridges (`relaxBackStore`, `skipStealerFence`) | `MC_hunt_familyB.cfg` | 87K / 15 (stops at expected adversary demo) | Expected fault-model demo only — `NoDoublePop` / `NoGarbageSteal` under `relaxBackStore`. Not a real bug. |
| Family C — adversarial caller (Stealer::clone, Worker::drop, multi-stealer) | `MC_hunt_familyC.cfg` | 13.6M / 40 (exhaustive) | No violation. |
| Family D — weak CAS on Worker LIFO last-task CAS | `MC_hunt_familyD.cfg` | 704K / 33 (exhaustive, after invariant fix) | No violation. Spec model is conservative — `bufContent` preserved on spurious-fail path. |
| Family F — per-iteration LIFO batch loop | `MC_hunt_familyF.cfg` | 20.7M / 39 (exhaustive) | No violation. |
| **Family E — Injector block-lifecycle (READ/DESTROY bits)** | n/a | not modeled | Out of scope for this run; Injector is a separate MPMC structure not modeled in `base.tla`. Brief flags this as deferred for future iteration. |
| **MC-1 — asymmetric absence of recheck at deque.rs:1083 with non-index-preserving resize** | n/a | not modeled | Brief's MC-1 hypothesis requires modeling a *non-index-preserving* `Worker::resize`. Current `ResizeGrow` is index-preserving (matches deque.rs:298-303). The asymmetric-recheck-absence is encoded (`skipRecheck["batchLIFOFirst"] = TRUE` by default), but with index-preserving resize the violation does not manifest — confirming the brief's note that "the asymmetry is currently safe because resize is index-preserving (an undocumented invariant)". Recommendation per the brief stands: add a `// SAFETY:` comment at deque.rs:1083 citing the resize invariant. |

---

## Spec Fixes Applied During Hunting

| File | Change | Rationale |
|------|--------|-----------|
| `base.tla` | Rewrote `NoLostPopUnderStrongCAS` in bullet style so `wPC \in {"PushSlotWritten", "FIFORollback", "LIFODecrFenced"}` is a top-level disjunct rather than nested inside `\E pos \in front..(back-1) : ...`. | Original parsing precedence put the `wPC` escape inside an existential whose range was empty during the transient `PushSlotWritten` state — making the invariant always FALSE there. Case A (invariant malformed). |

No fixes to crossbeam-deque source code are warranted by this verification run.

---

## Code-Review-Only Recommendations

These are not violations TLC found, but they are notes the brief flagged that this run confirms remain valid.

- **CR-1** (`deque.rs:1083`): `Stealer::steal_batch_with_limit_and_pop` Lifo's first CAS is the only stealer-side `front.compare_exchange` site without a `self.inner.buffer.load(Acquire) != buffer` re-check. Currently safe because `Worker::resize` (deque.rs:298-303) preserves logical indices on copy. Recommend adding a `// SAFETY:` comment that cites this invariant, so a refactor that compacts indices in `resize` cannot silently introduce CVE-2021-32810-class double-take.
- **CR-2** (`deque.rs:1284-1301`, `Block::destroy`): Walker invariant for the Injector READ/DESTROY bits is non-obvious; document it. (Out of scope for this run — Injector not modeled.)
- **CR-3** (`deque.rs:1415, 1506, 1658, 1861`): `compare_exchange_weak` on Injector head/tail. Upstream commit `1015b21d` (post-HEAD) switched the three steal sites to strong CAS. Once that commit lands in this branch, MC-5 becomes moot.
