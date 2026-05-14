-------------------------------- MODULE base --------------------------------
(***************************************************************************
  VibeTensor CUDA caching allocator — Category B (concurrent / lock-free /
  runtime) spec.

  Scope (from modeling-brief.md §Scoping): native backend `vbt::cuda::Allocator`
  — block/segment chain, per-stream + cross-stream free lists, deferred frees,
  limbo (stream-ordered reclamation), graph-pool lifecycle, fraction cap.

  Source: vibetensor/src/vbt/cuda/allocator.cc (4029 LOC),
          vibetensor/include/vbt/cuda/allocator.h (706 LOC).

  Bug families targeted (brief §2):
    F1  Phantom free block (off-lock raw_delete window + deferred)
    F2  Non-idempotent concurrent process_events deferred flush
    F3  Lost stream-use fence on raw_delete rollback
    F4  Graph-pool lifecycle — guard stale destruction and boolean counters
    F5  Fraction-cap TOCTOU gate vs. cudaMalloc
    F6  GC ladder non-monotonicity under reshape

  Category B motivations:
    - The single mutex mu_ is released and re-acquired around every CUDA API
      call; every release/acquire pair is a linearization window we must
      expose as a distinct state.
    - `s_capture_tls` and `routing_active_flag_` are a thread-local / shared
      flag pair whose consistency breaks under interleaved capture begin/end.
    - `deferred_` and `limbo_` are reclamation queues with their own visibility
      windows — we split enqueue/record/publish where the code does.
 ***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    Threads,        \* finite set of thread identifiers
    Streams,        \* finite set of CUDA stream identifiers
    BlockIds,       \* finite pool of potential block IDs (abstract handles)
    PoolIds,        \* finite set of graph private pool IDs
    DefaultPool,    \* the distinguished default/global pool id (value 0 in code)
    FractionLimit,  \* abstract cap in units (Nat); MAX means effectively disabled
    MaxPoolOps,     \* bound on pool begin/end/cancel counts for MC
    NullBlock,      \* symbolic "no block" sentinel
    NullStream      \* symbolic "no stream" sentinel

ASSUME DefaultPool \in PoolIds
ASSUME NullBlock \notin BlockIds
ASSUME NullStream \notin Streams

BlockIdsOrNull   == BlockIds \cup {NullBlock}
StreamsOrNull    == Streams \cup {NullStream}

\* -------------------------------------------------------------------------
\* Thread program-counter enumerations (every release/re-acquire window is a
\* PC state; see brief §3.1).
\* -------------------------------------------------------------------------
RdPc  == {"Idle", "Marked", "RecordFailed", "Published", "RolledBack"}
PePc  == {"Idle", "Snapshotted", "Recorded"}
FgPc  == {"Idle", "SampledLimit", "PastGate", "GCDone"}
GcPc  == {"Idle", "PlanBuilt"}

\* =========================================================================
\* Variables
\* =========================================================================

\* -- Block & segment state (Family 1, 3, 6 motivated) ---------------------
VARIABLES
    existingBlocks, \* SUBSET BlockIds: which block IDs are currently live (NOT `delete`d)
                    \* source: exists whenever the code has `new Block()` without
                    \* a matching `delete`. (allocator.cc:1311, 1818, 3818, 3860, 1890)

    block,          \* [BlockIds -> BlockRec] block field record; only meaningful for b \in existingBlocks
                    \* models Block struct at allocator.h:622-639

    segPrev,        \* [BlockIds -> BlockIdsOrNull]  Block::prev (allocator.h:632)
    segNext,        \* [BlockIds -> BlockIdsOrNull]  Block::next (allocator.h:633)

    byPtr,          \* SUBSET BlockIds: mirror of by_ptr_ map membership
                    \* (allocator.h:641; touched at allocator.cc:1324, 1336, 1603, 1817, 3817, 3834, 3859, 3872, 1884)

    activeBlocks    \* SUBSET BlockIds: mirror of active_blocks_
                    \* (allocator.h:642; allocator.cc:1325, 1577, 1793, 1887)

VARIABLES
    perStreamFree,  \* [Streams -> SUBSET BlockIds]  mirror of per_stream_free_
                    \* (allocator.h:643; insert/remove at 1579, 1796, 3802, 3845, ...)
    crossStreamFree \* SUBSET BlockIds  mirror of cross_stream_free_
                    \* (allocator.h:644; inserted by insert_free_block_unlocked; erased at 1582)

\* -- Reclamation state (Family 1, 2 motivated) ----------------------------
VARIABLES
    limbo,          \* [Streams -> Seq([b: BlockIds, token: Nat])]
                    \* mirror of limbo_ map (allocator.h:645; push at 1660, 1734; pop at 1786)
    limboTokenSeq,  \* Nat counter; models limbo_token_seq_ (allocator.h:646)
    deferredQ       \* Seq([b: BlockIds, ownerSid: Streams, streams: SUBSET Streams])
                    \* mirror of deferred_ deque (allocator.h:649; push at 1602; erase at 1729-1731)

\* -- Per-thread raw_delete PC (Family 1.1 + Family 3) ---------------------
VARIABLES
    rdPc,           \* [Threads -> RdPc]
    rdBlock,        \* [Threads -> BlockIdsOrNull]: block being deleted by this thread
    rdSnapshot,     \* [Threads -> SUBSET Streams]: `snapshot` vector at 1563-1565
    rdPrevOwner,    \* [Threads -> StreamsOrNull]: prev_owner_sid at 1555
    rdNewOwner,     \* [Threads -> StreamsOrNull]: owner_sid_new at 1548
    rdRecorded      \* [Threads -> SUBSET Streams]: pendings recorded off-lock (1611-1624)

\* -- Per-thread process_events PC (Family 2) ------------------------------
VARIABLES
    pePc,           \* [Threads -> PePc]
    peCands,        \* [Threads -> Seq of deferred-entry snapshots] (1696-1700)
    peIdx,          \* [Threads -> Nat]: index into peCands being processed
    peRecorded      \* [Threads -> SUBSET Streams]: pendings recorded off-lock (1712-1721)

\* -- Graph-pool lifecycle state (Family 4) --------------------------------
VARIABLES
    poolState,      \* [PoolIds -> [refcnt: Nat, activeCap: Nat,
                    \*              activeRep: Nat, prewarm: Nat]]
                    \* mirror of graph_pools_ map (allocator.h:660; allocator.cc:819-977)
    tls,            \* [Threads -> [active: BOOLEAN, pool: PoolIds]]  (allocator.cc: s_capture_tls)
                    \* written at 883-886, cleared at 893-896, 917-920
    routingFlag,    \* BOOLEAN; routing_active_flag_ (allocator.h:679; 887, 898, 922)
    guardOwners,    \* SUBSET (Threads \X PoolIds): outstanding RAII guards
                    \* models AllocateToPoolGuard (allocator.cc:1128-1171)
    poolOpsTotal    \* Nat: total pool begin/end/cancel events for MC bounding

\* -- Fraction cap state (Family 5) ----------------------------------------
VARIABLES
    reservedBytes,     \* Nat: stats_.reserved_bytes_all_current (allocator.h: stats field)
                       \* bumped at 1326, decremented at 2056-2059, 2113-2117
    fgPc,              \* [Threads -> FgPc]
    fgReservedSnap,    \* [Threads -> Nat]: reserved_before sample at 359-361
    fgLimitSnap,       \* [Threads -> Nat]: limit_before sample at 350
    fractionBreaches,  \* Nat: stats_.fraction_cap_breaches (incremented at 370)
    fractionMisfires   \* Nat: stats_.fraction_cap_misfires (incremented at 442)

\* -- CUDA runtime state we model non-deterministically --------------------
VARIABLES
    streamCapturing,   \* [Streams -> BOOLEAN]: is_stream_capturing(dev, sid) (used at 1595, 1702, 1750)
    mallocWillFail     \* BOOLEAN: nondet cudaMalloc failure (env-modeled)

\* -- GC ladder state (Family 6) -------------------------------------------
VARIABLES
    gcPasses,          \* Nat: stats_.gc_passes (2061)
    ghostDangling      \* SUBSET BlockIds: blocks referenced by queues whose storage has been `delete`d.
                       \* PURE AUDIT VARIABLE — set by coalesce/detach when they free a block that is
                       \* still referenced by deferredQ or limbo. Used by NoDanglingXxx invariants.

\* =========================================================================
\* Variable groups for UNCHANGED clauses
\* =========================================================================
blockVars    == <<existingBlocks, block, segPrev, segNext, byPtr, activeBlocks>>
freeVars     == <<perStreamFree, crossStreamFree>>
reclaimVars  == <<limbo, limboTokenSeq, deferredQ>>
rdVars       == <<rdPc, rdBlock, rdSnapshot, rdPrevOwner, rdNewOwner, rdRecorded>>
peVars       == <<pePc, peCands, peIdx, peRecorded>>
poolVars     == <<poolState, tls, routingFlag, guardOwners, poolOpsTotal>>
fgVars       == <<reservedBytes, fgPc, fgReservedSnap, fgLimitSnap, fractionBreaches, fractionMisfires>>
cudaVars     == <<streamCapturing, mallocWillFail>>
gcVars       == <<gcPasses, ghostDangling>>

vars == <<blockVars, freeVars, reclaimVars, rdVars, peVars, poolVars,
          fgVars, cudaVars, gcVars>>

\* =========================================================================
\* Helpers
\* =========================================================================
BlockRecType == [ allocated: BOOLEAN,
                  eventCount: Nat,
                  streamUses: SUBSET Streams,
                  graphPool: PoolIds,
                  ownerStream: Streams,
                  allocStream: Streams,
                  segmentHead: BOOLEAN,
                  isSplitTail: BOOLEAN,
                  gcAge: Nat ]

\* Walk segment chain (bounded fold); returns head and tail reachability sets.
RECURSIVE WalkFwd(_, _, _)
WalkFwd(start, acc, budget) ==
    IF budget = 0 \/ start = NullBlock THEN acc
    ELSE WalkFwd(segNext[start], acc \cup {start}, budget - 1)

RECURSIVE WalkBack(_, _, _)
WalkBack(start, acc, budget) ==
    IF budget = 0 \/ start = NullBlock THEN acc
    ELSE WalkBack(segPrev[start], acc \cup {start}, budget - 1)

\* bounded; state space keeps BlockIds small anyway
MaxChain == Cardinality(BlockIds) + 1
SegmentMembers(b) == WalkFwd(b, WalkBack(segPrev[b], {b}, MaxChain), MaxChain)

SegmentHeadOf(b) ==
    CHOOSE h \in SegmentMembers(b) : segPrev[h] = NullBlock

\* "eligible_neighbor" predicate from allocator.cc:3767-3789 (NOTE: does NOT
\* check free-index membership — this is the bug-carrying predicate from F1.1)
EligibleNeighbor(n, anchor) ==
    /\ n \in existingBlocks
    /\ ~ block[n].allocated
    /\ block[n].eventCount = 0
    /\ block[n].streamUses = {}
    /\ block[n].graphPool = block[anchor].graphPool

\* "find_candidate_heads" inner chain-walk predicate (1832-1836); also bug-carrying.
IdleSegment(h) ==
    /\ segPrev[h] = NullBlock
    /\ block[h].segmentHead
    /\ \A cur \in SegmentMembers(h) :
         /\ block[cur].graphPool = DefaultPool
         /\ ~ block[cur].allocated
         /\ block[cur].eventCount = 0

\* A block is referenced by any reclamation queue or in-flight delete/pe slot.
ReferencedByQueues(b) ==
    \/ \E sid \in Streams : \E i \in 1..Len(limbo[sid]) : limbo[sid][i].b = b
    \/ \E i \in 1..Len(deferredQ) : deferredQ[i].b = b
    \/ \E t \in Threads : rdBlock[t] = b /\ rdPc[t] \in {"Marked", "RecordFailed"}
    \/ \E t \in Threads : \E i \in 1..Len(peCands[t]) : peCands[t][i].b = b

\* Sequence helpers
SeqToSet(s)       == { s[i] : i \in 1..Len(s) }
SeqExcept(s, i)   == [j \in 1..(Len(s)-1) |-> IF j < i THEN s[j] ELSE s[j+1]]

\* =========================================================================
\* Init
\* =========================================================================
EmptyBlock == [ allocated     |-> FALSE,
                eventCount    |-> 0,
                streamUses    |-> {},
                graphPool     |-> DefaultPool,
                ownerStream   |-> CHOOSE s \in Streams : TRUE,
                allocStream   |-> CHOOSE s \in Streams : TRUE,
                segmentHead   |-> FALSE,
                isSplitTail   |-> FALSE,
                gcAge         |-> 0 ]

Init ==
    /\ existingBlocks  = {}
    /\ block           = [b \in BlockIds |-> EmptyBlock]
    /\ segPrev         = [b \in BlockIds |-> NullBlock]
    /\ segNext         = [b \in BlockIds |-> NullBlock]
    /\ byPtr           = {}
    /\ activeBlocks    = {}
    /\ perStreamFree   = [s \in Streams |-> {}]
    /\ crossStreamFree = {}
    /\ limbo           = [s \in Streams |-> <<>>]
    /\ limboTokenSeq   = 0
    /\ deferredQ       = <<>>
    /\ rdPc            = [t \in Threads |-> "Idle"]
    /\ rdBlock         = [t \in Threads |-> NullBlock]
    /\ rdSnapshot      = [t \in Threads |-> {}]
    /\ rdPrevOwner     = [t \in Threads |-> NullStream]
    /\ rdNewOwner      = [t \in Threads |-> NullStream]
    /\ rdRecorded      = [t \in Threads |-> {}]
    /\ pePc            = [t \in Threads |-> "Idle"]
    /\ peCands         = [t \in Threads |-> <<>>]
    /\ peIdx           = [t \in Threads |-> 0]
    /\ peRecorded      = [t \in Threads |-> {}]
    /\ poolState       = [p \in PoolIds |->
                            [ refcnt |-> 0, activeCap |-> 0,
                              activeRep |-> 0, prewarm |-> 0 ]]
    /\ tls             = [t \in Threads |-> [ active |-> FALSE, pool |-> DefaultPool ]]
    /\ routingFlag     = FALSE
    /\ guardOwners     = {}
    /\ poolOpsTotal    = 0
    /\ reservedBytes   = 0
    /\ fgPc            = [t \in Threads |-> "Idle"]
    /\ fgReservedSnap  = [t \in Threads |-> 0]
    /\ fgLimitSnap     = [t \in Threads |-> 0]
    /\ fractionBreaches = 0
    /\ fractionMisfires = 0
    /\ streamCapturing = [s \in Streams |-> FALSE]
    /\ mallocWillFail  = FALSE
    /\ gcPasses        = 0
    /\ ghostDangling   = {}

\* =========================================================================
\* ACTIONS
\*
\* Each action is annotated with its source-code location in allocator.cc or
\* allocator.h. Multi-step operations (raw_delete, process_events deferred
\* flush, fraction gate) are split at each mu_ release/re-acquire boundary —
\* see brief §3.1.
\* =========================================================================

---------------------------------------------------------------------------
\* *** STREAM CAPTURE ENVIRONMENT (nondeterministic) ***
\* is_stream_capturing(dev, sid) is a CUDA driver query; model as arbitrary
\* flips with MC counter bounds so the spec can explore both branches of
\* `if (any_capturing)` at allocator.cc:1599-1609 and the deferred-flush
\* "capturing continue" branch at 1706.
---------------------------------------------------------------------------
StreamCaptureStart(s) ==
    /\ ~ streamCapturing[s]
    /\ streamCapturing' = [streamCapturing EXCEPT ![s] = TRUE]
    /\ UNCHANGED <<blockVars, freeVars, reclaimVars, rdVars, peVars,
                   poolVars, fgVars, mallocWillFail, gcVars>>

StreamCaptureEnd(s) ==
    /\ streamCapturing[s]
    /\ streamCapturing' = [streamCapturing EXCEPT ![s] = FALSE]
    /\ UNCHANGED <<blockVars, freeVars, reclaimVars, rdVars, peVars,
                   poolVars, fgVars, mallocWillFail, gcVars>>

MallocFlipToFail ==
    /\ ~ mallocWillFail
    /\ mallocWillFail' = TRUE
    /\ UNCHANGED <<blockVars, freeVars, reclaimVars, rdVars, peVars,
                   poolVars, fgVars, streamCapturing, gcVars>>

MallocFlipToOk ==
    /\ mallocWillFail
    /\ mallocWillFail' = FALSE
    /\ UNCHANGED <<blockVars, freeVars, reclaimVars, rdVars, peVars,
                   poolVars, fgVars, streamCapturing, gcVars>>

---------------------------------------------------------------------------
\* *** raw_alloc — fresh cudaMalloc path ***
\* Condensed model of raw_alloc (allocator.cc:1157-1346 / 1349-1511):
\*   1. reuse-from-free-list attempt (modeled as RawAllocReuse actions)
\*   2. fraction-cap gate (modeled as PassGate / BumpReserved, Family 5)
\*   3. cudaMalloc + track block (allocator.cc:1311-1343)
\* This action models the successful-cudaMalloc-and-insert step.
\* Precondition: caller has already passed the fraction gate (fgPc[t]="PastGate")
\*   or disabled the gate (fgLimitSnap[t] = FractionLimit = "MAX").
---------------------------------------------------------------------------
RawAllocNewBlock(t, sid, pool) ==
    \* allocator.cc:1311-1343 — "Create and track the block/segment".
    /\ \E b \in BlockIds \ existingBlocks :
         /\ fgPc[t] \in {"PastGate", "Idle"}  \* "Idle" permitted when gate not needed
         /\ ~ mallocWillFail
         \* Capture gating: do not allocate in capturing-without-routing mode
         \* (allocator.cc:1191-1193 / 1380-1382) — only allow default pool
         \* unless routingActive & tls matches.
         /\ (streamCapturing[sid] =>
               /\ tls[t].active /\ tls[t].pool = pool
               /\ routingFlag /\ pool # DefaultPool)
         /\ (~streamCapturing[sid] => pool = DefaultPool \/ tls[t].active)
         /\ LET fresh == [ EmptyBlock EXCEPT
                            !.allocated   = TRUE,
                            !.ownerStream = sid,
                            !.allocStream = sid,
                            !.segmentHead = TRUE,
                            !.graphPool   = pool ] IN
            /\ existingBlocks' = existingBlocks \cup {b}
            /\ block'    = [block EXCEPT ![b] = fresh]
            /\ segPrev'  = [segPrev EXCEPT ![b] = NullBlock]
            /\ segNext'  = [segNext EXCEPT ![b] = NullBlock]
            /\ byPtr'    = byPtr \cup {b}
            /\ activeBlocks' = activeBlocks \cup {b}
            \* allocator.cc:1326 — reserved_bytes_all_current += rounded (unit=1)
            /\ reservedBytes' = reservedBytes + 1
            /\ fgPc' = [fgPc EXCEPT ![t] = "Idle"]
         /\ UNCHANGED <<freeVars, reclaimVars, rdVars, peVars, poolVars,
                        fgReservedSnap, fgLimitSnap, fractionBreaches,
                        fractionMisfires, streamCapturing, mallocWillFail,
                        gcVars>>

---------------------------------------------------------------------------
\* *** raw_alloc — reuse-from-free-list path ***
\* allocator.cc:1204-1210 / 1391-1397: try_take_free_block_unlocked + on_reuse.
\* This takes a matching free block and marks it allocated under lock. No
\* off-lock window; single atomic step.
---------------------------------------------------------------------------
RawAllocReuseFromFreeList(t, sid, pool) ==
    \* pool routing: if routing, pool must match; else DefaultPool.
    /\ pool = DefaultPool \/ (tls[t].active /\ tls[t].pool = pool)
    /\ \E b \in perStreamFree[sid] :
         /\ block[b].graphPool = pool
         /\ perStreamFree' =
              [perStreamFree EXCEPT ![sid] = @ \ {b}]
         /\ crossStreamFree' = crossStreamFree \ {b}
         /\ block' = [block EXCEPT ![b] =
                        [@ EXCEPT !.allocated = TRUE,
                                  !.ownerStream = sid,
                                  !.streamUses = {}]]
         /\ activeBlocks' = activeBlocks \cup {b}
    /\ UNCHANGED <<existingBlocks, segPrev, segNext, byPtr, reclaimVars,
                   rdVars, peVars, poolVars, fgVars, cudaVars, gcVars>>

RawAllocReuseFromCross(t, sid) ==
    \* allocator.cc:1213-1222 / 1400-1409 — cross_stream fallback (only DefaultPool)
    /\ ~ (tls[t].active /\ tls[t].pool # DefaultPool)
    /\ \E b \in crossStreamFree :
         /\ block[b].graphPool = DefaultPool
         /\ crossStreamFree' = crossStreamFree \ {b}
         /\ perStreamFree' =
              [perStreamFree EXCEPT ![block[b].ownerStream] = @ \ {b}]
         /\ block' = [block EXCEPT ![b] =
                        [@ EXCEPT !.allocated = TRUE,
                                  !.ownerStream = sid,
                                  !.streamUses = {}]]
         /\ activeBlocks' = activeBlocks \cup {b}
    /\ UNCHANGED <<existingBlocks, segPrev, segNext, byPtr, reclaimVars,
                   rdVars, peVars, poolVars, fgVars, cudaVars, gcVars>>

---------------------------------------------------------------------------
\* *** Split ***
\* allocator.cc:3572-3690 (approx split_block_unlocked). Produces a tail
\* block on the segment chain. Single atomic step under mu_.
\* Triggers GC-age reset at 3688 (seg_head->gc_age = 0).
---------------------------------------------------------------------------
Split(b) ==
    /\ b \in existingBlocks /\ block[b].allocated
    /\ \E tail \in BlockIds \ existingBlocks :
         LET newTail == [ EmptyBlock EXCEPT
                            !.allocated   = FALSE,
                            !.ownerStream = block[b].ownerStream,
                            !.allocStream = block[b].allocStream,
                            !.graphPool   = block[b].graphPool,
                            !.isSplitTail = TRUE,
                            !.segmentHead = FALSE ] IN
         /\ existingBlocks' = existingBlocks \cup {tail}
         /\ block'   = [block EXCEPT ![tail] = newTail,
                                     ![SegmentHeadOf(b)] = [@ EXCEPT !.gcAge = 0]]
         /\ segNext' = [segNext EXCEPT ![tail] = segNext[b], ![b] = tail]
         /\ segPrev' = [segPrev EXCEPT ![tail] = b,
                                       ![segNext[b]] = IF segNext[b] = NullBlock THEN @ ELSE tail]
         /\ byPtr'   = byPtr \cup {tail}
         /\ perStreamFree' =
              [perStreamFree EXCEPT
                 ![newTail.ownerStream] = @ \cup {tail}]
    /\ UNCHANGED <<activeBlocks, crossStreamFree, reclaimVars, rdVars,
                   peVars, poolVars, fgVars, cudaVars, gcVars>>

---------------------------------------------------------------------------
\* *** record_stream ***
\* allocator.cc:1673-1690. Under lock; guard: b->allocated, device match,
\* stream != alloc_stream && stream != owner_stream.
\* **Key for Family 3**: early-returns if ~allocated, even when raw_delete
\*   is in its off-lock window; the stream registration is silently dropped.
---------------------------------------------------------------------------
RecordStream(t, b, s) ==
    /\ b \in existingBlocks
    /\ \* 1682: if (!b->allocated) return; — observable when window is open
       block[b].allocated
    /\ s # block[b].allocStream /\ s # block[b].ownerStream
    /\ block' = [block EXCEPT ![b] =
                    [@ EXCEPT !.streamUses = @ \cup {s}]]
    /\ UNCHANGED <<existingBlocks, segPrev, segNext, byPtr, activeBlocks,
                   freeVars, reclaimVars, rdVars, peVars, poolVars,
                   fgVars, cudaVars, gcVars>>

---------------------------------------------------------------------------
\* *** raw_delete — three-step split (Family 1.1 + Family 3) ***
\*
\* The code (allocator.cc:1520-1671) is:
\*   A) {mu_ held}   allocated=false; owner_stream=new; snapshot=stream_uses;
\*                   stream_uses.clear(); decrement stats.          (1553-1584)
\*   B) {mu_ released} cudaEventRecord(sid) for each sid in snapshot (1615-1625)
\*   C) {mu_ held}   event_count += N; limbo[sid].push(...)         (1656-1663)
\*      — OR on failure: rollback (1626-1653): allocated=true,
\*        stream_uses += snapshot, restore stats.
\*
\* Between (A) and (C) the block is **phantom-free**: allocated=false,
\* stream_uses={}, event_count=0 — yet it's still on the chain and in byPtr.
\* Another thread performing coalesce or GC scan can observe it as free
\* (brief §F1.1).
---------------------------------------------------------------------------
RawDeleteMark(t, b, newOwner) ==
    \* allocator.cc:1553-1585 under mu_
    /\ rdPc[t] = "Idle"
    /\ b \in existingBlocks /\ block[b].allocated
    /\ rdPc'        = [rdPc        EXCEPT ![t] = "Marked"]
    /\ rdBlock'     = [rdBlock     EXCEPT ![t] = b]
    /\ rdPrevOwner' = [rdPrevOwner EXCEPT ![t] = block[b].ownerStream]
    /\ rdNewOwner'  = [rdNewOwner  EXCEPT ![t] = newOwner]
    \* 1563-1565: snapshot = stream_uses \ {new} \cup (prev != new ? {prev} : {})
    /\ rdSnapshot'  = [rdSnapshot  EXCEPT ![t] =
                        (block[b].streamUses \ {newOwner})
                        \cup (IF block[b].ownerStream # newOwner
                              THEN {block[b].ownerStream} ELSE {})]
    /\ rdRecorded'  = [rdRecorded  EXCEPT ![t] = {}]
    \* 1560-1566: allocated=false; owner_stream=new; stream_uses.clear()
    /\ block' = [block EXCEPT ![b] =
                    [@ EXCEPT !.allocated   = FALSE,
                              !.ownerStream = newOwner,
                              !.streamUses  = {}]]
    /\ UNCHANGED <<existingBlocks, segPrev, segNext, byPtr, activeBlocks,
                   freeVars, reclaimVars, peVars, poolVars, fgVars, cudaVars,
                   gcVars>>

\* Immediate-reuse branch (same-stream, empty snapshot, event_count==0):
\* allocator.cc:1575-1584 — atomic coalesce + insert_free_block.
RawDeleteSameStreamFastPath(t, b, newOwner) ==
    /\ rdPc[t] = "Idle"
    /\ b \in existingBlocks /\ block[b].allocated
    /\ block[b].ownerStream = newOwner   \* 1575: prev_owner_sid == owner_sid_new
    /\ block[b].eventCount = 0
    /\ block[b].streamUses \subseteq {newOwner}
    \* under lock: allocated:=false, coalesce, insert free, erase cross.
    /\ activeBlocks' = activeBlocks \ {b}
    \* Emulate coalesce_neighbors_unlocked as a no-op (no eligible neighbor) or
    \* merge left/right via separate Coalesce actions. Here we model the direct
    \* insert without coalesce for simplicity; Coalesce action is separate.
    /\ block' = [block EXCEPT ![b] =
                    [@ EXCEPT !.allocated  = FALSE,
                              !.streamUses = {}]]
    /\ perStreamFree' = [perStreamFree EXCEPT ![newOwner] = @ \cup {b}]
    /\ UNCHANGED <<existingBlocks, segPrev, segNext, byPtr, crossStreamFree,
                   reclaimVars, rdVars, peVars, poolVars, fgVars, cudaVars,
                   gcVars>>

RawDeleteRecordOk(t) ==
    \* allocator.cc:1611-1625 off-lock: cudaEventRecord for each snapshot stream.
    /\ rdPc[t] = "Marked"
    /\ rdBlock[t] \in existingBlocks  \* phantom-state assumption
    /\ rdPc'       = [rdPc EXCEPT ![t] = "Published"]   \* tentatively move to publish-ready
    /\ rdRecorded' = [rdRecorded EXCEPT ![t] = rdSnapshot[t]]
    /\ UNCHANGED <<blockVars, freeVars, reclaimVars,
                   rdBlock, rdSnapshot, rdPrevOwner, rdNewOwner,
                   peVars, poolVars, fgVars, cudaVars, gcVars>>

RawDeleteRecordFail(t) ==
    \* failure path 1626-1653 — destroy events + rollback under lock.
    /\ rdPc[t] = "Marked"
    /\ rdBlock[t] \in existingBlocks
    /\ rdPc'    = [rdPc EXCEPT ![t] = "RolledBack"]
    \* 1631-1647 rollback: allocated:=true; owner:=prev; stream_uses += snapshot
    \* NOTE Family 3: record_stream calls during the window put stream-uses ON
    \* THE BLOCK (set empty when we got here); after rollback they are lost
    \* UNLESS they were added during the window.  In our model, block[b].streamUses
    \* is currently whatever RecordStream may have added — rollback REPLACES with
    \* snapshot, dropping those adds (the bug we model).
    /\ block' = [block EXCEPT ![rdBlock[t]] =
                    [@ EXCEPT !.allocated   = TRUE,
                              !.ownerStream = rdPrevOwner[t],
                              !.streamUses  = rdSnapshot[t]]]
    /\ UNCHANGED <<existingBlocks, segPrev, segNext, byPtr, activeBlocks,
                   freeVars, reclaimVars,
                   rdBlock, rdSnapshot, rdPrevOwner, rdNewOwner, rdRecorded,
                   peVars, poolVars, fgVars, cudaVars, gcVars>>

RawDeletePublish(t) ==
    \* allocator.cc:1656-1663 — under lock: event_count += N; push limbo.
    /\ rdPc[t] = "Published"
    /\ rdBlock[t] \in existingBlocks  \* if not, the block was freed while off-lock (F1.1 violation)
    /\ LET b == rdBlock[t] IN
         LET recorded == rdRecorded[t] IN
           /\ block' = [block EXCEPT ![b] =
                          [@ EXCEPT !.eventCount = @ + Cardinality(recorded)]]
           /\ limbo' = [sid \in Streams |->
                          IF sid \in recorded
                          THEN Append(limbo[sid],
                                      [b |-> b, token |-> limboTokenSeq + 1])
                          ELSE limbo[sid]]
           /\ limboTokenSeq' = limboTokenSeq + Cardinality(recorded)
    /\ rdPc'     = [rdPc     EXCEPT ![t] = "Idle"]
    /\ rdBlock'  = [rdBlock  EXCEPT ![t] = NullBlock]
    /\ UNCHANGED <<existingBlocks, segPrev, segNext, byPtr, activeBlocks,
                   freeVars, deferredQ,
                   rdSnapshot, rdPrevOwner, rdNewOwner, rdRecorded,
                   peVars, poolVars, fgVars, cudaVars, gcVars>>

RawDeleteFinishRollback(t) ==
    \* return to Idle after rollback; caller is expected to retry later.
    /\ rdPc[t] = "RolledBack"
    /\ rdPc'    = [rdPc    EXCEPT ![t] = "Idle"]
    /\ rdBlock' = [rdBlock EXCEPT ![t] = NullBlock]
    /\ UNCHANGED <<blockVars, freeVars, reclaimVars,
                   rdSnapshot, rdPrevOwner, rdNewOwner, rdRecorded,
                   peVars, poolVars, fgVars, cudaVars, gcVars>>

---------------------------------------------------------------------------
\* *** Deferred push (capturing stream at free time) ***
\* allocator.cc:1596-1608: if any referenced stream is capturing, push to
\* deferred_ under lock. Block keeps `allocated=false, stream_uses={}`.
\* (Also used by the deferred-push variant that transitions from Marked PC.)
---------------------------------------------------------------------------
RawDeleteToDeferred(t) ==
    /\ rdPc[t] = "Marked"
    /\ rdBlock[t] \in existingBlocks
    /\ (\/ streamCapturing[rdNewOwner[t]]
        \/ \E s \in rdSnapshot[t] : streamCapturing[s])
    /\ deferredQ' = Append(deferredQ,
                       [ b        |-> rdBlock[t],
                         ownerSid |-> rdNewOwner[t],
                         streams  |-> rdSnapshot[t] ])
    /\ rdPc'    = [rdPc    EXCEPT ![t] = "Idle"]
    /\ rdBlock' = [rdBlock EXCEPT ![t] = NullBlock]
    /\ UNCHANGED <<blockVars, freeVars, limbo, limboTokenSeq,
                   rdSnapshot, rdPrevOwner, rdNewOwner, rdRecorded,
                   peVars, poolVars, fgVars, cudaVars, gcVars>>

---------------------------------------------------------------------------
\* *** process_events — deferred-flush phase (3-step, Family 2) ***
\*
\* Code (allocator.cc:1692-1738):
\*   A) {mu_ held}   cands = snapshot(deferred_);                   (1696-1700)
\*   B) {mu_ released} for each df: cudaEventRecord for df.streams  (1708-1721)
\*   C) {mu_ held}   erase first deferred_ entry with b == df.b;
\*                   push limbo entries; event_count += N.          (1727-1737)
\*
\* Steps (A) and (C) run under lock but there is NO `pe_in_progress` flag —
\* two concurrent process_events threads can overlap these steps, producing
\* duplicate limbo entries (brief §F2).
---------------------------------------------------------------------------
PeSnapshot(t) ==
    \* allocator.cc:1696-1700 under mu_
    /\ pePc[t] = "Idle"
    /\ pePc'    = [pePc    EXCEPT ![t] = "Snapshotted"]
    /\ peCands' = [peCands EXCEPT ![t] = deferredQ]
    /\ peIdx'   = [peIdx   EXCEPT ![t] = 1]
    /\ peRecorded' = [peRecorded EXCEPT ![t] = {}]
    /\ UNCHANGED <<blockVars, freeVars, reclaimVars, rdVars,
                   poolVars, fgVars, cudaVars, gcVars>>

PeSkipCapturing(t) ==
    \* 1701-1706: if still capturing, continue (move to next df)
    /\ pePc[t] = "Snapshotted"
    /\ peIdx[t] >= 1 /\ peIdx[t] <= Len(peCands[t])
    /\ LET df == peCands[t][peIdx[t]] IN
         \/ streamCapturing[df.ownerSid]
         \/ \E s \in df.streams : streamCapturing[s]
    /\ peIdx' = [peIdx EXCEPT ![t] = @ + 1]
    /\ UNCHANGED <<blockVars, freeVars, reclaimVars, rdVars,
                   pePc, peCands, peRecorded,
                   poolVars, fgVars, cudaVars, gcVars>>

PeRecordOk(t) ==
    \* 1708-1721 off-lock
    /\ pePc[t] = "Snapshotted"
    /\ peIdx[t] >= 1 /\ peIdx[t] <= Len(peCands[t])
    /\ LET df == peCands[t][peIdx[t]] IN
         /\ ~ streamCapturing[df.ownerSid]
         /\ \A s \in df.streams : ~ streamCapturing[s]
         /\ peRecorded' = [peRecorded EXCEPT ![t] = df.streams]
    /\ pePc' = [pePc EXCEPT ![t] = "Recorded"]
    /\ UNCHANGED <<blockVars, freeVars, reclaimVars, rdVars,
                   peCands, peIdx, poolVars, fgVars, cudaVars, gcVars>>

PeRecordFail(t) ==
    \* 1722-1725 — destroy pendings, try next df
    /\ pePc[t] = "Snapshotted"
    /\ peIdx[t] >= 1 /\ peIdx[t] <= Len(peCands[t])
    /\ peIdx' = [peIdx EXCEPT ![t] = @ + 1]
    /\ UNCHANGED <<blockVars, freeVars, reclaimVars, rdVars,
                   pePc, peCands, peRecorded, poolVars, fgVars,
                   cudaVars, gcVars>>

PePublish(t) ==
    \*
    \* allocator.cc:1727-1737 under mu_.
    \* Linear search erase of the matching df-by-block from deferredQ, then
    \* unconditional push to limbo.  If another concurrent process_events
    \* already erased this entry, the erase becomes a no-op but the push
    \* still fires — Family 2 bug.
    \*
    /\ pePc[t] = "Recorded"
    /\ peIdx[t] >= 1 /\ peIdx[t] <= Len(peCands[t])
    /\ LET df == peCands[t][peIdx[t]] IN
         LET matchIdx == IF \E i \in 1..Len(deferredQ) : deferredQ[i].b = df.b
                         THEN CHOOSE i \in 1..Len(deferredQ) : deferredQ[i].b = df.b
                         ELSE 0 IN
         /\ deferredQ' = IF matchIdx = 0 THEN deferredQ ELSE SeqExcept(deferredQ, matchIdx)
         \* Publish UNCONDITIONALLY — the bug surface.
         /\ IF df.b \in existingBlocks
            THEN /\ block' = [block EXCEPT ![df.b] =
                                [@ EXCEPT !.eventCount =
                                           @ + Cardinality(peRecorded[t])]]
                 /\ limbo' = [sid \in Streams |->
                                IF sid \in peRecorded[t]
                                THEN Append(limbo[sid],
                                            [b |-> df.b, token |-> limboTokenSeq + 1])
                                ELSE limbo[sid]]
                 /\ limboTokenSeq' = limboTokenSeq + Cardinality(peRecorded[t])
            ELSE \* block already reclaimed — ghost entries would be created; audit
                 /\ limbo' = [sid \in Streams |->
                                IF sid \in peRecorded[t]
                                THEN Append(limbo[sid],
                                            [b |-> df.b, token |-> limboTokenSeq + 1])
                                ELSE limbo[sid]]
                 /\ limboTokenSeq' = limboTokenSeq + Cardinality(peRecorded[t])
                 /\ UNCHANGED block
    /\ pePc'  = [pePc  EXCEPT ![t] = "Snapshotted"]
    /\ peIdx' = [peIdx EXCEPT ![t] = @ + 1]
    /\ peRecorded' = [peRecorded EXCEPT ![t] = {}]
    /\ UNCHANGED <<existingBlocks, segPrev, segNext, byPtr, activeBlocks,
                   freeVars, rdVars, peCands,
                   poolVars, fgVars, cudaVars, gcVars>>

PeLoopDone(t) ==
    /\ pePc[t] = "Snapshotted"
    /\ peIdx[t] > Len(peCands[t])
    /\ pePc'    = [pePc    EXCEPT ![t] = "Idle"]
    /\ peCands' = [peCands EXCEPT ![t] = <<>>]
    /\ peIdx'   = [peIdx   EXCEPT ![t] = 0]
    /\ peRecorded' = [peRecorded EXCEPT ![t] = {}]
    /\ UNCHANGED <<blockVars, freeVars, reclaimVars, rdVars,
                   poolVars, fgVars, cudaVars, gcVars>>

---------------------------------------------------------------------------
\* *** process_events — limbo drain (head-of-line event query) ***
\* allocator.cc:1740-1802. Single reactive action per stream: peek head,
\* off-lock query (abstracted as non-deterministic ready choice), pop if ready,
\* decrement event_count, and on event_count -> 0 coalesce + insert.
\*
\* Modeled as two atomic steps: PeHeadReady (flips head to ready nondet) and
\* PePop (atomic pop + optional reinsertion).
---------------------------------------------------------------------------
PePopReady(sid) ==
    /\ ~ streamCapturing[sid]
    /\ Len(limbo[sid]) > 0
    /\ LET entry == limbo[sid][1] IN
         LET b == entry.b IN
           /\ limbo' = [limbo EXCEPT ![sid] = Tail(@)]
           /\ ghostDangling' = IF b \in existingBlocks
                               THEN ghostDangling
                               ELSE ghostDangling \cup {b}
           /\ IF b \in existingBlocks
              THEN /\ block' = [block EXCEPT ![b] =
                                  [@ EXCEPT !.eventCount =
                                             IF @ > 0 THEN @ - 1 ELSE 0]]
                                \* 1790 guard masks underflow (F2 symptom)
                   /\ IF  block[b].eventCount - 1 <= 0
                           /\ ~ block'[b].allocated
                      THEN \* 1791-1796 coalesce + insert free
                           /\ activeBlocks' = activeBlocks \ {b}
                           /\ perStreamFree' =
                                [perStreamFree EXCEPT ![block'[b].ownerStream] = @ \cup {b}]
                           /\ UNCHANGED <<crossStreamFree>>
                      ELSE /\ UNCHANGED <<activeBlocks, freeVars>>
              ELSE \* b was already delete'd by an earlier coalesce/detach
                   /\ UNCHANGED <<block, activeBlocks, freeVars>>
    /\ UNCHANGED <<existingBlocks, segPrev, segNext, byPtr, deferredQ,
                   limboTokenSeq, rdVars, peVars, poolVars, fgVars, cudaVars,
                   gcPasses>>

---------------------------------------------------------------------------
\* *** Coalesce neighbors (standalone action, Family 1) ***
\*
\* Full coalesce_neighbors_unlocked logic (allocator.cc:3693-3881):
\*   - not split_enabled? no-op
\*   - oversize block? no-op
\*   - try left-merge with eligible_neighbor (3800-3822)
\*   - stop if merged head became oversize (3825-3840)
\*   - try right-merge (3842-3861)
\*   - normalize head (3863-3878)
\*
\* This action models the left-merge arm.  **The bug** (F1): eligible_neighbor
\* does not check whether n is in per_stream_free_ or cross_stream_free_ —
\* a block that is deferred_ / in-flight-delete / in limbo can be "eligible"
\* and will be deleted by the merge.
\*
\* Triggered from: insert_free_block_unlocked's fast path (1578-1579), and
\* from process_events pop (1794).  Modeled as a standalone fault-injection
\* action to explore interleavings.
---------------------------------------------------------------------------
CoalesceLeft(b) ==
    /\ b \in existingBlocks
    /\ ~ block[b].allocated
    /\ block[b].eventCount = 0
    /\ block[b].streamUses = {}
    /\ LET left == segPrev[b] IN
         /\ left # NullBlock
         /\ EligibleNeighbor(left, b)   \* BUG-CARRYING PREDICATE (F1)
         \* 3811-3815 rewire: left.size += b.size; left.next = b.next
         /\ segNext' = [segNext EXCEPT ![left] = segNext[b]]
         /\ segPrev' = IF segNext[b] # NullBlock
                       THEN [segPrev EXCEPT ![segNext[b]] = left]
                       ELSE segPrev
         \* 3817-3818 by_ptr_.erase(head->ptr); delete head
         /\ byPtr' = byPtr \ {b}
         /\ existingBlocks' = existingBlocks \ {b}
         /\ activeBlocks' = activeBlocks \ {b}
         /\ perStreamFree' = [sid \in Streams |-> perStreamFree[sid] \ {b}]
         /\ crossStreamFree' = crossStreamFree \ {b}
         \* If b was referenced by deferredQ/limbo/rd/pe, this is dangling.
         /\ ghostDangling' = ghostDangling \cup
               (IF ReferencedByQueues(b) THEN {b} ELSE {})
    /\ UNCHANGED <<block, reclaimVars, rdVars, peVars, poolVars, fgVars,
                   cudaVars, gcPasses>>

CoalesceRight(b) ==
    /\ b \in existingBlocks
    /\ ~ block[b].allocated
    /\ block[b].eventCount = 0
    /\ block[b].streamUses = {}
    /\ LET right == segNext[b] IN
         /\ right # NullBlock
         /\ EligibleNeighbor(right, b)  \* BUG-CARRYING PREDICATE (F1)
         /\ segNext' = [segNext EXCEPT ![b] = segNext[right]]
         /\ segPrev' = IF segNext[right] # NullBlock
                       THEN [segPrev EXCEPT ![segNext[right]] = b]
                       ELSE segPrev
         /\ byPtr' = byPtr \ {right}
         /\ existingBlocks' = existingBlocks \ {right}
         /\ activeBlocks' = activeBlocks \ {right}
         /\ perStreamFree' = [sid \in Streams |-> perStreamFree[sid] \ {right}]
         /\ crossStreamFree' = crossStreamFree \ {right}
         /\ ghostDangling' = ghostDangling \cup
               (IF ReferencedByQueues(right) THEN {right} ELSE {})
    /\ UNCHANGED <<block, reclaimVars, rdVars, peVars, poolVars, fgVars,
                   cudaVars, gcPasses>>

---------------------------------------------------------------------------
\* *** GC: run_gc_pass_if_eligible / emptyCache ***
\*
\* allocator.cc:1811-2080 (gc) and 2082-2138 (emptyCache).
\* Under lock: find_candidate_heads_locked walks every free block up to its
\* segment head, and checks each block on the chain with the BUG predicate
\* (graph_pool_id==0 & !allocated & event_count==0). A phantom block (deferred
\* or raw_delete window) passes this predicate.
\*
\* detach_segment_for_gc_locked then `delete`s every block on the chain and
\* removes them from by_ptr_/active_blocks_ — this is where the dangling
\* happens when the chain contains a phantom-free block that is still
\* referenced by deferredQ or a live raw_delete off-lock window.
---------------------------------------------------------------------------
GcDetachIdleSegment(h) ==
    /\ h \in existingBlocks
    /\ IdleSegment(h)  \* bug-carrying predicate (F1: no deferred/limbo check)
    /\ LET chain == SegmentMembers(h) IN
         /\ existingBlocks' = existingBlocks \ chain
         /\ byPtr'          = byPtr \ chain
         /\ activeBlocks'   = activeBlocks \ chain
         /\ perStreamFree'  = [sid \in Streams |-> perStreamFree[sid] \ chain]
         /\ crossStreamFree' = crossStreamFree \ chain
         \* Clear segPrev/segNext for detached blocks so stale pointers don't
         \* leak into subsequent allocations / splits.
         /\ segPrev' = [b \in BlockIds |-> IF b \in chain THEN NullBlock ELSE segPrev[b]]
         /\ segNext' = [b \in BlockIds |-> IF b \in chain THEN NullBlock ELSE segNext[b]]
         /\ reservedBytes'  = IF reservedBytes > Cardinality(chain)
                              THEN reservedBytes - Cardinality(chain) ELSE 0
         /\ gcPasses' = gcPasses + 1
         /\ ghostDangling' = ghostDangling \cup
               { b \in chain : ReferencedByQueues(b) }
    /\ UNCHANGED <<block, reclaimVars, rdVars, peVars, poolVars,
                   fgPc, fgReservedSnap, fgLimitSnap, fractionBreaches,
                   fractionMisfires, cudaVars>>

---------------------------------------------------------------------------
\* *** Graph-pool lifecycle (Family 4) ***
\*
\* allocator.cc:826-977 + 1128-1135 (guard).
\* Modeled as separate actions for each mutation site because the TLS/flag/
\* refcount updates happen in different orders depending on entry point.
\*
\* BeginCapture flat:     883-888
\*   1. (locked)   gp.active_capture_count = 1u  (asymmetric inc)
\*   2. (locked)   gp.begins += 1
\*   3. (after lock) s_capture_tls = {active, id}
\*   4. (after lock) routing_active_flag_ = true
\*   5. returns an AllocateToPoolGuard owning `id` (outstanding until dtor)
\*
\* EndCaptureFlat: 891-913
\*   1. clear TLS (if matches)
\*   2. routing_active_flag_ = false   ← CLEARS UNCONDITIONALLY
\*   3. (locked) gp.active_capture_count = 0
\*
\* GuardDestruct: 1131-1135 — unconditionally calls cancel_allocate_to_pool_
\*   cancel: same as EndCaptureFlat but stats-wise a cancel (1:916-937)
\*
\* BUG (F4): sequence: [Begin, EndFlat, Begin2, GuardDestruct(from Begin1)]
\*   disarms the freshly-begun capture's TLS and routingFlag.
---------------------------------------------------------------------------
BeginCapture(t, id) ==
    /\ poolOpsTotal < MaxPoolOps
    /\ id \in PoolIds /\ id # DefaultPool
    /\ ~ tls[t].active
    /\ poolState[id].activeCap = 0
    /\ poolState[id].activeRep = 0
    /\ poolState[id].prewarm   = 0
    /\ poolState' = [poolState EXCEPT ![id] =
                        [@ EXCEPT !.activeCap = 1]]   \* 880: = 1u (asymmetric)
    /\ tls'         = [tls EXCEPT ![t] = [active |-> TRUE, pool |-> id]]
    /\ routingFlag' = TRUE
    /\ guardOwners' = guardOwners \cup {<<t, id>>}
    /\ poolOpsTotal' = poolOpsTotal + 1
    /\ UNCHANGED <<blockVars, freeVars, reclaimVars, rdVars, peVars,
                   fgVars, cudaVars, gcVars>>

EndCaptureFlat(t, id) ==
    /\ poolOpsTotal < MaxPoolOps
    /\ id # DefaultPool
    \* flat API: does NOT necessarily match the RAII guard owner
    /\ tls[t].active /\ tls[t].pool = id =>
         tls' = [tls EXCEPT ![t] = [active |-> FALSE, pool |-> DefaultPool]]
    /\ (~(tls[t].active /\ tls[t].pool = id)) => UNCHANGED tls
    /\ routingFlag' = FALSE            \* 898: unconditionally clears
    /\ poolState' = [poolState EXCEPT ![id] =
                        [@ EXCEPT !.activeCap = IF @ > 0 THEN 0 ELSE 0]]
    /\ poolOpsTotal' = poolOpsTotal + 1
    /\ UNCHANGED <<blockVars, freeVars, reclaimVars, rdVars, peVars,
                   guardOwners, fgVars, cudaVars, gcVars>>

GuardDestruct(t, id) ==
    \* allocator.cc:1131-1135 — dtor calls cancel_allocate_to_pool_ unconditionally.
    \* 915-937: cancel path clears TLS + routing + active_capture_count.
    /\ poolOpsTotal < MaxPoolOps
    /\ <<t, id>> \in guardOwners
    /\ guardOwners' = guardOwners \ {<<t, id>>}
    /\ (tls[t].active /\ tls[t].pool = id) =>
         tls' = [tls EXCEPT ![t] = [active |-> FALSE, pool |-> DefaultPool]]
    /\ (~(tls[t].active /\ tls[t].pool = id)) => UNCHANGED tls
    /\ routingFlag' = FALSE            \* 922: unconditionally clears (BUG surface)
    /\ poolState' = [poolState EXCEPT ![id] =
                        [@ EXCEPT !.activeCap = 0]]
    /\ poolOpsTotal' = poolOpsTotal + 1
    /\ UNCHANGED <<blockVars, freeVars, reclaimVars, rdVars, peVars,
                   fgVars, cudaVars, gcVars>>

RetainPool(t, id) ==
    /\ id # DefaultPool
    /\ poolState' = [poolState EXCEPT ![id] =
                        [@ EXCEPT !.refcnt = @ + 1]]
    /\ UNCHANGED <<blockVars, freeVars, reclaimVars, rdVars, peVars,
                   tls, routingFlag, guardOwners, poolOpsTotal,
                   fgVars, cudaVars, gcVars>>

ReleasePool(t, id) ==
    /\ id # DefaultPool
    /\ poolState[id].refcnt > 0
    /\ poolState' = [poolState EXCEPT ![id] =
                        [@ EXCEPT !.refcnt = @ - 1]]
    /\ UNCHANGED <<blockVars, freeVars, reclaimVars, rdVars, peVars,
                   tls, routingFlag, guardOwners, poolOpsTotal,
                   fgVars, cudaVars, gcVars>>

---------------------------------------------------------------------------
\* *** Fraction cap gate (Family 5) ***
\*
\* allocator.cc:338-450 maybe_run_fraction_gate.  Modeled as:
\*   PassGate(t):  samples reservedBytes + limit, decides whether to proceed
\*   BumpReserved(t):  the caller's post-gate cudaMalloc; adds to reserved
\*
\* Two threads can both PassGate while seeing reservedBytes < limit, then both
\* BumpReserved, overshooting the limit.  No counter reflects the overshoot
\* (F5 bug).
---------------------------------------------------------------------------
PassGate(t) ==
    /\ fgPc[t] = "Idle"
    /\ fgLimitSnap'    = [fgLimitSnap EXCEPT ![t] = FractionLimit]
    /\ fgReservedSnap' = [fgReservedSnap EXCEPT ![t] = reservedBytes]
    /\ fgPc' = [fgPc EXCEPT ![t] =
                  IF reservedBytes + 1 > FractionLimit THEN "GCDone" ELSE "PastGate"]
    \* 370: fraction_cap_breaches += 1 when cap is exceeded on entry
    /\ fractionBreaches' =
         IF reservedBytes + 1 > FractionLimit
         THEN fractionBreaches + 1 ELSE fractionBreaches
    /\ UNCHANGED <<blockVars, freeVars, reclaimVars, rdVars, peVars, poolVars,
                   reservedBytes, fractionMisfires, cudaVars, gcVars>>

PassGateRetryMisfire(t) ==
    \* 439-446 — after GC+emptyCache still overshoots -> misfire
    /\ fgPc[t] = "GCDone"
    /\ reservedBytes + 1 > fgLimitSnap[t]
    /\ fractionMisfires' = fractionMisfires + 1
    /\ fgPc' = [fgPc EXCEPT ![t] = "Idle"]
    /\ UNCHANGED <<blockVars, freeVars, reclaimVars, rdVars, peVars, poolVars,
                   reservedBytes, fgReservedSnap, fgLimitSnap, fractionBreaches,
                   cudaVars, gcVars>>

PassGateRecovered(t) ==
    /\ fgPc[t] = "GCDone"
    /\ reservedBytes + 1 <= fgLimitSnap[t]
    /\ fgPc' = [fgPc EXCEPT ![t] = "PastGate"]
    /\ UNCHANGED <<blockVars, freeVars, reclaimVars, rdVars, peVars, poolVars,
                   reservedBytes, fgReservedSnap, fgLimitSnap,
                   fractionBreaches, fractionMisfires, cudaVars, gcVars>>

\* BumpReserved is rolled into RawAllocNewBlock (see `reservedBytes + 1`).

---------------------------------------------------------------------------
\* *** emptyCache (user-visible) ***
\* allocator.cc:2082-2138. Wraps detach for every idle head.
---------------------------------------------------------------------------
EmptyCache ==
    /\ \E h \in existingBlocks :
         /\ IdleSegment(h)
         /\ GcDetachIdleSegment(h)

---------------------------------------------------------------------------
\* Next
---------------------------------------------------------------------------
Next ==
    \/ \E t \in Threads, sid \in Streams, pool \in PoolIds :
         RawAllocNewBlock(t, sid, pool)
    \/ \E t \in Threads, sid \in Streams, pool \in PoolIds :
         RawAllocReuseFromFreeList(t, sid, pool)
    \/ \E t \in Threads, sid \in Streams : RawAllocReuseFromCross(t, sid)
    \/ \E b \in BlockIds : Split(b)
    \/ \E t \in Threads, b \in BlockIds, s \in Streams : RecordStream(t, b, s)
    \/ \E t \in Threads, b \in BlockIds, s \in Streams : RawDeleteMark(t, b, s)
    \/ \E t \in Threads, b \in BlockIds, s \in Streams : RawDeleteSameStreamFastPath(t, b, s)
    \/ \E t \in Threads : RawDeleteRecordOk(t)
    \/ \E t \in Threads : RawDeleteRecordFail(t)
    \/ \E t \in Threads : RawDeletePublish(t)
    \/ \E t \in Threads : RawDeleteFinishRollback(t)
    \/ \E t \in Threads : RawDeleteToDeferred(t)
    \/ \E t \in Threads : PeSnapshot(t)
    \/ \E t \in Threads : PeSkipCapturing(t)
    \/ \E t \in Threads : PeRecordOk(t)
    \/ \E t \in Threads : PeRecordFail(t)
    \/ \E t \in Threads : PePublish(t)
    \/ \E t \in Threads : PeLoopDone(t)
    \/ \E sid \in Streams : PePopReady(sid)
    \/ \E b \in BlockIds : CoalesceLeft(b)
    \/ \E b \in BlockIds : CoalesceRight(b)
    \/ \E h \in BlockIds : GcDetachIdleSegment(h)
    \/ EmptyCache
    \/ \E t \in Threads, id \in PoolIds : BeginCapture(t, id)
    \/ \E t \in Threads, id \in PoolIds : EndCaptureFlat(t, id)
    \/ \E t \in Threads, id \in PoolIds : GuardDestruct(t, id)
    \/ \E t \in Threads, id \in PoolIds : RetainPool(t, id)
    \/ \E t \in Threads, id \in PoolIds : ReleasePool(t, id)
    \/ \E t \in Threads : PassGate(t)
    \/ \E t \in Threads : PassGateRetryMisfire(t)
    \/ \E t \in Threads : PassGateRecovered(t)
    \/ \E s \in Streams : StreamCaptureStart(s)
    \/ \E s \in Streams : StreamCaptureEnd(s)
    \/ MallocFlipToFail
    \/ MallocFlipToOk

Spec == Init /\ [][Next]_vars

\* =========================================================================
\* INVARIANTS
\* =========================================================================

\* -- Standard safety properties -------------------------------------------

\* Every block field access goes through existingBlocks; no variable should
\* refer to a deleted BlockId.
TypeOK ==
    /\ existingBlocks \subseteq BlockIds
    /\ byPtr \subseteq existingBlocks
    /\ activeBlocks \subseteq existingBlocks
    /\ \A sid \in Streams : perStreamFree[sid] \subseteq existingBlocks
    /\ crossStreamFree \subseteq existingBlocks

\* Allocated blocks are in activeBlocks; free-list blocks are not allocated.
FreeListConsistency ==
    /\ \A b \in existingBlocks :
         block[b].allocated => (b \in activeBlocks \/ \E t \in Threads : rdBlock[t] = b /\ rdPc[t] = "RolledBack")
    /\ \A sid \in Streams : \A b \in perStreamFree[sid] :
         ~ block[b].allocated
    /\ \A b \in crossStreamFree : ~ block[b].allocated

NoDoubleFree ==
    \* Each block may be in an in-progress free at most once. "RolledBack" is
    \* excluded — rollback has already restored block.allocated=TRUE, so another
    \* thread validly begins raw_delete before the first thread hits
    \* FinishRollback and clears rdBlock.
    \A b \in BlockIds : Cardinality({t \in Threads : rdBlock[t] = b
                                                  /\ rdPc[t] \in {"Marked",
                                                                   "RecordFailed",
                                                                   "Published"}}) <= 1

\* -- Extension invariants (bug-family targets) ----------------------------

\* Family 1.1: during raw_delete off-lock window, the block must still exist.
\* ViolatedIF: Coalesce or GCDetach delete the phantom-free block during the window.
NoDanglingInFlight ==
    \A t \in Threads :
      (rdPc[t] \in {"Marked", "Published"}) => rdBlock[t] \in existingBlocks

\* Family 1.2: block referenced by deferredQ must still exist.
NoDanglingDeferred ==
    \A i \in 1..Len(deferredQ) : deferredQ[i].b \in existingBlocks

\* Family 1, 2: block referenced by limbo must still exist.
NoDanglingLimbo ==
    \A sid \in Streams : \A i \in 1..Len(limbo[sid]) :
      limbo[sid][i].b \in existingBlocks

\* Audit: no block should be placed in ghostDangling.
NoGhostDangling == ghostDangling = {}

\* Family 2: no deferredQ entry should be reflected in limbo more than once per
\* (stream, block) pair. Approximation: count limbo entries per block; each
\* block's total event_count should equal the number of live limbo entries for
\* that block.
EventCountConsistent ==
    \A b \in existingBlocks :
      block[b].eventCount =
        Cardinality({ <<sid, i>> \in Streams \X (1..100) :
                        i <= Len(limbo[sid]) /\ limbo[sid][i].b = b })
                                      \* bounded by 100 per stream; MC limits much smaller

\* Family 3: during a raw_delete window a RecordStream concurrent with it
\* must survive rollback.  We track this by requiring that if any thread is in
\* Marked/Published PC with block b and another thread calls RecordStream(b,s),
\* then after any rollback the stream s is either in snapshot (will be restored)
\* or in a subsequent publish's pendings.
\* Simplified form: if block b ever has rollback fire while b.streamUses had
\* streams added during the window, those streams must remain in b.streamUses.
\* (Encoded indirectly: the rollback uses the pre-window snapshot and ignores
\*  any intervening inserts -> invariant holds WITH BUG when RecordStream fired.)
\* Here we require streamUses conservatism: if rollback restores, any stream
\* the record added is lost.  Violation detection is done by an auxiliary
\* variable tracking "recordedDuringWindow" and the bug is the invariant
\* being violatable post-rollback.
\*
\* StreamUsesPersist is modeled as: after RawDeleteFinishRollback, streamUses
\* must include everything that was in streamUses at any point during the
\* window.  We encode it via a ghost `windowObserved` variable in MC spec.

\* Family 4:
\* routing_active_flag_ must be TRUE iff some thread has TLS active with
\* a capturing pool.
RoutingFlagMatchesTLS ==
    routingFlag <=>
      \E t \in Threads :
        /\ tls[t].active
        /\ poolState[tls[t].pool].activeCap > 0

\* Family 4 (counter well-formedness):
PoolRefcntWellFounded ==
    \A p \in PoolIds : poolState[p].refcnt >= 0

\* Family 5:
ReservedLimitRespected ==
    reservedBytes <= FractionLimit \/ fractionBreaches > 0 \/ fractionMisfires > 0

\* Segment chain structural invariant
SegmentChainWellFormed ==
    \A b \in existingBlocks :
      /\ (segPrev[b] # NullBlock => segNext[segPrev[b]] = b)
      /\ (segNext[b] # NullBlock => segPrev[segNext[b]] = b)

\* -- Liveness / temporal (liveness marker only; defined in MC.tla) --------

==============================================================================
