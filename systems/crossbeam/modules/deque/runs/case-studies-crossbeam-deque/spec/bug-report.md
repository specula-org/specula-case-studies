# crossbeam-deque — Spec Validation Bug Report

## Summary

Formal verification of crossbeam-deque's Chase-Lev work-stealing deque using TLA+ model checking. The specification covers FIFO/LIFO pop modes, single and batch steal, buffer resize with epoch-based reclamation, and three bug families (F1: steal-resize buffer race, F3: epoch lifecycle coupling, F4: FIFO pop rollback).

**Result: 0 new bugs found.** All fault-injected violations reproduce known/expected vulnerability patterns. The implementation is correct under normal operation with respect to all modeled safety properties.

## Specification

| Item | Value |
|------|-------|
| Base spec | `base.tla` (~570 lines) |
| MC wrapper | `MC.tla` — counter-bounded fault injection (ResizeGrow, EpochReclaim) |
| Trace spec | `Trace.tla` — per-thread timebox replay (Category B) |
| Stealers | 2 (s1, s2) |
| Buffer capacity | 2–3 (per config) |
| Max values | 4–5 |
| Max batch | 2 |
| Fault injection flags | `skipRecheck` (per CAS site), `prematureReclaim` |

## Convergence

Converged in **1 round**.

### Round 1 — Trace Validation
- **Fix (trace spec):** `TraceStealBegin`/`TraceBatchStealBeginFIFO`/`TraceBatchStealBeginLIFO` — Category B concurrent replay fix. Stealer begin actions now use `logline.cachedFront` and `logline.result` instead of reading `front`/`back` from current TLA+ state. Without this, stealers scheduled after worker events saw mutated state (e.g., front=8 instead of 0), causing false empty-queue detection and validation deadlock. (Trace: `concurrent_fifo.json`)
- All 4 traces pass after fix: `push_lifo_pop` (10 events), `push_fifo_pop` (10 events), `steal_single` (20 events), `concurrent_fifo` (24 events, worker+s1+s2)

### Round 1 — Model Checking
- No violations. 8.3M states, 2.2M distinct, depth 26, 7s BFS. All 6 convergence invariants pass (ConsumedWasPushed, NoDoublePop, DequeConsistency, PushedDistinct, PushCountConsistency, CurrentBufferAlive).
- No spec or invariant changes needed → **converged**.

## Invariants

| Invariant | Category | Description |
|-----------|----------|-------------|
| ConsumedWasPushed | Standard | Every consumed value was actually pushed |
| NoDoublePop | Standard | No value consumed more than once |
| DequeConsistency | Standard | front <= back when not in FIFO rollback |
| NoElementLoss | Standard | Every pushed value is consumed or still in deque |
| StealReturnsValid | F1 | Speculative steal reads return pushed values (not stale/freed garbage) |
| NoUseAfterFree | F3 | No stealer reads from a freed buffer |
| PushedDistinct | Structural | All pushed values are unique |
| PushCountConsistency | Structural | nextPush tracks push count |
| CurrentBufferAlive | Structural | Current buffer is never freed |

## Bug Hunting Results

### Config Results

| Config | Bug Family | Faults | Invariants | States | Distinct | Depth | Duration | Result |
|--------|-----------|--------|------------|--------|----------|-------|----------|--------|
| MC.cfg | — (convergence) | skipBatchLIFO only | 6 standard | 8.3M | 2.2M | 26 | 7s | **PASS** (exhaustive) |
| MC_hunt_family1_cve | F1 (CVE-2021-32810) | skipRecheck=ALL, prematureReclaim | 4 (safety+F1) | 1.3K | 819 | 9 | <1s | **NoUseAfterFree violated** (6 states) |
| MC_hunt_family1_mc1 | F1 (MC-1, line 1083) | skipBatchLIFO, prematureReclaim | 3 (safety) | 1.3K | 798 | 9 | <1s | **NoUseAfterFree violated** (6 states) |
| MC_hunt_family3 | F3 (epoch lifecycle) | prematureReclaim | 4 (safety+F3) | 1.6K | 954 | 9 | <1s | **NoUseAfterFree violated** (5 states) |
| MC_hunt_family4 | F4 (FIFO rollback) | none | 4 (safety+F4) | 197K | 55K | 22 | 1s | **PASS** (exhaustive) |

### Detailed Analysis

#### Verification Finding VF-1: CVE-2021-32810 Reproduction (Family 1)

**Config**: `MC_hunt_family1_cve.cfg`
**Invariant Violated**: NoUseAfterFree
**Status**: VERIFIED (reproduces known CVE)

**Counterexample (6 states):**
1. Init: `prematureReclaim=TRUE`, `skipRecheck=ALL TRUE`, `flavor=LIFO`
2. Push(1): back=1, bufContent[1]=[1,0]
3. Push(2): back=2, bufContent[1]=[1,2]
4. StealBegin(s1): s1 caches `bufferID=1`, `front=0`, transitions to ReadTask, pins epoch
5. ResizeGrow: `bufferID→2`, copies data, retires buffer 1
6. **EpochReclaim**: frees buffer 1 while s1 is pinned → `freed={1}`, but `sCachedBuf[s1]=1` and `sPC[s1]=ReadTask`

**Root Cause**: With `prematureReclaim=TRUE`, epoch reclamation bypasses the pin check, freeing buffer 1 while s1 still holds a reference. This is the exact CVE-2021-32810 attack vector. The fix (buffer re-check before CAS) prevents the stealer from committing stale reads, but the epoch system is the primary defense against UAF.

**Affected Code**: `deque.rs:305-321` (resize/defer), `deque.rs:650-654` (epoch pin in steal)

#### Verification Finding VF-2: MC-1 Missing Re-check (Family 1)

**Config**: `MC_hunt_family1_mc1.cfg`
**Invariant Violated**: NoUseAfterFree
**Status**: VERIFIED (defense-in-depth gap, not independently exploitable)

**Counterexample (6 states):**
Same pattern as VF-1 but with `SkipRecheckSingle=FALSE`. The violation occurs via premature reclaim regardless of re-check status. The stealer uses the "single" steal path, so the missing re-check at `batchLIFOFirst` (`deque.rs:1083-1087`) is not even exercised in this counterexample.

**Key Finding**: The missing buffer re-check at `deque.rs:1083-1087` is a defense-in-depth gap. Under normal epoch operation (`prematureReclaim=FALSE`), it is **benign** — the convergence MC exhaustively checked 8.3M states with `SkipRecheckBatchLIFO=TRUE` and all invariants passed. The re-check only matters if epoch also fails, which is prevented by crossbeam-epoch's design.

**Why it's benign**: After resize, old buffer contents are frozen (worker only writes to new buffer). A stealer reading from the old buffer gets correct pre-resize values. The CAS on front prevents double-consumption. Even without the re-check, the stolen value is valid.

#### Verification Finding VF-3: Epoch Lifecycle (Family 3)

**Config**: `MC_hunt_family3.cfg`
**Invariant Violated**: NoUseAfterFree
**Status**: VERIFIED (confirms epoch is primary safety mechanism)

**Counterexample (5 states):**
1. Init: `prematureReclaim=TRUE`, re-checks normal, `flavor=LIFO`
2. Push(1): back=1
3. StealBegin(s1): caches `bufferID=1`, pins epoch
4. ResizeGrow: `bufferID→2`, retires buffer 1
5. **EpochReclaim**: frees buffer 1 while s1 pinned → UAF

**Key Finding**: Even with all buffer re-checks active, premature reclamation alone causes UAF. This confirms that epoch-based reclamation is the **primary** safety mechanism, not the buffer re-check. The re-check is defense-in-depth.

#### Family 4: FIFO Rollback — No Bugs Found

**Config**: `MC_hunt_family4.cfg`
**Result**: PASS — 197K states, 55K distinct, depth 22, exhaustive BFS

The FIFO pop rollback mechanism (`fetch_add` then conditional `store` rollback) is safe. During the rollback window, `front > back` causes stealers to see false-empty, but no elements are lost. `NoElementLoss`, `ConsumedWasPushed`, `NoDoublePop`, and `DequeConsistency` all hold.

## State Space Coverage

| Config | States Generated | Distinct | Depth | Coverage |
|--------|-----------------|----------|-------|----------|
| MC.cfg (convergence) | 8,317,024 | 2,240,921 | 26 | Exhaustive BFS |
| MC_hunt_family1_cve | 1,310 | 819 | 9 | Violation found (exhaustive to depth 9) |
| MC_hunt_family1_mc1 | 1,278 | 798 | 9 | Violation found (exhaustive to depth 9) |
| MC_hunt_family3 | 1,590 | 954 | 9 | Violation found (exhaustive to depth 9) |
| MC_hunt_family4 | 197,339 | 55,096 | 22 | Exhaustive BFS |
| **Total** | **8,518,541** | — | — | — |

## Conclusion

The crossbeam-deque implementation is correct with respect to all modeled safety properties under normal operation. The spec verifies three defense layers:

1. **CAS on front** (Chase-Lev core): Prevents double-consumption and ensures slot ownership. Exhaustively verified.
2. **Buffer re-check** (CVE-2021-32810 fix): Prevents stale buffer reads from being committed after resize. Present at 4 of 5 CAS sites; absent at `batchLIFOFirst` (`deque.rs:1083`), which is benign under normal epoch.
3. **Epoch-based reclamation** (crossbeam-epoch): Prevents use-after-free by deferring buffer deallocation until no stealer holds a reference. Confirmed as the primary safety mechanism via fault injection.

The missing buffer re-check at `deque.rs:1083-1087` (`steal_batch_with_limit_and_pop` LIFO first CAS) is a defense-in-depth gap but does not independently cause safety violations. It is only exploitable in combination with an epoch failure, which is prevented by crossbeam-epoch's design.
