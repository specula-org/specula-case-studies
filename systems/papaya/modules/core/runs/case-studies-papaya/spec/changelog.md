# papaya Spec Validation Changelog

## Round 1 - Trace Validation
- [fix] Trace.tla: Removed SilentAdvanceEpoch and SilentReclaimEntry (unbounded state space from infinite epoch increments)
- [fix] Trace.tla: Switched from SPECIFICATION+PROPERTIES to INIT/NEXT deadlock-based completion (temporal property trivially fails without fairness)
- [fix] Trace.tla: Added rootTable'=logline.table constraint in init_table match (non-deterministic table choice caused early deadlock)
- [fix] Trace.tla: Added nextTable' constraint in alloc_next match (same issue for next table allocation)
- [fix] Trace.tla: Removed SilentInsertStoreMeta (prematurely wrote meta for slots with pending explicit insert_meta events, causing deadlock)
- [fix-inv] NoDuplicateEntry: Also exclude COPYING entries from live count (during copy window, entry exists in both old and new table — this is expected, not a duplicate)
- [fix-spec] InsertStoreMeta: Removed ~ HasTag(COPYING) guard. Meta store operates on separate atomic (meta byte), completes regardless of entry pointer's COPYING tag. (Trace: concurrent_insert_resize.json)
- [fix-inv] ResizeStatusConsistency: Weakened from "PROMOTED implies root or nextTable-reachable" to "root must be PROMOTED". Old tables retain PROMOTED after double promotion. (Trace: concurrent_insert_resize.json)
- [fix] Trace.tla: Replaced per-slot SilentCopyMarkCopyingNull with SilentBatchCopyNullSlots (batch processes all null slots at once before try_promote, eliminates N! ordering explosion)

## Round 1 - Model Checking
- [fix-spec] InsertCASEntry: Added probe-chain duplicate prevention — key must not exist in any table in the chain (raw/mod.rs:472-582 probe loop guarantees this). Also removed MC.cfg action substitution lines (MCSpec already calls bounded wrappers directly). (Case B)
- [fix-spec] AllocNextTable: Added `nt \notin TableChain(rootTable)` and `nextTable[nt] = NULL` guards to prevent table chain cycles. After promotion, old table's nextTable link persists; reusing it without these guards caused infinite recursion in TableChain. (Case B)
- [fix-spec] CopyInsertToNext: Added guard that key must not already exist in destination table. In the real system, insert_copy uses CAS — only the first thread's CAS wins; subsequent threads find the key exists. (Case B)

## Round 2 - Trace Validation
- All 3 traces pass (no regressions): basic_insert (18 states), concurrent_insert_remove (50 states), concurrent_insert_resize (144 states)

## Round 2 - Model Checking
- Passed: 1.73B states generated, 141M distinct, depth 16, 30 min BFS, 48 workers, no violations across 7 invariants (NoDuplicateEntry, ProbeChainIntegrity, PromotionSafety, ResizeStatusConsistency, CopiedCountBound, MetaConsistency, TagConsistency)

## Bug Hunting
- [bug] AbortResize/ParkThread: NoParkedOnAborted violated — unpark targets wrong parker (table.parker instead of next.parker). Real bug MC-1, 5-state trace. (MC_hunt_parker_deadlock.cfg)
- [fix-inv] CopyCompleteness: Weakened to only check active chain tables + live keys (Case A). Post-promotion removes are legitimate.
- [fix-inv] NoUseAfterReclaim: Changed to slot-level tracking (Case A). Prevents false positives on remove+re-insert at different slot.
- [fix-inv] InsertUpdate: Removed retirement tracking — key-level model can't distinguish old/new pointers at same slot (Case A).
- MC_hunt_twophase BFS: PASSED — 19K states, depth 11, complete BFS
- MC_hunt_twophase Simulation: PASSED — 844M states, 77.6M traces, depth 50, 35 min
- MC_hunt_resize_race BFS: PASSED — 644M states, 47.5M distinct, depth 18, 35 min
- MC_hunt_resize_race Simulation: PASSED — 881M states, 35.7M traces, depth 75, 30 min
- MC_hunt_reclamation BFS: PASSED — 206M states, 20.9M distinct, depth 27, 13 min (complete)
- [fix] Trace.tla: Added completion stutter (UNCHANGED when ThreadsWithEvents={}) to avoid false deadlock error in trace validation tool

## Result
Converged in 2 rounds. Bug hunting: 1 bug found (MC-1: parker deadlock on abort). ~2.6B total states explored across 5 hunting runs.
