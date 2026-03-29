# Bug Report — flurry (Rust ConcurrentHashMap)

## Summary

- Bug families tested: 4
- Bugs found: 0
- Configs run: MC_hunt_resize.cfg, MC_hunt_reclaim.cfg, MC_hunt_treelock.cfg, MC_hunt_treeify.cfg
- Spec fixes during hunting: 1 (HelpTransfer join guard — Case B)

## Spec Fix During Hunting

### HelpTransfer Join Guard (Case B — Spec Modeling Issue)

- **Bug Family**: Family 1 (Resize/Transfer Coordination)
- **Invariant violated**: NoSkippedBins
- **Config**: MC_hunt_resize.cfg (pre-fix)
- **Counterexample**: 28 states (output/MC_hunt_resize_bfs.out)

**What happened**: The spec's `HelpTransfer` action allowed a thread to join an ongoing resize after the finisher had already been determined. This created a scenario where two threads both believed they were the finishing thread:

1. t1 initiates resize: `sizeCtl = -(rs+2) = -6`
2. t1 claims range, then TransferFinishCheck: `sizeCtl = -5` (0 active → t1 becomes finisher)
3. t2 sees Moved bin, calls HelpTransfer: `sizeCtl = -6` (joins AFTER finisher determined)
4. t2 later TransferFinishCheck: `sizeCtl = -5` (t2 also becomes finisher!)
5. t1 CompleteResize resets `binTransferred` → NoSkippedBins violated (t2 still thinks it's finishing)

**Root cause**: The spec's `HelpTransfer` lacked the guard checks from map.rs:1099-1109, which prevent joining when `sc == rs + 1` (no active threads) or `transferIndex <= 0` (all bins claimed).

**Fix**: Added `sizeCtl /= -(rs+1)` and `transferIndex > 0` guards to `HelpTransfer`. Added `HelpTransferBail` action for the bail-out path when guards fail.

**Classification**: Case B — the implementation correctly prevents this via the `sc == rs + 1` check. This is a spec modeling gap, not a real bug.

---

## Not Reproduced

| Bug Family | Config | States Explored | Distinct | Depth | Result |
|------------|--------|-----------------|----------|-------|--------|
| F1: Resize/Transfer | MC_hunt_resize.cfg | 3,352,519 | 436,203 | 61 | No violation (exhaustive BFS) |
| F2: Memory Reclamation | MC_hunt_reclaim.cfg | 38,986 | 8,125 | 21 | No violation (exhaustive BFS) |
| F3: TreeBin R/W Lock | MC_hunt_treelock.cfg | 13,477 | 988 | 10 | No violation (exhaustive BFS) |
| F4: Treeify Race | MC_hunt_treeify.cfg | 38,030 | 5,805 | 21 | No violation (exhaustive BFS) |

All BFS runs completed with 0 states left on queue (fully exhaustive within the configured bounds).

### Notes on Coverage

- **F1 (Resize)**: 3 threads, 8 keys, MaxPuts=8, MaxResizes=2. Covers 2-resize sequences with cooperative transfer. The off-by-one (`i = next_index` vs Java's `i = nextIndex - 1`) is correctly handled by the finishing sweep — the model confirms this.
- **F2 (Reclamation)**: 2 threads, 4 keys, MaxEpochAdvances=4. The simplified epoch model (retire → free when no active guard holds reference) is clean. Real memory safety bugs (#46, #98, `a9c6890`) involved lifetime/type system issues not expressible in this model.
- **F3 (TreeBin Lock)**: 3 threads, MaxTreeLockOps=8. The R/W lock protocol (WRITER|WAITER|READER bits) passes ReaderWriterMutex and WaiterSafety. State space is small (988 distinct) because tree bins require sufficient puts first.
- **F4 (Treeify Race)**: 2 threads, MaxPuts=8, MaxResizes=1. TreeifyNoPanic and BinTypeConsistency hold across all interleavings of put/treeify/transfer. The fix for #83 (handle Moved/Tree in treeify_bin) is correctly modeled.

### Modeling Limitations

- **F2 (Reclamation)**: The model uses a simplified epoch-based GC. Real soundness bugs (#46, #98) involve lifetime bounds, external guards, and stacked borrows — these are Rust type system issues that cannot be expressed in a state-machine model. The NoUseAfterFree invariant validates the abstract protocol, not the Rust-specific implementation details.
- **F3 (TreeBin Lock)**: The waiter handle lifecycle (park/unpark race in node.rs:352-407) is modeled but the waiter handle's memory safety (whether `unpark()` is called on freed memory) depends on epoch-based reclamation details not fully captured here.
- **F1 (Resize off-by-one)**: The `i = next_index` vs `i = nextIndex - 1` difference (map.rs:710 vs Java) means helper threads trigger the finishing check before processing their claimed range on first claim. The finishing sweep (i=n, bound=0) re-checks all bins, recovering correctness. The model confirms no bins are skipped with this approach.
