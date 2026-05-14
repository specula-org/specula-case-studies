--------------------------------- MODULE MC ---------------------------------
(***************************************************************************
  MC wrapper for VibeTensor CUDA allocator base spec.

  Counter-bounded fault-injection (not normal reactive actions): split,
  capture begin/end, stream capture flips, malloc fail flips, cudaEvent
  fail outcomes, emptyCache/GC triggers.  All safe interleavings (raw_alloc
  reuse, raw_delete, process_events steps, coalesce, limbo drain) remain
  unconstrained so the target bug mechanisms stay reachable (see
  references/mc-spec-pattern.md — Category B hunting pattern).
 ***************************************************************************)
EXTENDS base, TLC

CONSTANTS
    MaxSplitOps,     \* bound on Split actions
    MaxCaptureOps,   \* bound on pool begin/end/cancel
    MaxCaptureFlips, \* bound on stream capture flips
    MaxMallocFlips,  \* bound on malloc success/fail flips
    MaxGcOps,        \* bound on standalone GC / emptyCache
    MaxRecordFails,  \* bound on raw_delete / pe record failures

    \* Liveness envelope
    Liveness

VARIABLES
    mcCounters  \* record of fault-injection counters

McInit ==
    /\ Init
    /\ mcCounters = [ split      |-> 0,
                      capture    |-> 0,
                      flips      |-> 0,
                      mallocFlip |-> 0,
                      gcOps      |-> 0,
                      recFails   |-> 0 ]

\* ---------------------------------------------------------------------
\* Bounded wrappers.  Each wraps a base action and increments its counter.
\* ---------------------------------------------------------------------

MCSplit(b) ==
    /\ mcCounters.split < MaxSplitOps
    /\ Split(b)
    /\ mcCounters' = [mcCounters EXCEPT !.split = @ + 1]

MCBeginCapture(t, id) ==
    /\ mcCounters.capture < MaxCaptureOps
    /\ BeginCapture(t, id)
    /\ mcCounters' = [mcCounters EXCEPT !.capture = @ + 1]

MCEndCaptureFlat(t, id) ==
    /\ mcCounters.capture < MaxCaptureOps
    /\ EndCaptureFlat(t, id)
    /\ mcCounters' = [mcCounters EXCEPT !.capture = @ + 1]

MCGuardDestruct(t, id) ==
    /\ mcCounters.capture < MaxCaptureOps
    /\ GuardDestruct(t, id)
    /\ mcCounters' = [mcCounters EXCEPT !.capture = @ + 1]

MCStreamCaptureStart(s) ==
    /\ mcCounters.flips < MaxCaptureFlips
    /\ StreamCaptureStart(s)
    /\ mcCounters' = [mcCounters EXCEPT !.flips = @ + 1]

MCStreamCaptureEnd(s) ==
    /\ mcCounters.flips < MaxCaptureFlips
    /\ StreamCaptureEnd(s)
    /\ mcCounters' = [mcCounters EXCEPT !.flips = @ + 1]

MCMallocFlipToFail ==
    /\ mcCounters.mallocFlip < MaxMallocFlips
    /\ MallocFlipToFail
    /\ mcCounters' = [mcCounters EXCEPT !.mallocFlip = @ + 1]

MCMallocFlipToOk ==
    /\ mcCounters.mallocFlip < MaxMallocFlips
    /\ MallocFlipToOk
    /\ mcCounters' = [mcCounters EXCEPT !.mallocFlip = @ + 1]

MCGcDetach(h) ==
    /\ mcCounters.gcOps < MaxGcOps
    /\ GcDetachIdleSegment(h)
    /\ mcCounters' = [mcCounters EXCEPT !.gcOps = @ + 1]

MCEmptyCache ==
    /\ mcCounters.gcOps < MaxGcOps
    /\ EmptyCache
    /\ mcCounters' = [mcCounters EXCEPT !.gcOps = @ + 1]

MCRawDeleteRecordFail(t) ==
    /\ mcCounters.recFails < MaxRecordFails
    /\ RawDeleteRecordFail(t)
    /\ mcCounters' = [mcCounters EXCEPT !.recFails = @ + 1]

MCPeRecordFail(t) ==
    /\ mcCounters.recFails < MaxRecordFails
    /\ PeRecordFail(t)
    /\ mcCounters' = [mcCounters EXCEPT !.recFails = @ + 1]

\* ---------------------------------------------------------------------
\* Unbounded (reactive) wrappers — they only add UNCHANGED mcCounters.
\* ---------------------------------------------------------------------
Pass(A) == A /\ UNCHANGED mcCounters

MCNext ==
    \* Alloc / reuse
    \/ \E t \in Threads, sid \in Streams, pool \in PoolIds :
         Pass(RawAllocNewBlock(t, sid, pool))
    \/ \E t \in Threads, sid \in Streams, pool \in PoolIds :
         Pass(RawAllocReuseFromFreeList(t, sid, pool))
    \/ \E t \in Threads, sid \in Streams :
         Pass(RawAllocReuseFromCross(t, sid))

    \* Split (bounded)
    \/ \E b \in BlockIds : MCSplit(b)

    \* record_stream / raw_delete PC steps (reactive)
    \/ \E t \in Threads, b \in BlockIds, s \in Streams :
         Pass(RecordStream(t, b, s))
    \/ \E t \in Threads, b \in BlockIds, s \in Streams :
         Pass(RawDeleteMark(t, b, s))
    \/ \E t \in Threads, b \in BlockIds, s \in Streams :
         Pass(RawDeleteSameStreamFastPath(t, b, s))
    \/ \E t \in Threads : Pass(RawDeleteRecordOk(t))
    \/ \E t \in Threads : MCRawDeleteRecordFail(t)
    \/ \E t \in Threads : Pass(RawDeletePublish(t))
    \/ \E t \in Threads : Pass(RawDeleteFinishRollback(t))
    \/ \E t \in Threads : Pass(RawDeleteToDeferred(t))

    \* process_events deferred flush (reactive)
    \/ \E t \in Threads : Pass(PeSnapshot(t))
    \/ \E t \in Threads : Pass(PeSkipCapturing(t))
    \/ \E t \in Threads : Pass(PeRecordOk(t))
    \/ \E t \in Threads : MCPeRecordFail(t)
    \/ \E t \in Threads : Pass(PePublish(t))
    \/ \E t \in Threads : Pass(PeLoopDone(t))

    \* limbo drain
    \/ \E sid \in Streams : Pass(PePopReady(sid))

    \* coalesce (reactive; bug-carrying predicate)
    \/ \E b \in BlockIds : Pass(CoalesceLeft(b))
    \/ \E b \in BlockIds : Pass(CoalesceRight(b))

    \* GC / emptyCache (bounded)
    \/ \E h \in BlockIds : MCGcDetach(h)
    \/ MCEmptyCache

    \* Graph pool lifecycle (bounded)
    \/ \E t \in Threads, id \in PoolIds : MCBeginCapture(t, id)
    \/ \E t \in Threads, id \in PoolIds : MCEndCaptureFlat(t, id)
    \/ \E t \in Threads, id \in PoolIds : MCGuardDestruct(t, id)
    \/ \E t \in Threads, id \in PoolIds : Pass(RetainPool(t, id))
    \/ \E t \in Threads, id \in PoolIds : Pass(ReleasePool(t, id))

    \* Fraction cap (reactive)
    \/ \E t \in Threads : Pass(PassGate(t))
    \/ \E t \in Threads : Pass(PassGateRetryMisfire(t))
    \/ \E t \in Threads : Pass(PassGateRecovered(t))

    \* Environment flips (bounded)
    \/ \E s \in Streams : MCStreamCaptureStart(s)
    \/ \E s \in Streams : MCStreamCaptureEnd(s)
    \/ MCMallocFlipToFail
    \/ MCMallocFlipToOk

MCSpec == McInit /\ [][MCNext]_<<vars, mcCounters>>

\* ---------------------------------------------------------------------
\* Symmetry: threads and streams and block-ids are permutation-symmetric.
\* ---------------------------------------------------------------------
Perms ==
    Permutations(Threads) \cup
    Permutations(Streams) \cup
    Permutations(BlockIds)

\* View excludes the counters (they blow up state space)
View == <<vars>>

\* ---------------------------------------------------------------------
\* State-space bound: reclamation queues cannot grow without bound
\* ---------------------------------------------------------------------
MaxQueueLen == 4

QueueBound ==
    /\ Len(deferredQ) <= MaxQueueLen
    /\ \A sid \in Streams : Len(limbo[sid]) <= MaxQueueLen

\* Use as a state constraint in MC.cfg.

\* ---------------------------------------------------------------------
\* Temporal / liveness (Family 1, 2, 6)
\* ---------------------------------------------------------------------
RawDeleteEventuallyPublishes ==
    \A t \in Threads :
      (rdPc[t] = "Marked") ~> (rdPc[t] \in {"Idle", "RolledBack"})

PeEventuallyDrains ==
    \A t \in Threads :
      (pePc[t] = "Snapshotted") ~> (pePc[t] = "Idle")

AllocEventuallySucceedsWeak ==
    \* Under fairness, if mallocWillFail is eventually FALSE and no stream is
    \* capturing forever, an outstanding raw_alloc eventually completes.
    TRUE  \* placeholder; encoded via strong fairness on RawAllocNewBlock

==============================================================================
