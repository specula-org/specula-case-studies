# arc-swap Spec Changelog

## Trace Validation Fixes

### Trace.tla — Post-state validation (primed variables)
All validation functions changed from unprimed to primed variables to check
post-state (after the action fires), not pre-state:
- `ValidateReaderPC(t)`: `rPC[t]` → `rPC'[t]`
- `ValidateReaderState(t)`: `rPC[t]`, `rPtr[t]`, `rHasDebt[t]` → primed
- `ValidateWriterState(t)`: `wPC[t]` → `wPC'[t]`
- `ValidateStorage`: `storagePtr` → `storagePtr'`

### Trace.tla — Identity mapping (removed CHOOSE)
Replaced `CHOOSE`-based bijection mapping with identity mapping:
```tla
MapThread(tid) == tid
MapPtr(addr) == IF addr = "null" THEN NullPtr ELSE addr
```
Reason: `CHOOSE f \in [A -> B] : TRUE` picks an arbitrary bijection, potentially
mapping "P1" → P2 (model value), breaking InitPtr alignment.

### Trace.tla — TraceWriterScanSlot (slot from trace)
Constrained `slot` from `logline.slot` instead of existential quantification over
all Slot values. Reduced scan step branching from O(|Thread| × |Slot|) to O(|Thread|).

### Trace.tla — TraceWriterPayDone (relaxed scan completion)
Overrode `WriterPayDone` to not require `wScanned[t] = AllDebtPositions`.
Reason: implementation only scans registered nodes (linked list), not all
Thread × Slot positions.

### Trace.tla — Silent actions
Added: `SilentCheckCooldown`, `SilentClaimNode`, `SilentWriterReserveNode`,
`SilentWriterReleaseNode`. Removed: `SilentWriterScanSlot` (caused state space
explosion with unconstrained WriterScanSlot non-determinism).

### Trace configs — String constants
Changed all trace configs to use string literals (`Thread = {"T1", "T2"}`)
instead of model values (`Thread = {T1, T2}`) for identity mapping with trace
JSON data.

## Model Checking Fixes

### MC.tla — Ordering gap guard (MCWriterScanSlot)
Added guard preventing ordering gap from firing on confirmed debts:
```tla
/\ ~(rPC[target] = "r_holding" /\ rHasDebt[target] /\ rSlot[target] = slot)
```
Reason: CAS (RMW) always reads the latest value in the modification order
(C++ [atomics.order]/10). A confirmed debt cannot be missed by a CAS-based scan.
The ordering gap can only occur for unconfirmed debts where the reader's SeqCst
store and writer's AcqRel CAS have no happens-before chain through storagePtr.

### MC.cfg — NoUseAfterFree commented out
`NoUseAfterFree` is expected to fail with ordering gaps (unconfirmed debts
transiently point to freed pointers). The correct safety invariant for confirmed
readers is `ReaderHoldsAlivePtr`.
