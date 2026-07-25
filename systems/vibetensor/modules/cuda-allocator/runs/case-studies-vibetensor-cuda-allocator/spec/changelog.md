# VibeTensor CUDA Allocator — Spec Validation Changelog

## Round 1 - Trace Validation

- [fix-spec] RawDeletePublish: replaced invalid `CHOOSE TRUE : TRUE` expression at
  base.tla:544 (TRUE is a built-in symbol, not a bound variable). Used the simpler
  `limboTokenSeq + 1` token pattern, matching PePublish.
- [fix-cfg] Trace.cfg CONSTANTS: changed symbolic model values `{t1, t2, t3}`,
  `{s1, s2, s3}`, `{b1..b6}`, `{p0, p1}` to string/integer literals matching the
  JSON trace schema ("t1", "s1", 1..10, 0..1). Outer `tidMap` uses strings, inner
  `bid`/`pool` fields are integers.
- [fix-cfg] Trace.cfg Streams/BlockIds: extended to cover concurrent_alloc trace
  (5 streams, 10 block IDs).
- [fix-spec] base.tla PePopReady: added explicit `ghostDangling'` assignment in
  both IF branches (was left undefined on the existing-block path, causing
  "Successor state is not completely specified").
- [fix-spec] Trace.tla SilentActions: replaced UNCHANGED stub with the internal
  PE state-machine transitions (PeRecordOk, PeSkipCapturing, PeLoopDone) the
  harness doesn't emit directly. PeRecordFail is a fault-injection action and is
  NOT included in silent firing — its inclusion caused dead-ends where
  `pe.publish` could not fire.
- [fix-spec] Trace.tla TraceSpec: added `WF_<<vars, pc, windowObs>>(TraceNext)`
  fairness constraint. TLC warned that temporal properties without fairness
  admit trivial infinite-stutter counterexamples, which indeed happened at
  `TraceMatched`.
- [fix-spec] Trace.tla ValidateAlloc: removed `logline.state.reservedBytes =
  reservedBytes'` check (spec uses unit=1 abstraction; trace has real byte
  counts). Abstraction gap.
- [fix-spec] Trace.tla ValidatePublish: removed `logline.state.rdOutcome` check
  (harness ghost variable is always "" per INSTRUMENTATION.md). Abstraction gap.

All traces (basic_alloc_free, concurrent_alloc, deferred_capture) pass.


## Round 1 - Model Checking

- [fix-inv] NoDoubleFree: exclude "RolledBack" — rollback already restored
  block.allocated=TRUE, so another thread may validly begin raw_delete before
  the first calls FinishRollback. (Case A)
- [bug] F1.1 Phantom block via GC detach + ID reuse: MCGcDetach(b1) fires while
  t1 is in raw_delete Marked state. b1 id gets re-allocated; t2's subsequent
  RawDeleteMark(b1) puts both t1.rdBlock=b1 and t2.rdBlock=b1 in Marked.
  NoDoubleFree surfaces it in 7s of BFS. The canonical catcher is
  NoDanglingInFlight (MC_hunt_F1.cfg). TLC output saved to
  output/MC_bug_F1_via_NoDoubleFree.out. (Case C)
- [fix-cfg] MC.cfg: moved NoDoubleFree out of standard-safety invariants. Its
  observable surface is the F1.1 bug, already captured by NoDanglingInFlight
  during bug hunting. Keeping it in MC.cfg would block convergence of the
  remaining structural invariants.
- [bug] F1.1 Phantom block via GC detach + split reuse: MCGcDetach(b1) detaches a
  block while t1 has rdBlock=b1 in Marked. MCSplit(b2) picks b1 as fresh tail;
  b1 is now in perStreamFree[s1] with block[b1].allocated=FALSE. t1 then
  MCRawDeleteRecordFail rolls back, setting block[b1].allocated=TRUE on the
  stale reference, corrupting the new block's free-list membership.
  FreeListConsistency detects the corruption. Saved to
  output/MC_bug_F1_via_FreeListConsistency.out. (Case C)
- [fix-cfg] MC.cfg: added `NoGhostDangling` as a state CONSTRAINT (not
  invariant). This prunes F1.1/F1.2 phantom-free traces from convergence so
  the remaining structural invariants (TypeOK, FreeListConsistency,
  SegmentChainWellFormed) can be checked without triggering the bug each time.
  The bug stays reachable under MC_hunt_F1.cfg.
- [fix-spec] GcDetachIdleSegment: added `h \in existingBlocks` guard and reset
  segPrev/segNext to NullBlock for every block in the detached chain. Without
  the reset, stale segment pointers survive detach and corrupt subsequent
  splits/allocations that reuse the detached block ids.  (Case B)
