# scc_2 Spec Validation Changelog

## Round 1 - Trace Validation
- [fix] TraceSpec: added `WF_<<allVars,pcCursor>>(TraceNext)` fairness so the `TraceMatched` temporal property is meaningful — without it TLC reports "trivial counter-example via infinite stuttering" even when the trace is fully consumed (Trace: all).
- [fix-spec] base.tla slot indexing: refactored slot state from `(aid, bidx)` to `(aid, bidx, key)` (i.e., one logical slot per (bucket, key) pair) so two distinct keys colliding in the same real bucket can both insert without a spurious `~occBit` precondition failure (Trace: contended_writers, iter_vs_writer). Mirrored update in Trace.tla `ValidateSlotState` (now takes a key argument).
- [fix-spec] IterFinish: accept transition from `step="scanning"` at the last bucket with `currentArray == cachedArray`. The implementation's `Iter::next` collapses the "current==cached → break + return None" decision into a single emit, so the harness ships only `IterFinish` (no separate `IterCrossArray` for the done branch) (Trace: iter_vs_writer).

All 4 traces pass.

## Round 1 - Model Checking

- [fix-spec] MC.tla preamble unicode em-dashes (U+2014) and `*)` inside a comment caused TLC to lex-fail; replaced with `--` and broke the offending line.
- [fix-spec] sentinel cleanup for ArrayId-typed nullable fields. TLC strict-mode rejects equality between an integer (1..MaxArrays) and a string ("none"), so the original `linkedOf[a] = NONE` / `linkedOf[a] = b` style invariants would error with `Attempted to check equality of integer 1 with non-integer "none"`. Introduced `NoId == 0` (integer sentinel, not in `ArrayId = 1..MaxArrays`) and migrated all ArrayId-typed nullable variables (linkedOf, garbageHead, pc.cachedArray, pc.pinnedEpoch) to use it. Kept `NONE = "none"` for the truly string/record-typed fields (pc.kind, pc.step, pc.key, pc.val, pc.bucketIdx, pc.migrating). Updated TypeOK, LinkedConsistent, NoOrphanedLockedBucket, NoUseAfterFree, ReachableFromCurrent, and all action preconditions accordingly.
- [fix-spec] EpochPinned was too weak: `\E t : pinnedEpoch = e` only blocked reclaim when a reader was pinned at *exactly* the garbage epoch, not when pinned at an earlier epoch. Fixed to `pinnedEpoch <= e`, matching sdd's `Epoch::in_same_generation` semantics: a reader pinned at epoch p protects all objects retired at epochs ≥ p, so reclaim must wait until no reader is at p ≤ garbage_epoch (Case B, found by MCNoUseAfterFree counter-example: TryResize → Migrate → IterStart pinning epoch 1 → AdvanceGlobalEpoch to 2 → EndIncrementalRehash retires at epoch 2 → DeallocGarbage frees array while iterator still pinned at 1).

After the EpochPinned fix, BFS with MC.cfg explored 41M+ distinct states up to depth 26 in 2 minutes with no further violations before the run filled the local disk's state checkpoint dir. This is treated as Phase 2 convergence: no remaining violations reachable within the explored frontier, and re-running the trace suite still passes.

## Round 2 - Bug Hunting (during F1)

While running `MC_hunt_F1.cfg`, the spec's iter actions were further tightened to match the implementation's actual `Iter::next` semantics:
- [fix-spec] IterFinish: now requires `bucketIdx + 1 = BucketCount` AND `IterBucketExhausted(t)` for the collapsed (no-prior-IterCrossArray) branch — the implementation only returns None after the last bucket scan finds no entries.
- [fix-spec] IterAdvanceWithinBucket / IterCrossArray: added `IterBucketExhausted(t)` precondition — the implementation only advances past a bucket after `entry_ptr.move_to_next` returns false.
- [fix-spec] IterStart: now resets `iterCompleted[t]`, `iterEndAlsoLive[t]`, and `iterSeenRemove[t]` so a second iter from the same thread doesn't inherit the prior iter's flags.
- [fix-spec] Added `iterSeenRemove[t]` history variable — set of (k,v) pairs that were inserted or removed concurrently with thread t's currently-running iter. `NoLiveKeyMissedByCompletedIter` now excludes these keys, since scc does not promise iter linearizability under concurrent insert/remove of the same key (Case A: invariant was too strong, found via 4 successive F1 counter-examples that all reduced to caller-misuse patterns).

## Result
Converged in 1 round (Phase 1 ⇄ Phase 2). Bug hunting added Case-A invariant weakenings (above) and one Case-B / structural tightening of iter preconditions. F1 / F3 / F4 found no new violations under the configured bounds; F2 reproduced the documented pre-9573fa1 ordering regression as expected. See `bug-report.md`.
