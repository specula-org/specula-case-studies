# Spec Validation Changelog — papaya_2

## Round 1 - Trace Validation

- [fix-spec] ValidateInsertStoreMeta: dropped `tableMeta'[t][s] = logline.meta` check. Harness emits placeholder string `"H2"` while the spec models h2(k)=k; equality never holds. Verifying `metaWritten' = TRUE` and `insertWindow' = NULL` is sufficient. (Trace: meta_overwrite_race.ndjson)
- [fix-spec] Trace.cfg `Slot`: expanded from {0,1,2,3} to {0,1,2,3,4,5,6,7} to match the harness's 8-slot table capacity. (All traces.)
- [fix-spec] CopyMarkCopyingNull (Trace.tla MatchEvent): added trace-only no-op variant for the case where `tableMeta = META_TOMBSTONE` already. The implementation emits `mark_copying_empty` for both null-entry and tombstone-entry slots (mod.rs:2444-2466), but the base spec's CopyMarkCopyingNull guards `meta /= TOMBSTONE` to remain one-shot for MC. The variant still bumps claim/copied counts. (Trace: meta_overwrite_race.ndjson)
- [fix-spec] InsertStoreMeta (base.tla): dropped `metaWritten[t][s] = FALSE` guard. After a Remove during the yield window, metaWritten=TRUE; the implementation's Phase 2 Release store at mod.rs:1051 still fires (this is the Family-7 bug). Without dropping the guard, the bug window is unreachable in the spec. The `insertWindow[t][s] = tid` guard is sufficient one-shot serialization. (Trace: blocking_resize_parkers.ndjson)
- [fix-inv] InsertWindowConsistency (base.tla): weakened to `(insertWindow /= NULL ∧ tableEntry /= NULL) ⇒ metaWritten = FALSE`. The original form fires false positives in the legitimate Family-7 bug window where Remove sets metaWritten=TRUE while the winner's insertWindow is still pending. (Trace: blocking_resize_parkers.ndjson)
- [fix-spec] CopyInsertToNext (base.tla): now increments copiedCount. In blocking mode, the impl's per-chunk local `copied` accumulator is folded into `state.copied` at try_promote (mod.rs:2831); the spec previously never bumped copiedCount for non-null copies, causing TryPromote to deadlock. CopyMarkCopied (incremental-only) was changed to NOT increment copiedCount to avoid double-counting. (Trace: blocking_resize_parkers.ndjson)
- [fix-spec] TraceSpec (Trace.tla) + Trace.cfg: switched from `INIT/NEXT/PROPERTIES` to `SPECIFICATION TraceSpec` with `WF_traceVars(TraceNext)` fairness. Without fairness, TLC reports trivial stuttering counterexamples for the liveness property `<>(ThreadsWithEvents = {})`. (Trace: meta_overwrite_race.ndjson)
- [fix-spec] IterBegin/IterEnd (base.tla): iterIdx now starts at 0 and ends at `>= Cardinality(Slot)` (was 1 and `> Cardinality(Slot)`). Trace slot indices are 0-based (matching impl's `self.i: usize`); old 1-based iterIdx never matched any slot. ValidateIterBegin updated to `iterIdx' = 0`. (Trace: incremental_resize_iter.ndjson)
- [fix-spec] IterEnd (base.tla): now resets `iterTable[tid]` to NULL on completion, mirroring the impl's drop-of-Iter releasing its `table` reference. Without this, a thread cannot start a second IterBegin in the same trace. (Trace: incremental_resize_iter.ndjson)
- [fix-spec] MC.cfg + all MC_hunt_*.cfg: changed Slot from string set `{s1,s2,...}` to integer set `{0,1,...}` so the iter actions (which use `s = iterIdx[tid]`) can actually fire. With string slots, iter actions were dead in MC.
- [fix-inv] MC_hunt_meta_overwrite.cfg: removed InsertWindowConsistency from invariant list (the Family-7 bug-window legitimately violates it; it would mask the target invariant NoStaleMetaOnEmptySlot).

## Round 1 - Model Checking

- [fix-spec] ReclaimEntry (base.tla): TLC raised "Attempted to select field 'key' from a non-record value NULL" — `\/` in TLA+ is not short-circuiting, so `tableEntry[t][s].key /= entry.key` was evaluated even when the slot was NULL. Restructured with a LET binding and conjoined `e /= NULL` before record access.

## Round 2 - Trace Validation

- All 4 traces re-validated successfully after Phase 2 spec modification (ReclaimEntry NULL guard does not affect any trace event).

## Round 2 - Model Checking

- 30-minute BFS run with `MC.cfg` over standard safety + structural invariants (NoDuplicateEntry, ProbeChainIntegrity, PromotionSafety, ResizeStatusConsistency, CopiedCountBound, MetaConsistency, TagConsistency, InsertWindowConsistency). 56.5M states generated, 9.2M distinct, BFS depth 13. No violations.

## Round 3 - Bug Hunting

### Bugs found (3)

- [bug] **Bug 1 — Wrong-Parker on Blocking Resize Abort** (`MC_hunt_parker_deadlock.cfg`): `NoParkedOnAborted` violated at 5 states / depth 7 in 5 s. Confirms D2-1, still unfixed on upstream master b510b15. Output: `output/MC_hunt_parker_deadlock_bfs.out`. Details in `bug-report.md` Bug 1.
- [bug] **Bug 2 — META Overwrite on Phase-2 Store** (`MC_hunt_meta_overwrite.cfg`): `NoStaleMetaOnEmptySlot` violated at 5 states / depth 11 in 16 s. Confirms D2-4, in-tree reproducer at `tests/repro_bug1_meta_overwrite.rs`. Output: `output/MC_hunt_meta_overwrite_bfs.out`. Details in `bug-report.md` Bug 2.
- [bug] **Bug 3 — Iter Double-Yield Across Insert/Remove/Reinsert** (`MC_hunt_iter_double_yield.cfg`): `IterNoDoubleYield` violated at 10 states / depth 11 in 7 s. New finding (caller-visible API contract issue). Output: `output/MC_hunt_iter_double_yield_bfs.out`. Details in `bug-report.md` Bug 3.

### Hunts with no violation

- `MC_hunt_iter_weak_snapshot.cfg`: BFS 30 min depth 13 (195K distinct) + sim 190M states / 8.6M traces — no violation.
- `MC_hunt_reclamation.cfg`: BFS exhaustively completed in 15 s (309K distinct, depth 20) — no violation.
- `MC_hunt_resize_race.cfg`: see Round 3 fix below.

### Spec fix during hunting

- [fix-spec] CopyInsertToNext (base.tla) (Case B): The first `MC_hunt_resize_race.cfg` BFS reported `NoLostEntry` violated. Inspection showed the spec allowed `CopyInsertToNext` to fire twice with the same `srcS` and different `dstS` (re-copying the same key) because the spec did not model the impl's chunk-claim partitioning at `mod.rs:2292` (`claim.fetch_add(copy_chunk, ...)`). Fix: the action now sets the `COPIED` tag on the source as part of the action body, so the precondition `~ HasTag(src, COPIED)` enforces one-shot semantics. After the fix, `MC_hunt_resize_race.cfg` BFS exhaustively explored 4.7M distinct states to depth 23 with no errors. Trace validation re-passed.

## Round 3 - Trace Validation

- All 4 traces re-validated successfully after the CopyInsertToNext fix.

## Round 3 - Model Checking (re-convergence)

- 30-minute BFS run with `MC.cfg`. 167M states generated, 25.5M distinct, BFS depth 14 reached. No invariant violations before the JVM crashed at the deadline. Coverage exceeds Round 2's 9.2M / depth 13.

## Result

Converged in 3 rounds. Bug hunting found **3 bugs** across 6 family configs. See `bug-report.md`.


