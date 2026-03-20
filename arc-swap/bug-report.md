# arc-swap Bug Report

## System Under Test

**arc-swap** — A Rust library for atomically swapping `Arc` pointers with lock-free reads using a debt-based hazard pointer mechanism.

- Repository: [github.com/vorner/arc-swap](https://github.com/vorner/arc-swap)
- Language: Rust
- Protocol: Debt-based hazard pointer with SeqCst/AcqRel ordering

## Spec Overview

The TLA+ spec models the debt-based reader tracking protocol:

- **Core mechanism**: Readers write pointers to per-thread "debt slots" instead of incrementing refcounts. Writers scan all slots before freeing the old pointer, paying debts by incrementing refcounts.
- **Two-tier slot system**: 8 fast slots (SeqCst swap) + 1 helping slot (lock-free fallback with Acquire ordering)
- **Three bug families modeled**:
  1. Cross-Variable SeqCst Ordering Gaps (CRITICAL) — open bugs #198, #200
  2. ABA / Pointer Reuse Races (HIGH) — historical fixes
  3. Generation Counter Wraparound (MEDIUM) — historical fix 343d1f5

### Spec Files

| File | Description |
|------|-------------|
| `spec/base.tla` | Core spec: 14 actions, 12 invariants, 3 bug families |
| `spec/MC.tla` | Counter-bounded MC wrapper with fault injection |
| `spec/MC.cfg` | Convergence config (all faults disabled, all invariants pass) |
| `spec/MC_hunt_*.cfg` | 6 hunting configs for targeted bug search |
| `spec/Trace.tla` | Trace validation spec |
| `spec/Trace.cfg` | Trace validation config |

### Convergence

| Config | States | Distinct | Depth | Time | Invariants | Result |
|--------|--------|----------|-------|------|------------|--------|
| MC.cfg (no faults) | 1,356,637 | 160,809 | 35 | 2s | All 12 | PASS |

## Findings

### Bug Family 1: Cross-Variable SeqCst Ordering Gap (CRITICAL)

**Root cause**: Writer's debt scan uses `AcqRel` CAS (`debt/mod.rs:77`) which does not participate in the SeqCst total order. This creates a gap where the writer can miss a reader's SeqCst debt store.

#### Finding AS-1: WriterPaysAllDebts Violation (confirms #200)

| Property | Value |
|----------|-------|
| Invariant | `WriterPaysAllDebts` |
| Config | `MC_hunt_ordering.cfg` |
| Counterexample | 9 states |
| Discovery | MC-BFS, instant |

**Counterexample**:
1. T1: `ReaderAcquireFast` — loads P1 into debt slot `[T1][1]` (SeqCst swap)
2. T2: `WriterSwap` — swaps storage P1→P3, saves `wOldPtr=P1`
3. T2: `WriterPayInit` — pre-pays `refCount[P1]` = 1→2
4. T2: `WriterScanSlot([T1][1])` — **ORDERING GAP**: AcqRel CAS misses P1 debt
5–8. T2: Scans remaining 3 slots — no P1 debts found
9. T2: `WriterPayDone` — drops pre-pay: `refCount[P1]` = 2→1

**At state 9**: `wPC[T2]="w_returning"` but `debtSlot[T1][1]=P1` — writer thinks all debts paid, but one remains.

#### Finding AS-2: NoUseAfterFree Violation (confirms #200)

| Property | Value |
|----------|-------|
| Invariant | `NoUseAfterFree` |
| Config | `MC_hunt_uaf.cfg` |
| Counterexample | 10 states |
| Discovery | MC-BFS, instant |

Same setup as AS-1, but continues:
10. T2: `WriterReturn` — drops old ptr: `refCount[P1]` = 0→freed

**At state 10**: `debtSlot[T1][1]=P1` but `ptrAlive[P1]=FALSE` — **use-after-free**.

#### Finding AS-3: ReaderHoldsAlivePtr Violation (confirms #200)

| Property | Value |
|----------|-------|
| Invariant | `ReaderHoldsAlivePtr` |
| Config | `MC_hunt_fallback_gap.cfg` |
| Counterexample | 11 states |
| Discovery | MC-BFS, instant |

The most severe manifestation: reader has **confirmed** its fast-path load and is in `r_holding` state with `rPtr=P1`, while P1 is freed.

1. T1: `ReaderAcquireFast` — loads P1 into slot [T1][1]
2. T1: `ReaderConfirmFast` — confirms (storage still P1), enters `r_holding`
3. T2: `WriterSwap` — swaps P1→P2
4–9. T2: Scans all slots, misses T1's debt via ordering gap
10. T2: `WriterPayDone` + `WriterReturn` — frees P1

**At state 11**: `rPC[T1]="r_holding"`, `rPtr[T1]=P1`, `ptrAlive[P1]=FALSE` — reader actively dereferencing freed memory.

#### Key insight: Stale read alone is insufficient

With `MaxOrderingGaps=0, MaxStaleReads=1`: **No bugs found** (276K states, all pass). The fallback's Acquire load of a stale pointer is correctly handled when the writer scan works properly — the writer finds and pays the stale debt. The UAF requires the ordering gap in the scanner (#200).

### Bug Family 2: ABA / Pointer Reuse (NO BUGS FOUND)

| Property | Value |
|----------|-------|
| Invariant | `NoABAViolation` |
| Config | `MC_hunt_aba.cfg` |
| States | 1,356,637 |
| Result | **PASS** |

The ABA mitigations (pointer generation tracking, comparison semantics) correctly prevent ABA races when ordering is correct. Historical fixes (e4fbadf, 00225f5, 63fa111, 7fcaa11) remain effective.

### Bug Family 3: Generation Counter Wraparound (NO BUGS FOUND)

| Property | Value |
|----------|-------|
| Invariant | `CooldownBlocksReaders` |
| Config | `MC_hunt_genwrap.cfg` |
| States | 19,369 |
| Result | **PASS** |

The cooldown state machine (NODE_USED → NODE_COOLDOWN → NODE_UNUSED → NODE_USED) correctly prevents generation wraparound from causing issues. The `activeWriters` counter ensures no writer is scanning a node during its cooldown-to-unused transition. Historical fix (343d1f5) remains effective.

## Summary

| Family | Mechanism | Invariant | Result | Severity |
|--------|-----------|-----------|--------|----------|
| 1 | AcqRel ordering gap in scan | `WriterPaysAllDebts` | **VIOLATED** (9 states) | Critical |
| 1 | AcqRel ordering gap in scan | `NoUseAfterFree` | **VIOLATED** (10 states) | Critical |
| 1 | AcqRel ordering gap + confirm | `ReaderHoldsAlivePtr` | **VIOLATED** (11 states) | Critical |
| 1 | Stale read only (no scan gap) | `ReaderHoldsAlivePtr` | PASS (276K states) | — |
| 2 | ABA / pointer reuse | `NoABAViolation` | PASS (1.36M states) | — |
| 3 | Generation wraparound | `CooldownBlocksReaders` | PASS (19K states) | — |

**Confirmed**: Open bugs [#198](https://github.com/vorner/arc-swap/issues/198) and [#200](https://github.com/vorner/arc-swap/issues/200) — the AcqRel ordering gap in `Debt::pay` (`debt/mod.rs:77`) is the root cause of use-after-free.
