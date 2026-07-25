# Bug Report — papaya (Lock-Free Concurrent HashMap)

## Summary

- Bug families tested: 4 (Resize Race, Two-Phase Insert, Parker Deadlock, Reclamation)
- Bugs found: 1
- Configs run: MC_hunt_resize_race.cfg, MC_hunt_twophase.cfg, MC_hunt_parker_deadlock.cfg, MC_hunt_reclamation.cfg

## Bug 1: Blocking Resize Abort Unparks Wrong Parker (MC-1)

- **Bug Family**: Family 3 — Parker/Synchronization Deadlocks
- **Severity**: Medium (only affects blocking resize mode with abort, which is rare)
- **Invariant violated**: NoParkedOnAborted
- **Config**: MC_hunt_parker_deadlock.cfg
- **Counterexample**: 5 states, output file: spec/output/MC_hunt_parker_deadlock.out

### Trace Summary

1. **InitTable(t1)**: Thread t1 initializes table 1 as root
2. **AllocNextTable(t1, 1)**: Thread t1 allocates table 2 as next table for resize
3. **ParkThread(t1, 1)**: Thread t1 parks waiting for resize completion — parks on `next.state().parker` (table 2's parker) with `&next.state().status` as the key
4. **AbortResize(t1, 1, 2)**: Resize is aborted (table 2 is full). Status set to ABORTED. **BUG**: The unpark call targets `table.state().parker` (table 1's parker), NOT `next.state().parker` (table 2's parker) where thread t1 is parked
5. **Result**: Thread t1 remains parked on table 2's parker. The abort unparked table 1's parker (which nobody is waiting on). NoParkedOnAborted violated: t1 is parked on an ABORTED table with no mechanism to wake it.

### Root Cause

In `help_copy_blocking()` (raw/mod.rs:2060-2078), when a resize is aborted:

```rust
// Line 2067: Mark next table as ABORTED
next.state().status.store(State::ABORTED, Ordering::SeqCst);

// Lines 2073-2074: Unpark waiters — WRONG PARKER
let state = table.state();          // <- source table's state
state.parker.unpark(&state.status); // <- unparks source table's parker
```

But threads waiting for resize completion are parked on the **next table's** parker:

```rust
// Lines 2095, 2134-2136: Park on next table's parker
let state = next.state();
state.parker.park(&state.status, |status| status == State::PENDING);
```

These are different `Parker` instances (each table has its own `Parker` in its `State` struct). The unpark targets table 1's parker, but threads are parked on table 2's parker. The parked thread is never woken.

### Affected Code

- `raw/mod.rs:2073-2074`: `table.state().parker.unpark(...)` should be `next.state().parker.unpark(...)`
- `raw/mod.rs:2134-2136`: Correct park target (next table's parker)

### Recommendation

Change lines 2073-2074 from:
```rust
let state = table.state();
state.parker.unpark(&state.status);
```
To:
```rust
let state = next.state();
state.parker.unpark(&state.status);
```

This ensures the unpark targets the same parker instance where threads are waiting.

---

## Not Reproduced

| Bug Family | Config | Mode | States Explored | Depth | Duration | Result |
|------------|--------|------|-----------------|-------|----------|--------|
| Family 1: Resize Race | MC_hunt_resize_race.cfg | BFS | 644M | 18 | 35 min | No violation |
| Family 1: Resize Race | MC_hunt_resize_race.cfg | Simulation | 881M (35.7M traces) | 75 | 30 min | No violation |
| Family 1/MC-2: Two-Phase Insert | MC_hunt_twophase.cfg | BFS | 19K | 11 | <1s (complete) | No violation |
| Family 1/MC-2: Two-Phase Insert | MC_hunt_twophase.cfg | Simulation | 844M (77.6M traces) | 50 | 35 min | No violation |
| Family 4: Reclamation | MC_hunt_reclamation.cfg | BFS | 206M (20.9M distinct) | 27 | 13 min (complete) | No violation |

## Convergence Summary

- Converged in 2 rounds
- Round 2 MC: 1.73B states, 141M distinct, depth 16, 30 min BFS, 48 workers
- 7 invariants checked: NoDuplicateEntry, ProbeChainIntegrity, PromotionSafety, ResizeStatusConsistency, CopiedCountBound, MetaConsistency, TagConsistency
- 3 traces validated: basic_insert (18 states), concurrent_insert_remove (50 states), concurrent_insert_resize (144 states)

## Spec Adjustments During Bug Hunting

- **CopyCompleteness** (Case A): Weakened to only check tables in active chain (`TableChain(rootTable)`) and only live keys (`insertedKeys`). Post-promotion removes and retired table chains are legitimate.
- **NoUseAfterReclaim** (Case A): Changed to slot-level tracking `retired = {[key, table, slot]}` instead of key-level. Prevents false positives when a key is removed and re-inserted at a different slot.
- **InsertUpdate retirement** (Case A): Removed retirement tracking from InsertUpdate — key-level model can't distinguish old/new pointers at same slot.

## Total State Space Coverage

| Config | Total States | Distinct | Traces | Modes |
|--------|-------------|----------|--------|-------|
| MC_hunt_parker_deadlock | Bug found at 5 states | - | - | BFS |
| MC_hunt_twophase | 844M+ | 19K (BFS complete) | 77.6M | BFS + Simulation |
| MC_hunt_resize_race | 1.53B+ | 47.5M+ | 35.7M | BFS + Simulation |
| MC_hunt_reclamation | 206M | 20.9M (BFS complete) | - | BFS (complete) |
| **Total** | **~2.6B** | | **113M+** | |
