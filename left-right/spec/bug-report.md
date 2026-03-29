# Bug Report — left-right

## Summary

- Bug families tested: 4
- Bugs found: 0 new bugs (3 expected fault-injection violations confirmed)
- Configs run: MC_hunt_ordering.cfg, MC_hunt_absorb.cfg, MC_hunt_deadlock.cfg, MC_hunt_variants.cfg
- Convergence: Round 1 (25.3M states, 5.5M distinct, all 6 invariants pass)
- Trace validation: 2 traces (basic_publish 16 states, concurrent_rw 63 states)

## Fault Injection Results

### Family 1: Memory Ordering (MC_hunt_ordering.cfg)

- **Invariant violated**: MCOrderingNoWriteWhileRead
- **Counterexample**: 6 states (output: MC_hunt_ordering_bfs.out)
- **Result**: EXPECTED VIOLATION — confirms SeqCst fences are necessary

**Trace**: SkipReaderFence(R1) → WriterStartPublish → ReaderBumpEpoch(R1) → ReaderLoadPointer(R1) → WriterWait

R1's SeqCst fence is disabled. After bumping epoch (odd), R1 loads pointer but sees stale value "R" instead of current "L". Writer passes wait (R1's epoch changed since snapshot), proceeds to modify writerCopy="R" — but R1 is still reading "R". **Write-while-read**.

This confirms the correctness linchpin documented in the modeling brief: the SeqCst fence at `read.rs:172` establishes the total order between epoch bump and pointer load. Without it, the CPU may reorder the pointer load before the epoch bump, allowing the reader to see a pre-swap pointer value. The corresponding writer fence at `write.rs:428` ensures the writer's epoch reads happen after the swap.

**Implementation status**: Both fences are correctly in place (`read.rs:172`, `write.rs:428`). The `sync.rs:9` FIXME notes that loom downgrades SeqCst to Acquire, which means loom testing cannot fully verify this ordering property — our model checking fills that gap.

---

### Family 2: Oplog Dual-Apply Determinism (MC_hunt_absorb.cfg)

- **Invariant violated**: MCAbsorbApplyCorrectness
- **Counterexample**: 10 states (output: MC_hunt_absorb_bfs.out)
- **Result**: EXPECTED VIOLATION — confirms deterministic absorb is required

**Trace**: First publish (first→false) → EnableNonDetAbsorb → Second publish with non-det absorb

With non-deterministic absorb active, `WriterApplyAndSwap` computes `copyData[writerCopy] = totalOps + 1` instead of `totalOps`, causing the freshly-swapped pointer copy to have wrong data. This violates `ApplyCorrectness: copyData[pointer] = totalOps`.

This confirms the `Absorb` trait's contract: `absorb_first` and `absorb_second` must produce identical results. Historical bugs include `6a678e7` (HashBag drain order mismatch → UAF) and evmap #1 (non-deterministic PartialEq → segfault).

**Implementation status**: Correctness depends on user-provided `Absorb` implementations. The trait documentation clearly warns about this requirement.

---

### Family 3: Reader Lifecycle / Deadlock (MC_hunt_deadlock.cfg)

- **Deadlock found**: 11 states (output: MC_hunt_deadlock_bfs.out)
- **Result**: EXPECTED DEADLOCK — confirms clone-while-guarded deadlock

**Trace**: ReaderDeregister(R1) → ReaderBumpEpoch(R2) → ReaderLoadPointer(R2) → ReaderStartClone(R2) → WriterStartPublish → WriterWait → ... → WriterStartPublish (second)

At state 11: R2 is CloningBlocked (epoch=1 odd, enters=1, holds guard), writer holds mutex (wPC=PubLocked). Circular wait:
- Writer needs R2's epoch to change (waits for quiescence)
- R2 needs mutex to complete clone (ReaderCloneComplete requires mutexHolder="none")
- R2 can't drop guard (blocked in clone) → epoch stays odd

This reproduces the historical deadlock from commit `02eb63b`. The scenario is still possible in the current code: `ReadHandle::clone()` takes `&self`, so it can be called while a `ReadGuard` (which borrows from `&ReadHandle`) exists. The clone calls `epochs.lock()` which blocks if the writer holds the lock in `publish()`.

**Implementation status**: The deadlock is a known API hazard. `ReadHandleFactory` (`read/factory.rs`) was introduced as the safe alternative — it captures `Arc` clones at creation time, avoiding the need to acquire the mutex while a guard is held. The deadlock requires specific misuse: calling `clone()` while holding a `ReadGuard` concurrently with `publish()`.

---

### Family 4: Publish Path Variants (MC_hunt_variants.cfg)

- **Result**: PASS — 147M states generated, 33M distinct, depth 61, 64s
- **Invariants checked**: TypeOK, EpochParity, PointerCopyDisjoint, NoWriteWhileRead, ApplyCorrectness, VariantSafety

All three publish variants (`publish`, `try_publish`, `take_inner`) provide identical safety guarantees. The `try_publish` path (PR #120, v0.11.6) correctly implements the non-blocking epoch check. The `take_inner` path correctly publishes pending ops before swapping to NULL.

---

## Not Reproduced

| Bug Family | Config | States Explored | Diameter | Result |
|------------|--------|-----------------|----------|--------|
| F1 Ordering | MC_hunt_ordering.cfg | 1,982 | 9 | Expected violation (fence fault injection) |
| F2 Absorb | MC_hunt_absorb.cfg | 3,800 | 15 | Expected violation (non-det absorb injection) |
| F3 Deadlock | MC_hunt_deadlock.cfg | 7,391 | 13 | Expected deadlock (clone+guard+publish) |
| F4 Variants | MC_hunt_variants.cfg | 146,868,905 | 61 | **No violation** |

## Convergence Statistics

| Config | States Generated | Distinct States | Depth | Time | Result |
|--------|-----------------|-----------------|-------|------|--------|
| MC.cfg (convergence) | 25,279,587 | 5,542,842 | 59 | 14s | All 6 invariants pass |
| MC_hunt_ordering.cfg | 1,982 | 773 | 9 | <1s | Violation at depth 6 |
| MC_hunt_absorb.cfg | 3,800 | 1,554 | 15 | <1s | Violation at depth 10 |
| MC_hunt_deadlock.cfg | 7,391 | 2,660 | 13 | 1s | Deadlock at depth 11 |
| MC_hunt_variants.cfg | 146,868,905 | 32,939,410 | 61 | 64s | Pass |

## Trace Validation

| Trace | Events | States | Result |
|-------|--------|--------|--------|
| basic_publish | 12 | 16 | Pass |
| concurrent_rw | 20 | 63 | Pass |
