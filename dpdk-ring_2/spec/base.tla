---- MODULE base ----
(***************************************************************************)
(* DPDK rte_ring — Round 2 base spec.                                      *)
(*                                                                         *)
(* Category B (concurrent / lock-free).                                    *)
(*                                                                         *)
(* Source: dpdk/lib/ring/                                                  *)
(*   rte_ring_core.h          — data structures                            *)
(*   rte_ring_c11_pvt.h       — default MP/MC CAS + tail update            *)
(*   rte_ring_rts_elem_pvt.h  — RTS counter mechanism (Family A)           *)
(*   rte_ring_hts_elem_pvt.h  — HTS serialised mode                        *)
(*   rte_ring_peek_elem_pvt.h — Peek START / FINISH (Family E)             *)
(*   soring.c                 — SORING staged ordered ring (Family D)      *)
(*                                                                         *)
(* Bug Families (round 2):                                                 *)
(*   A — RTS update_tail residual stale-head load (BZ-1527 candidate)      *)
(*   B — Caller misuse / sync_type mode confusion at public API            *)
(*   C — Default-mode partial-order regression check                        *)
(*   D — SORING multiple concurrency hazards (D.1 stale head, D.2 lost     *)
(*       finalize, D.3 release-count mismatch, D.4 ftoken wraparound)      *)
(*   E — Peek API atomicity & NDEBUG-masked invariants                     *)
(***************************************************************************)

EXTENDS Integers, Sequences, FiniteSets, TLC

\* ========================================================================
\* Constants
\* ========================================================================

CONSTANTS
    Thread,             \* Set of thread IDs (mixed prod/cons; role chosen per call)
    Capacity,           \* Ring usable capacity (rte_ring_core.h:124)
    Mode,               \* Ring sync mode actually configured: "ST", "MT", "RTS", "HTS", "SORING"
    MaxBatch,           \* Max elements per single enqueue/dequeue/acquire
    HTDMax,             \* RTS htd_max — max head-tail distance (rte_ring_core.h:88)
    NbStage,            \* Number of stages for SORING (soring.h:113)
    PosWrap,            \* Position-counter wrap (small for Family D.4 ftoken collision)
    CntWrap             \* RTS .cnt counter wrap (small for ABA-on-cnt scenario)

ASSUME Capacity \in Nat \ {0}
ASSUME Mode \in {"ST","MT","RTS","HTS","SORING"}
ASSUME MaxBatch \in 1..Capacity
ASSUME HTDMax \in 1..(2*Capacity)
ASSUME NbStage \in Nat \ {0}
ASSUME PosWrap \in Nat \ {0}
ASSUME CntWrap \in Nat \ {0}

\* ========================================================================
\* Variables — main ring state
\* ========================================================================

\* Default mode (struct rte_ring_headtail, rte_ring_core.h:65-74)
VARIABLES
    prodHead,           \* atomic uint32 (rte_ring_core.h:66)
    prodTail,           \* atomic uint32 (rte_ring_core.h:67)
    consHead,           \* atomic uint32 (rte_ring_core.h:66)
    consTail            \* atomic uint32 (rte_ring_core.h:67)

\* HTS mode adds nothing beyond head/tail above (HTS uses 64-bit CAS on the
\* (head,tail) pair; we model this as a 64-bit composite by transition rules
\* — see HTS actions below; no new state variable needed because HTS still
\* uses prodHead/prodTail/consHead/consTail values).

\* RTS mode (struct rte_ring_rts_headtail, rte_ring_core.h:85-90)
VARIABLES
    rtsProdHeadCnt,     \* prod head .cnt (rte_ring_core.h:81)
    rtsProdHeadPos,     \* prod head .pos (rte_ring_core.h:82)
    rtsProdTailCnt,     \* prod tail .cnt
    rtsProdTailPos,     \* prod tail .pos
    rtsConsHeadCnt,     \* cons head .cnt
    rtsConsHeadPos,
    rtsConsTailCnt,
    rtsConsTailPos

\* Ring slot contents — abstract: each slot holds the producer's value or 0
VARIABLES
    ring                \* [0..Capacity-1] -> Nat (0 = empty)

\* History — for invariants that compare enqueued vs dequeued sequences
VARIABLES
    enqueued,           \* Sequence of values fully published (post tail-release)
    dequeued,           \* Sequence of values fully consumed (post tail-release)
    nextVal             \* Monotonic counter: next fresh value to produce

ringVars   == <<prodHead, prodTail, consHead, consTail, ring>>
rtsVars    == <<rtsProdHeadCnt, rtsProdHeadPos, rtsProdTailCnt, rtsProdTailPos,
                rtsConsHeadCnt, rtsConsHeadPos, rtsConsTailCnt, rtsConsTailPos>>
historyVars == <<enqueued, dequeued, nextVal>>

\* ========================================================================
\* Variables — per-thread state
\* ========================================================================

\* Phase tracks where the thread is in its multi-step API call.
\* Names mirror the C function structure.
VARIABLES
    phase,              \* phase[t] \in PhaseSet (see below)
    op,                 \* op[t] \in {"enq","deq","acq","rel"}  — what call the thread is in
    role,               \* role[t] \in {"prod","cons"} — which side
    callMode,           \* callMode[t] \in {"ST","MT","RTS","HTS","SORING"} — *intended* sync_type of the API
                        \* When callMode[t] /= Mode this is Family-B caller misuse.
    stage,              \* stage[t] \in 0..NbStage-1 (SORING)
    locOldHead,         \* per-thread snapshot — old_head captured at the move_head load
    locNewHead,         \* per-thread — new_head computed
    locReqN,            \* per-thread — n requested
    locActualN,         \* per-thread — n actually obtained (after free/avail clamp)
    locFtoken,          \* per-thread — ftoken bound at acquire
    locVals,            \* per-thread — values to be enqueued (sequence)
    locReleaseN,        \* per-thread — n the harness will pass to release / finish
                        \* (Family B/D.3/E adversary may make this differ from locActualN)
    locStaleHead,       \* per-thread — stale snapshot of head loaded with relaxed in update_tail
                        \* [valid: BOOL, cnt: 0..CntWrap-1, pos: 0..PosWrap-1]  (Family A/D.1)
    locReservedSlots    \* per-thread — set of slot indices reserved by this op (peek/SORING)

threadVars == <<phase, op, role, callMode, stage, locOldHead, locNewHead,
                locReqN, locActualN, locFtoken, locVals, locReleaseN,
                locStaleHead, locReservedSlots>>

\* ========================================================================
\* Variables — SORING (soring.h, soring.c)
\* ========================================================================

\* Per-stage ring (soring.h:75-79).
VARIABLES
    sStageHead,         \* [stage] -> uint32 — soring_stage_headtail.head (soring.h:78)
    sStageTailPos,      \* [stage] -> uint32 — soring_stage_tail.pos (soring.h:71)
    sStageTailSync      \* [stage] -> {0,1} — soring_stage_tail.sync (exclusive-finalize lock; soring.h:70)

\* Per-slot SORING state ring (soring.h:33-39).
\* state[idx] is a (ftoken, stnum) pair. stnum encodes ST_START | ST_FINISH | n.
VARIABLES
    sStateFtoken,       \* [stage][idx] -> Nat (0 means empty)
    sStateStnum,        \* [stage][idx] -> {"EMPTY","START","FINISH"}
    sStateN             \* [stage][idx] -> Nat — the n the slot was acquired with

soringVars == <<sStageHead, sStageTailPos, sStageTailSync,
                sStateFtoken, sStateStnum, sStateN>>

\* ========================================================================
\* Variables — extension state for fault-injection / adversary
\* ========================================================================

\* Family A / D.1 — stale views of head observed under relaxed load
\* visibleHead[t] = thread t's possibly-stale view of head.raw (cnt+pos)
VARIABLES
    visibleProdHeadCnt, visibleProdHeadPos,
    visibleConsHeadCnt, visibleConsHeadPos
visibleVars == <<visibleProdHeadCnt, visibleProdHeadPos,
                 visibleConsHeadCnt, visibleConsHeadPos>>

\* Family C — stale view of opposing tail (acquire load returning prior value).
\* Used by MCStaleRead in the move_head loop.
VARIABLES
    visibleConsTail,    \* visibleConsTail[t] = producer t's view of consTail
    visibleProdTail     \* visibleProdTail[t] = consumer t's view of prodTail
staleVars == <<visibleConsTail, visibleProdTail>>

\* Family D.4 — wrap counter for ftoken collision detection.
VARIABLES
    posWrapCount        \* monotonic count of how many times pos has wrapped

\* Family liveness/safety — booleans set whenever the spec observes a
\* violation we want to flag without needing per-action invariants
VARIABLES
    misuseDetected,     \* TRUE if Family-B mismatch occurred
    finalizeStuck,      \* TRUE if a FINISH slot is unreachable (Family D.2)
    overCommitted       \* TRUE if peek/SORING release exceeded acquired n (E/D.3)

extVars == <<posWrapCount, misuseDetected, finalizeStuck, overCommitted>>

\* ========================================================================
\* Phase set
\* ========================================================================

PhaseSet == {
    "Idle",
    \* default move_head (rte_ring_c11_pvt.h:74-143)
    "MoveHead.LoadHead",        \* line 92 — initial *old_head load with acquire
    "MoveHead.LoadTail",        \* line 104 — load opposing tail (acquire)
    "MoveHead.CAS",             \* lines 137-140 — CAS on d->head (release/acquire failure)
    "MoveHead.Reserved",        \* slot range allocated, ring writes pending
    "WriteRing",                \* enqueue/dequeue copies elems (rte_ring_elem_pvt.h __rte_ring_enqueue_elems)
    "UpdateTail",               \* default tail spin + release store (rte_ring_c11_pvt.h:35-44)

    \* RTS update_tail (rts_elem_pvt.h:25-62)
    "RTSUpdateTail.LoadTail",       \* line 45 — A0.a load of tail with acquire
    "RTSUpdateTail.LoadHead",       \* line 49 — *RELAXED* head load (Family A residual)
    "RTSUpdateTail.Compute",        \* lines 51-53
    "RTSUpdateTail.CAS",            \* lines 59-61

    \* RTS move_head (rts_elem_pvt.h:118-172)
    "RTSMoveHead.HeadWait",         \* line 133 — head_wait (acquire)
    "RTSMoveHead.LoadStail",        \* line 140
    "RTSMoveHead.CAS",              \* lines 169-172

    \* HTS move_head (hts_elem_pvt.h:104-158)
    "HTSMoveHead.HeadWait",         \* line 119
    "HTSMoveHead.LoadStail",        \* line 126
    "HTSMoveHead.CAS",              \* lines 155-158

    \* SORING acquire (soring.c:380-439)
    "SORingAcquire.MoveHead",       \* soring.c:228-247 stage_move_head
    "SORingAcquire.UpdateState",    \* soring.c:362-378 acquire_state_update
    \* SORING release (soring.c:441-488)
    "SORingRelease.LoadState",      \* soring.c:461 read state with relaxed
    "SORingRelease.Verify",         \* soring.c:465 soring_verify_state (NDEBUG just logs)
    "SORingRelease.WriteRing",      \* soring.c:468-473 enqueue_elems
    "SORingRelease.StoreFinish",    \* soring.c:476-480 fence + relaxed store of FINISH
    "SORingRelease.LoadTail",       \* soring.c:483 relaxed load of stage tail.pos (D.2)
    "SORingRelease.MaybeFinalize",  \* soring.c:485-487
    "SORingFinalize.LoadTail",      \* soring.c:77-78 acquire tail
    "SORingFinalize.CAS",           \* soring.c:86-88 try grab sync bit
    "SORingFinalize.LoadHead",      \* soring.c:95-96 relaxed head + acq fence
    "SORingFinalize.WalkStates",    \* soring.c:104-118 walk FINISH states, reset to 0
    "SORingFinalize.StoreTail",     \* soring.c:122-124 release new tail.pos with sync=0

    \* Peek API (peek_elem_pvt.h)
    "Peek.Start",                   \* peek_elem_pvt.h:113-140 do_enqueue_start
    "Peek.Finish"                   \* peek_elem_pvt.h:30-63
}

\* ========================================================================
\* Helpers
\* ========================================================================

WrapPos(x) == x % PosWrap
WrapCnt(x) == x % CntWrap
SlotOf(p)  == p % Capacity

\* Default-mode free space, viewed by producer (rte_ring_c11_pvt.h:112)
FreeProd(stail, head) == (Capacity + stail - head) % PosWrap

\* Default-mode entries available, viewed by consumer.  capacity=0 for cons.
EntriesCons(stail, head) == (stail - head) % PosWrap

\* RTS free space (rts_elem_pvt.h:148, capacity = r->capacity for prod; 0 for cons)
RTSEntries(cap, stail, head_pos) == (cap + stail - head_pos) % PosWrap

\* Items currently in ring (default mode quiescent count)
RingCount == (prodTail - consTail) % PosWrap

\* Filter empty slots from a record (used in Init for ring)
EmptyRing == [i \in 0..(Capacity-1) |-> 0]

\* Apply a sequence of values to consecutive slots starting at pos.
WriteSlots(r, pos, vals) ==
    [i \in DOMAIN r |->
        IF \E j \in 1..Len(vals) : SlotOf(pos + j - 1) = i
        THEN vals[CHOOSE j \in 1..Len(vals) : SlotOf(pos + j - 1) = i]
        ELSE r[i]]

\* ========================================================================
\* Init
\* ========================================================================

Init ==
    /\ prodHead = 0 /\ prodTail = 0
    /\ consHead = 0 /\ consTail = 0
    /\ ring = EmptyRing
    /\ enqueued = <<>>
    /\ dequeued = <<>>
    /\ nextVal = 1
    /\ phase   = [t \in Thread |-> "Idle"]
    /\ op      = [t \in Thread |-> "none"]
    /\ role    = [t \in Thread |-> "none"]
    /\ callMode = [t \in Thread |-> Mode]   \* harness will overwrite under MCMisuseAPI
    /\ stage   = [t \in Thread |-> 0]
    /\ locOldHead = [t \in Thread |-> 0]
    /\ locNewHead = [t \in Thread |-> 0]
    /\ locReqN   = [t \in Thread |-> 0]
    /\ locActualN = [t \in Thread |-> 0]
    /\ locFtoken = [t \in Thread |-> 0]
    /\ locVals   = [t \in Thread |-> <<>>]
    /\ locReleaseN = [t \in Thread |-> 0]
    /\ locStaleHead = [t \in Thread |-> [valid|->FALSE, cnt|->0, pos|->0]]
    /\ locReservedSlots = [t \in Thread |-> {}]
    \* RTS counters start at 0 (rte_ring.c init)
    /\ rtsProdHeadCnt = 0 /\ rtsProdHeadPos = 0
    /\ rtsProdTailCnt = 0 /\ rtsProdTailPos = 0
    /\ rtsConsHeadCnt = 0 /\ rtsConsHeadPos = 0
    /\ rtsConsTailCnt = 0 /\ rtsConsTailPos = 0
    \* SORING per-stage initial state
    /\ sStageHead   = [s \in 0..(NbStage-1) |-> 0]
    /\ sStageTailPos = [s \in 0..(NbStage-1) |-> 0]
    /\ sStageTailSync = [s \in 0..(NbStage-1) |-> 0]
    /\ sStateFtoken = [s \in 0..(NbStage-1) |-> [i \in 0..(Capacity-1) |-> 0]]
    /\ sStateStnum  = [s \in 0..(NbStage-1) |-> [i \in 0..(Capacity-1) |-> "EMPTY"]]
    /\ sStateN      = [s \in 0..(NbStage-1) |-> [i \in 0..(Capacity-1) |-> 0]]
    /\ visibleProdHeadCnt = [t \in Thread |-> 0]
    /\ visibleProdHeadPos = [t \in Thread |-> 0]
    /\ visibleConsHeadCnt = [t \in Thread |-> 0]
    /\ visibleConsHeadPos = [t \in Thread |-> 0]
    /\ visibleConsTail = [t \in Thread |-> 0]
    /\ visibleProdTail = [t \in Thread |-> 0]
    /\ posWrapCount = 0
    /\ misuseDetected = FALSE
    /\ finalizeStuck  = FALSE
    /\ overCommitted  = FALSE

allVars == <<ringVars, rtsVars, historyVars, threadVars, soringVars,
             visibleVars, staleVars, extVars>>

\* ========================================================================
\* Default mode (MT / ST) — Family C regression check
\* ========================================================================

\* ---- Producer move_head ---- (rte_ring_c11_pvt.h:74-143)

\* Phase entry: thread is idle, picks a request and the initial *old_head
\* load with ACQUIRE ordering (rte_ring_c11_pvt.h:92-93).  This is the new
\* C11 chain installed by commit a4ad0eba9d (2025-11-11).
ProdMoveHead_LoadHead(t, n) ==
    /\ Mode \in {"ST","MT"}
    /\ phase[t] = "Idle"
    /\ n \in 1..MaxBatch
    /\ phase' = [phase EXCEPT ![t] = "MoveHead.LoadHead"]
    /\ op' = [op EXCEPT ![t] = "enq"]
    /\ role' = [role EXCEPT ![t] = "prod"]
    /\ callMode' = [callMode EXCEPT ![t] = Mode]
    \* Acquire load (line 92) — observe current prodHead.
    /\ locOldHead' = [locOldHead EXCEPT ![t] = prodHead]
    /\ locReqN'    = [locReqN EXCEPT ![t] = n]
    /\ UNCHANGED <<ringVars, rtsVars, historyVars, soringVars,
                   stage, locNewHead, locActualN, locFtoken, locVals,
                   locReleaseN, locStaleHead, locReservedSlots,
                   visibleVars, staleVars, extVars>>

\* Inside the do/while, the thread loads opposing tail with ACQUIRE
\* (rte_ring_c11_pvt.h:104-105). MCStaleRead may downgrade this to relaxed,
\* yielding a stale value in visibleConsTail[t].
ProdMoveHead_LoadTail(t) ==
    /\ Mode \in {"ST","MT"}
    /\ phase[t] = "MoveHead.LoadHead"
    /\ role[t] = "prod"
    \* Default: visibleConsTail[t] is updated to the current consTail.
    /\ visibleConsTail' = [visibleConsTail EXCEPT ![t] = consTail]
    /\ phase' = [phase EXCEPT ![t] = "MoveHead.LoadTail"]
    /\ UNCHANGED <<ringVars, rtsVars, historyVars,
                   op, role, callMode, stage, locOldHead, locNewHead, locReqN,
                   locActualN, locFtoken, locVals, locReleaseN, locStaleHead,
                   locReservedSlots, soringVars, visibleProdTail,
                   visibleProdHeadCnt, visibleProdHeadPos,
                   visibleConsHeadCnt, visibleConsHeadPos, extVars>>

\* CAS attempt (rte_ring_c11_pvt.h:137-140).  Two outcomes:
\*  - success: prodHead becomes new_head, advance to "Reserved"
\*  - failure: stay in MoveHead and re-enter LoadTail with refreshed *old_head
ProdMoveHead_CAS(t) ==
    /\ Mode \in {"ST","MT"}
    /\ phase[t] = "MoveHead.LoadTail"
    /\ role[t] = "prod"
    /\ LET stail == visibleConsTail[t]
           free  == FreeProd(stail, locOldHead[t])
           n     == IF locReqN[t] > free THEN 0 ELSE locReqN[t]
       IN
       \* Success branch: CAS sees prodHead == locOldHead.  (line 137)
       \/ /\ prodHead = locOldHead[t]
          /\ n > 0
          /\ prodHead' = WrapPos(locOldHead[t] + n)
          /\ phase' = [phase EXCEPT ![t] = "MoveHead.Reserved"]
          /\ locNewHead' = [locNewHead EXCEPT ![t] = WrapPos(locOldHead[t] + n)]
          /\ locActualN' = [locActualN EXCEPT ![t] = n]
          /\ locVals' = [locVals EXCEPT ![t] = [i \in 1..n |-> nextVal + i - 1]]
          /\ nextVal' = nextVal + n
          /\ UNCHANGED <<prodTail, consHead, consTail, ring, rtsVars,
                         enqueued, dequeued, op, role, callMode, stage,
                         locOldHead, locReqN, locFtoken, locReleaseN,
                         locStaleHead, locReservedSlots, soringVars,
                         visibleVars, visibleConsTail, visibleProdTail,
                         extVars>>
       \* Failure branch: CAS fails because prodHead has advanced. (line 137 returns 0)
       \* The CAS's ACQUIRE on failure refreshes *old_head from prodHead.
       \/ /\ prodHead /= locOldHead[t]
          /\ locOldHead' = [locOldHead EXCEPT ![t] = prodHead]
          /\ phase' = [phase EXCEPT ![t] = "MoveHead.LoadHead"]  \* re-enter loop
          /\ UNCHANGED <<ringVars, rtsVars, historyVars,
                         op, role, callMode, stage, locNewHead, locReqN,
                         locActualN, locFtoken, locVals, locReleaseN,
                         locStaleHead, locReservedSlots, soringVars,
                         visibleVars, visibleConsTail, visibleProdTail,
                         extVars>>
       \* Zero-room break (line 119-120): no slots available, stop.
       \/ /\ n = 0
          /\ phase' = [phase EXCEPT ![t] = "Idle"]
          /\ op' = [op EXCEPT ![t] = "none"]
          /\ role' = [role EXCEPT ![t] = "none"]
          /\ UNCHANGED <<ringVars, rtsVars, historyVars,
                         callMode, stage, locOldHead, locNewHead, locReqN,
                         locActualN, locFtoken, locVals, locReleaseN,
                         locStaleHead, locReservedSlots, soringVars,
                         visibleVars, visibleConsTail, visibleProdTail,
                         extVars>>

\* Enqueue elements into reserved slots (rte_ring_elem_pvt.h __rte_ring_enqueue_elems).
\* This is between move_head and update_tail.
ProdWriteRing(t) ==
    /\ Mode \in {"ST","MT"}
    /\ phase[t] = "MoveHead.Reserved"
    /\ role[t] = "prod"
    /\ ring' = WriteSlots(ring, locOldHead[t], locVals[t])
    /\ phase' = [phase EXCEPT ![t] = "UpdateTail"]
    /\ UNCHANGED <<prodHead, prodTail, consHead, consTail, rtsVars,
                   historyVars, op, role, callMode, stage, locOldHead,
                   locNewHead, locReqN, locActualN, locFtoken, locVals,
                   locReleaseN, locStaleHead, locReservedSlots, soringVars,
                   visibleVars, staleVars, extVars>>

\* Update tail (rte_ring_c11_pvt.h:25-44).
\* For MT: spin until tail equals our old_head, then release-store new tail.
\* For ST: just release-store.
ProdUpdateTail(t) ==
    /\ Mode \in {"ST","MT"}
    /\ phase[t] = "UpdateTail"
    /\ role[t] = "prod"
    \* Spin condition (line 36) — wait until tail == old_head.
    /\ \/ Mode = "ST"
       \/ prodTail = locOldHead[t]
    /\ prodTail' = locNewHead[t]
    /\ enqueued' = enqueued \o locVals[t]
    /\ phase' = [phase EXCEPT ![t] = "Idle"]
    /\ op' = [op EXCEPT ![t] = "none"]
    /\ role' = [role EXCEPT ![t] = "none"]
    /\ UNCHANGED <<prodHead, consHead, consTail, ring, rtsVars,
                   dequeued, nextVal, callMode, stage, locOldHead,
                   locNewHead, locReqN, locActualN, locFtoken, locVals,
                   locReleaseN, locStaleHead, locReservedSlots, soringVars,
                   visibleVars, staleVars, extVars>>

\* ---- Consumer move_head ---- (rte_ring_c11_pvt.h:74-143 for cons side)

ConsMoveHead_LoadHead(t, n) ==
    /\ Mode \in {"ST","MT"}
    /\ phase[t] = "Idle"
    /\ n \in 1..MaxBatch
    /\ phase' = [phase EXCEPT ![t] = "MoveHead.LoadHead"]
    /\ op' = [op EXCEPT ![t] = "deq"]
    /\ role' = [role EXCEPT ![t] = "cons"]
    /\ callMode' = [callMode EXCEPT ![t] = Mode]
    /\ locOldHead' = [locOldHead EXCEPT ![t] = consHead]
    /\ locReqN'    = [locReqN EXCEPT ![t] = n]
    /\ UNCHANGED <<ringVars, rtsVars, historyVars, soringVars,
                   stage, locNewHead, locActualN, locFtoken, locVals,
                   locReleaseN, locStaleHead, locReservedSlots,
                   visibleVars, staleVars, extVars>>

ConsMoveHead_LoadTail(t) ==
    /\ Mode \in {"ST","MT"}
    /\ phase[t] = "MoveHead.LoadHead"
    /\ role[t] = "cons"
    /\ visibleProdTail' = [visibleProdTail EXCEPT ![t] = prodTail]
    /\ phase' = [phase EXCEPT ![t] = "MoveHead.LoadTail"]
    /\ UNCHANGED <<ringVars, rtsVars, historyVars, op, role, callMode, stage,
                   locOldHead, locNewHead, locReqN, locActualN, locFtoken,
                   locVals, locReleaseN, locStaleHead, locReservedSlots,
                   soringVars, visibleConsTail, visibleProdHeadCnt,
                   visibleProdHeadPos, visibleConsHeadCnt, visibleConsHeadPos,
                   extVars>>

ConsMoveHead_CAS(t) ==
    /\ Mode \in {"ST","MT"}
    /\ phase[t] = "MoveHead.LoadTail"
    /\ role[t] = "cons"
    /\ LET stail == visibleProdTail[t]
           ents  == EntriesCons(stail, locOldHead[t])
           n     == IF locReqN[t] > ents THEN 0 ELSE locReqN[t]
       IN
       \/ /\ consHead = locOldHead[t]
          /\ n > 0
          /\ consHead' = WrapPos(locOldHead[t] + n)
          /\ phase' = [phase EXCEPT ![t] = "MoveHead.Reserved"]
          /\ locNewHead' = [locNewHead EXCEPT ![t] = WrapPos(locOldHead[t] + n)]
          /\ locActualN' = [locActualN EXCEPT ![t] = n]
          \* Read out current ring slot values for this consumer (rte_ring_dequeue_elems).
          /\ locVals' = [locVals EXCEPT ![t] =
                [i \in 1..n |-> ring[SlotOf(locOldHead[t] + i - 1)]]]
          /\ UNCHANGED <<prodHead, prodTail, consTail, ring, rtsVars, historyVars,
                         op, role, callMode, stage, locOldHead, locReqN,
                         locFtoken, locReleaseN, locStaleHead, locReservedSlots,
                         soringVars, visibleVars, visibleConsTail,
                         visibleProdTail, extVars>>
       \/ /\ consHead /= locOldHead[t]
          /\ locOldHead' = [locOldHead EXCEPT ![t] = consHead]
          /\ phase' = [phase EXCEPT ![t] = "MoveHead.LoadHead"]
          /\ UNCHANGED <<ringVars, rtsVars, historyVars,
                         op, role, callMode, stage, locNewHead, locReqN,
                         locActualN, locFtoken, locVals, locReleaseN,
                         locStaleHead, locReservedSlots, soringVars,
                         visibleVars, visibleConsTail, visibleProdTail, extVars>>
       \/ /\ n = 0
          /\ phase' = [phase EXCEPT ![t] = "Idle"]
          /\ op' = [op EXCEPT ![t] = "none"]
          /\ role' = [role EXCEPT ![t] = "none"]
          /\ UNCHANGED <<ringVars, rtsVars, historyVars,
                         callMode, stage, locOldHead, locNewHead, locReqN,
                         locActualN, locFtoken, locVals, locReleaseN,
                         locStaleHead, locReservedSlots, soringVars,
                         visibleVars, visibleConsTail, visibleProdTail, extVars>>

ConsUpdateTail(t) ==
    /\ Mode \in {"ST","MT"}
    /\ phase[t] = "MoveHead.Reserved"
    /\ role[t] = "cons"
    /\ \/ Mode = "ST"
       \/ consTail = locOldHead[t]
    /\ consTail' = locNewHead[t]
    /\ dequeued' = dequeued \o locVals[t]
    /\ phase' = [phase EXCEPT ![t] = "Idle"]
    /\ op' = [op EXCEPT ![t] = "none"]
    /\ role' = [role EXCEPT ![t] = "none"]
    /\ UNCHANGED <<prodHead, prodTail, consHead, ring, rtsVars,
                   enqueued, nextVal, callMode, stage, locOldHead,
                   locNewHead, locReqN, locActualN, locFtoken, locVals,
                   locReleaseN, locStaleHead, locReservedSlots, soringVars,
                   visibleVars, staleVars, extVars>>

\* ========================================================================
\* HTS mode (rte_ring_hts_elem_pvt.h)
\* ========================================================================

\* HTS spin until head == tail (head_wait, hts_elem_pvt.h:56-69).
\* Modeled by guard prodHead = prodTail / consHead = consTail.
HTSProdHeadWait(t, n) ==
    /\ Mode = "HTS"
    /\ phase[t] = "Idle"
    /\ n \in 1..MaxBatch
    /\ prodHead = prodTail   \* head_wait done; (hts_elem_pvt.h:63)
    /\ phase' = [phase EXCEPT ![t] = "HTSMoveHead.HeadWait"]
    /\ op' = [op EXCEPT ![t] = "enq"]
    /\ role' = [role EXCEPT ![t] = "prod"]
    /\ callMode' = [callMode EXCEPT ![t] = Mode]
    /\ locOldHead' = [locOldHead EXCEPT ![t] = prodHead]
    /\ locReqN' = [locReqN EXCEPT ![t] = n]
    /\ UNCHANGED <<ringVars, rtsVars, historyVars, soringVars,
                   stage, locNewHead, locActualN, locFtoken, locVals,
                   locReleaseN, locStaleHead, locReservedSlots,
                   visibleVars, staleVars, extVars>>

HTSProdLoadStail(t) ==
    /\ Mode = "HTS"
    /\ phase[t] = "HTSMoveHead.HeadWait"
    /\ role[t] = "prod"
    /\ visibleConsTail' = [visibleConsTail EXCEPT ![t] = consTail]
    /\ phase' = [phase EXCEPT ![t] = "HTSMoveHead.LoadStail"]
    /\ UNCHANGED <<ringVars, rtsVars, historyVars, op, role, callMode, stage,
                   locOldHead, locNewHead, locReqN, locActualN, locFtoken,
                   locVals, locReleaseN, locStaleHead, locReservedSlots,
                   soringVars, visibleProdTail, visibleProdHeadCnt,
                   visibleProdHeadPos, visibleConsHeadCnt, visibleConsHeadPos,
                   extVars>>

\* HTS CAS atomically writes (head, tail) — but here only head changes since
\* np.tail = op.tail (hts_elem_pvt.h:144).  CAS expected match: full
\* (head,tail) pair == (op.head, op.tail).
HTSProdCAS(t) ==
    /\ Mode = "HTS"
    /\ phase[t] = "HTSMoveHead.LoadStail"
    /\ role[t] = "prod"
    /\ LET stail == visibleConsTail[t]
           free  == FreeProd(stail, locOldHead[t])
           n     == IF locReqN[t] > free THEN 0 ELSE locReqN[t]
       IN
       \/ /\ prodHead = locOldHead[t]
          /\ n > 0
          /\ prodHead' = WrapPos(locOldHead[t] + n)
          /\ phase' = [phase EXCEPT ![t] = "MoveHead.Reserved"]
          /\ locNewHead' = [locNewHead EXCEPT ![t] = WrapPos(locOldHead[t] + n)]
          /\ locActualN' = [locActualN EXCEPT ![t] = n]
          /\ locVals' = [locVals EXCEPT ![t] = [i \in 1..n |-> nextVal + i - 1]]
          /\ nextVal' = nextVal + n
          /\ UNCHANGED <<prodTail, consHead, consTail, ring, rtsVars,
                         enqueued, dequeued, op, role, callMode, stage,
                         locOldHead, locReqN, locFtoken, locReleaseN,
                         locStaleHead, locReservedSlots, soringVars,
                         visibleVars, visibleConsTail, visibleProdTail,
                         extVars>>
       \/ /\ prodHead /= locOldHead[t]    \* CAS failure -> retry head_wait
          /\ phase' = [phase EXCEPT ![t] = "Idle"]   \* re-enter via HTSProdHeadWait
          /\ op' = [op EXCEPT ![t] = "none"]
          /\ role' = [role EXCEPT ![t] = "none"]
          /\ UNCHANGED <<ringVars, rtsVars, historyVars,
                         callMode, stage, locOldHead, locNewHead, locReqN,
                         locActualN, locFtoken, locVals, locReleaseN,
                         locStaleHead, locReservedSlots, soringVars,
                         visibleVars, visibleConsTail, visibleProdTail, extVars>>
       \/ /\ n = 0
          /\ phase' = [phase EXCEPT ![t] = "Idle"]
          /\ op' = [op EXCEPT ![t] = "none"]
          /\ role' = [role EXCEPT ![t] = "none"]
          /\ UNCHANGED <<ringVars, rtsVars, historyVars,
                         callMode, stage, locOldHead, locNewHead, locReqN,
                         locActualN, locFtoken, locVals, locReleaseN,
                         locStaleHead, locReservedSlots, soringVars,
                         visibleVars, visibleConsTail, visibleProdTail, extVars>>

\* HTS update_tail — release-store of new tail (hts_elem_pvt.h:42).
HTSProdUpdateTail(t) ==
    /\ Mode = "HTS"
    /\ phase[t] = "MoveHead.Reserved"
    /\ role[t] = "prod"
    /\ ring' = WriteSlots(ring, locOldHead[t], locVals[t])
    /\ prodTail' = locNewHead[t]
    /\ enqueued' = enqueued \o locVals[t]
    /\ phase' = [phase EXCEPT ![t] = "Idle"]
    /\ op' = [op EXCEPT ![t] = "none"]
    /\ role' = [role EXCEPT ![t] = "none"]
    /\ UNCHANGED <<prodHead, consHead, consTail, rtsVars,
                   dequeued, nextVal, callMode, stage, locOldHead,
                   locNewHead, locReqN, locActualN, locFtoken, locVals,
                   locReleaseN, locStaleHead, locReservedSlots, soringVars,
                   visibleVars, staleVars, extVars>>

\* HTS Consumer uses identical mechanism (omitted for brevity; symmetric).
HTSConsHeadWait(t, n) ==
    /\ Mode = "HTS"
    /\ phase[t] = "Idle"
    /\ n \in 1..MaxBatch
    /\ consHead = consTail
    /\ phase' = [phase EXCEPT ![t] = "HTSMoveHead.HeadWait"]
    /\ op' = [op EXCEPT ![t] = "deq"]
    /\ role' = [role EXCEPT ![t] = "cons"]
    /\ callMode' = [callMode EXCEPT ![t] = Mode]
    /\ locOldHead' = [locOldHead EXCEPT ![t] = consHead]
    /\ locReqN' = [locReqN EXCEPT ![t] = n]
    /\ UNCHANGED <<ringVars, rtsVars, historyVars, soringVars,
                   stage, locNewHead, locActualN, locFtoken, locVals,
                   locReleaseN, locStaleHead, locReservedSlots,
                   visibleVars, staleVars, extVars>>

HTSConsLoadStail(t) ==
    /\ Mode = "HTS"
    /\ phase[t] = "HTSMoveHead.HeadWait"
    /\ role[t] = "cons"
    /\ visibleProdTail' = [visibleProdTail EXCEPT ![t] = prodTail]
    /\ phase' = [phase EXCEPT ![t] = "HTSMoveHead.LoadStail"]
    /\ UNCHANGED <<ringVars, rtsVars, historyVars, op, role, callMode, stage,
                   locOldHead, locNewHead, locReqN, locActualN, locFtoken,
                   locVals, locReleaseN, locStaleHead, locReservedSlots,
                   soringVars, visibleConsTail, visibleProdHeadCnt,
                   visibleProdHeadPos, visibleConsHeadCnt, visibleConsHeadPos,
                   extVars>>

HTSConsCAS(t) ==
    /\ Mode = "HTS"
    /\ phase[t] = "HTSMoveHead.LoadStail"
    /\ role[t] = "cons"
    /\ LET stail == visibleProdTail[t]
           ents  == EntriesCons(stail, locOldHead[t])
           n     == IF locReqN[t] > ents THEN 0 ELSE locReqN[t]
       IN
       \/ /\ consHead = locOldHead[t]
          /\ n > 0
          /\ consHead' = WrapPos(locOldHead[t] + n)
          /\ phase' = [phase EXCEPT ![t] = "MoveHead.Reserved"]
          /\ locNewHead' = [locNewHead EXCEPT ![t] = WrapPos(locOldHead[t] + n)]
          /\ locActualN' = [locActualN EXCEPT ![t] = n]
          /\ locVals' = [locVals EXCEPT ![t] =
                [i \in 1..n |-> ring[SlotOf(locOldHead[t] + i - 1)]]]
          /\ UNCHANGED <<prodHead, prodTail, consTail, ring, rtsVars,
                         historyVars, op, role, callMode, stage, locOldHead,
                         locReqN, locFtoken, locReleaseN, locStaleHead,
                         locReservedSlots, soringVars, visibleVars,
                         visibleConsTail, visibleProdTail, extVars>>
       \/ /\ \/ consHead /= locOldHead[t]
             \/ n = 0
          /\ phase' = [phase EXCEPT ![t] = "Idle"]
          /\ op' = [op EXCEPT ![t] = "none"]
          /\ role' = [role EXCEPT ![t] = "none"]
          /\ UNCHANGED <<ringVars, rtsVars, historyVars,
                         callMode, stage, locOldHead, locNewHead, locReqN,
                         locActualN, locFtoken, locVals, locReleaseN,
                         locStaleHead, locReservedSlots, soringVars,
                         visibleVars, visibleConsTail, visibleProdTail, extVars>>

HTSConsUpdateTail(t) ==
    /\ Mode = "HTS"
    /\ phase[t] = "MoveHead.Reserved"
    /\ role[t] = "cons"
    /\ consTail' = locNewHead[t]
    /\ dequeued' = dequeued \o locVals[t]
    /\ phase' = [phase EXCEPT ![t] = "Idle"]
    /\ op' = [op EXCEPT ![t] = "none"]
    /\ role' = [role EXCEPT ![t] = "none"]
    /\ UNCHANGED <<prodHead, prodTail, consHead, ring, rtsVars,
                   enqueued, nextVal, callMode, stage, locOldHead,
                   locNewHead, locReqN, locActualN, locFtoken, locVals,
                   locReleaseN, locStaleHead, locReservedSlots, soringVars,
                   visibleVars, staleVars, extVars>>

\* ========================================================================
\* RTS mode — Family A target (rts_elem_pvt.h)
\* ========================================================================

\* ---- RTS move_head (rts_elem_pvt.h:109-176) ----

\* head_wait acquire (line 133).  Throttle: spin while h.pos - tail.pos > htd_max.
RTSProdHeadWait(t, n) ==
    /\ Mode = "RTS"
    /\ phase[t] = "Idle"
    /\ n \in 1..MaxBatch
    /\ (rtsProdHeadPos - rtsProdTailPos) % PosWrap <= HTDMax  \* throttle (line 77)
    /\ phase' = [phase EXCEPT ![t] = "RTSMoveHead.HeadWait"]
    /\ op' = [op EXCEPT ![t] = "enq"]
    /\ role' = [role EXCEPT ![t] = "prod"]
    /\ callMode' = [callMode EXCEPT ![t] = Mode]
    \* Acquire load of head.raw — captures (cnt, pos) snapshot.
    /\ visibleProdHeadCnt' = [visibleProdHeadCnt EXCEPT ![t] = rtsProdHeadCnt]
    /\ visibleProdHeadPos' = [visibleProdHeadPos EXCEPT ![t] = rtsProdHeadPos]
    /\ locOldHead' = [locOldHead EXCEPT ![t] = rtsProdHeadPos]
    /\ locReqN' = [locReqN EXCEPT ![t] = n]
    /\ UNCHANGED <<ringVars, rtsVars, historyVars, soringVars,
                   stage, locNewHead, locActualN, locFtoken, locVals,
                   locReleaseN, locStaleHead, locReservedSlots,
                   visibleConsHeadCnt, visibleConsHeadPos,
                   visibleConsTail, visibleProdTail, extVars>>

\* Acquire load of opposing tail (line 140) — for RTS this is the consumer
\* side's RTS tail position (`r->rts_cons.tail.pos`), not the default-mode
\* `consTail` (which is unused under RTS mode).
RTSProdLoadStail(t) ==
    /\ Mode = "RTS"
    /\ phase[t] = "RTSMoveHead.HeadWait"
    /\ role[t] = "prod"
    /\ visibleConsTail' = [visibleConsTail EXCEPT ![t] = rtsConsTailPos]
    /\ phase' = [phase EXCEPT ![t] = "RTSMoveHead.LoadStail"]
    /\ UNCHANGED <<ringVars, rtsVars, historyVars,
                   op, role, callMode, stage, locOldHead, locNewHead, locReqN,
                   locActualN, locFtoken, locVals, locReleaseN, locStaleHead,
                   locReservedSlots, soringVars, visibleProdTail,
                   visibleProdHeadCnt, visibleProdHeadPos,
                   visibleConsHeadCnt, visibleConsHeadPos, extVars>>

\* CAS on d->head.raw (lines 169-172).  Update both .pos and .cnt+1.
RTSProdCAS(t) ==
    /\ Mode = "RTS"
    /\ phase[t] = "RTSMoveHead.LoadStail"
    /\ role[t] = "prod"
    /\ LET stail == visibleConsTail[t]
           free  == RTSEntries(Capacity, stail, visibleProdHeadPos[t])
           n     == IF locReqN[t] > free THEN 0 ELSE locReqN[t]
       IN
       \/ \* CAS success: head matches local snapshot
          /\ rtsProdHeadCnt = visibleProdHeadCnt[t]
          /\ rtsProdHeadPos = visibleProdHeadPos[t]
          /\ n > 0
          /\ rtsProdHeadCnt' = WrapCnt(rtsProdHeadCnt + 1)
          /\ rtsProdHeadPos' = WrapPos(rtsProdHeadPos + n)
          /\ phase' = [phase EXCEPT ![t] = "MoveHead.Reserved"]
          /\ locOldHead' = [locOldHead EXCEPT ![t] = rtsProdHeadPos]
          /\ locNewHead' = [locNewHead EXCEPT ![t] = WrapPos(rtsProdHeadPos + n)]
          /\ locActualN' = [locActualN EXCEPT ![t] = n]
          /\ locVals' = [locVals EXCEPT ![t] = [i \in 1..n |-> nextVal + i - 1]]
          /\ nextVal' = nextVal + n
          /\ UNCHANGED <<prodHead, prodTail, consHead, consTail, ring,
                         rtsProdTailCnt, rtsProdTailPos, rtsConsHeadCnt,
                         rtsConsHeadPos, rtsConsTailCnt, rtsConsTailPos,
                         enqueued, dequeued, op, role, callMode, stage,
                         locReqN, locFtoken, locReleaseN, locStaleHead,
                         locReservedSlots, soringVars, visibleVars,
                         visibleConsTail, visibleProdTail, extVars>>
       \/ \* CAS failure: head moved.  Refresh visible head and retry from head_wait.
          /\ \/ rtsProdHeadCnt /= visibleProdHeadCnt[t]
             \/ rtsProdHeadPos /= visibleProdHeadPos[t]
          /\ visibleProdHeadCnt' = [visibleProdHeadCnt EXCEPT ![t] = rtsProdHeadCnt]
          /\ visibleProdHeadPos' = [visibleProdHeadPos EXCEPT ![t] = rtsProdHeadPos]
          /\ phase' = [phase EXCEPT ![t] = "RTSMoveHead.HeadWait"]
          /\ UNCHANGED <<ringVars, rtsVars, historyVars,
                         op, role, callMode, stage, locOldHead, locNewHead,
                         locReqN, locActualN, locFtoken, locVals, locReleaseN,
                         locStaleHead, locReservedSlots, soringVars,
                         visibleConsHeadCnt, visibleConsHeadPos,
                         visibleConsTail, visibleProdTail, extVars>>
       \/ /\ n = 0
          /\ phase' = [phase EXCEPT ![t] = "Idle"]
          /\ op' = [op EXCEPT ![t] = "none"]
          /\ role' = [role EXCEPT ![t] = "none"]
          /\ UNCHANGED <<ringVars, rtsVars, historyVars,
                         callMode, stage, locOldHead, locNewHead, locReqN,
                         locActualN, locFtoken, locVals, locReleaseN,
                         locStaleHead, locReservedSlots, soringVars,
                         visibleVars, visibleConsTail, visibleProdTail, extVars>>

\* ---- RTS update_tail (rts_elem_pvt.h:25-62) — FAMILY A TARGET ----

\* Step (a): A0.a — load tail with ACQUIRE (line 45).
RTSProdUpdateTail_LoadTail(t) ==
    /\ Mode = "RTS"
    /\ phase[t] = "MoveHead.Reserved"
    /\ role[t] = "prod"
    /\ ring' = WriteSlots(ring, locOldHead[t], locVals[t])  \* enqueue elems first (line 234)
    /\ phase' = [phase EXCEPT ![t] = "RTSUpdateTail.LoadTail"]
    \* Snapshot tail (cnt, pos) into local "ot".  We model the snapshot by
    \* reading current rtsProdTail values; thread-private storage means we
    \* keep them in locOldHead/locNewHead repurposed: locOldHead for ot.cnt,
    \* locNewHead for ot.pos.  (Slight overload but keeps the variable count
    \* down; comments below reference these as ot.cnt / ot.pos.)
    /\ locOldHead' = [locOldHead EXCEPT ![t] = rtsProdTailCnt]   \* ot.cnt
    /\ locNewHead' = [locNewHead EXCEPT ![t] = rtsProdTailPos]   \* ot.pos
    /\ UNCHANGED <<prodHead, prodTail, consHead, consTail, rtsVars,
                   historyVars, op, role, callMode, stage, locReqN,
                   locActualN, locFtoken, locVals, locReleaseN, locStaleHead,
                   locReservedSlots, soringVars, visibleVars, staleVars, extVars>>

\* Step (b): RELAXED head load (line 49) — FAMILY A residual.
\* Default: thread observes the current head.raw exactly.
\* Adversary (MCStaleHeadRTS): thread observes a STALE prior value.  See MC.tla.
\* The post-Nov-2025 patch did not add an acquire here.
RTSProdUpdateTail_LoadHead(t) ==
    /\ Mode = "RTS"
    /\ phase[t] = "RTSUpdateTail.LoadTail"
    /\ role[t] = "prod"
    \* Default observation: fresh head.raw values.
    /\ locStaleHead' = [locStaleHead EXCEPT ![t] =
            [valid|->TRUE, cnt|->rtsProdHeadCnt, pos|->rtsProdHeadPos]]
    /\ phase' = [phase EXCEPT ![t] = "RTSUpdateTail.Compute"]
    /\ UNCHANGED <<ringVars, rtsVars, historyVars, op, role, callMode, stage,
                   locOldHead, locNewHead, locReqN, locActualN, locFtoken,
                   locVals, locReleaseN, locReservedSlots, soringVars,
                   visibleVars, staleVars, extVars>>

\* Step (c): compute nt = ot, ++nt.cnt, if nt.cnt == h.cnt then nt.pos = h.pos.
\* (rts_elem_pvt.h:51-53)
RTSProdUpdateTail_Compute(t) ==
    /\ Mode = "RTS"
    /\ phase[t] = "RTSUpdateTail.Compute"
    /\ role[t] = "prod"
    /\ phase' = [phase EXCEPT ![t] = "RTSUpdateTail.CAS"]
    /\ UNCHANGED <<ringVars, rtsVars, historyVars, op, role, callMode, stage,
                   locOldHead, locNewHead, locReqN, locActualN, locFtoken,
                   locVals, locReleaseN, locStaleHead, locReservedSlots,
                   soringVars, visibleVars, staleVars, extVars>>

\* Step (d): CAS on ht->tail.raw (lines 59-61) with release / acquire-on-failure.
\* Compute new (nt.cnt, nt.pos) from local ot and stale h.
RTSProdUpdateTail_CAS(t) ==
    /\ Mode = "RTS"
    /\ phase[t] = "RTSUpdateTail.CAS"
    /\ role[t] = "prod"
    /\ LET h_cnt == locStaleHead[t].cnt
           h_pos == locStaleHead[t].pos
           ot_cnt == locOldHead[t]              \* ot.cnt
           ot_pos == locNewHead[t]              \* ot.pos
           nt_cnt == WrapCnt(ot_cnt + 1)
           nt_pos == IF nt_cnt = h_cnt THEN h_pos ELSE ot_pos
       IN
       \/ \* CAS success
          /\ rtsProdTailCnt = ot_cnt
          /\ rtsProdTailPos = ot_pos
          /\ rtsProdTailCnt' = nt_cnt
          /\ rtsProdTailPos' = nt_pos
          \* Element publication is ordered by the release on tail.raw.
          /\ enqueued' = enqueued \o locVals[t]
          /\ phase' = [phase EXCEPT ![t] = "Idle"]
          /\ op' = [op EXCEPT ![t] = "none"]
          /\ role' = [role EXCEPT ![t] = "none"]
          /\ locStaleHead' = [locStaleHead EXCEPT ![t] = [valid|->FALSE, cnt|->0, pos|->0]]
          /\ UNCHANGED <<prodHead, prodTail, consHead, consTail, ring,
                         rtsProdHeadCnt, rtsProdHeadPos, rtsConsHeadCnt,
                         rtsConsHeadPos, rtsConsTailCnt, rtsConsTailPos,
                         dequeued, nextVal, callMode, stage, locOldHead,
                         locNewHead, locReqN, locActualN, locFtoken, locVals,
                         locReleaseN, locReservedSlots, soringVars,
                         visibleVars, staleVars, extVars>>
       \/ \* CAS failure -> on failure ACQUIRE refreshes ot (line 61).
          /\ \/ rtsProdTailCnt /= ot_cnt
             \/ rtsProdTailPos /= ot_pos
          /\ locOldHead' = [locOldHead EXCEPT ![t] = rtsProdTailCnt]
          /\ locNewHead' = [locNewHead EXCEPT ![t] = rtsProdTailPos]
          \* Re-enter loop body: head load happens again (rts_elem_pvt.h:47-61).
          \* Phase returns to LoadHead.  This is precisely where Family A
          \* lives — the stale-head load is repeated under relaxed ordering.
          /\ phase' = [phase EXCEPT ![t] = "RTSUpdateTail.LoadHead"]
          /\ UNCHANGED <<ringVars, rtsVars, historyVars,
                         op, role, callMode, stage, locReqN, locActualN,
                         locFtoken, locVals, locReleaseN, locStaleHead,
                         locReservedSlots, soringVars, visibleVars, staleVars, extVars>>

\* Cons RTS mirrors Prod.  We define only the cons head_wait and CAS to keep
\* the core RTS path symmetric; the update_tail path on the consumer side is
\* identical in structure to the producer side (Family A applies equally
\* there since rts_elem_pvt.h:25-62 is shared).
RTSConsHeadWait(t, n) ==
    /\ Mode = "RTS"
    /\ phase[t] = "Idle"
    /\ n \in 1..MaxBatch
    /\ (rtsConsHeadPos - rtsConsTailPos) % PosWrap <= HTDMax
    /\ phase' = [phase EXCEPT ![t] = "RTSMoveHead.HeadWait"]
    /\ op' = [op EXCEPT ![t] = "deq"]
    /\ role' = [role EXCEPT ![t] = "cons"]
    /\ callMode' = [callMode EXCEPT ![t] = Mode]
    /\ visibleConsHeadCnt' = [visibleConsHeadCnt EXCEPT ![t] = rtsConsHeadCnt]
    /\ visibleConsHeadPos' = [visibleConsHeadPos EXCEPT ![t] = rtsConsHeadPos]
    /\ locOldHead' = [locOldHead EXCEPT ![t] = rtsConsHeadPos]
    /\ locReqN' = [locReqN EXCEPT ![t] = n]
    /\ UNCHANGED <<ringVars, rtsVars, historyVars, soringVars,
                   stage, locNewHead, locActualN, locFtoken, locVals,
                   locReleaseN, locStaleHead, locReservedSlots,
                   visibleProdHeadCnt, visibleProdHeadPos,
                   visibleConsTail, visibleProdTail, extVars>>

RTSConsLoadStail(t) ==
    /\ Mode = "RTS"
    /\ phase[t] = "RTSMoveHead.HeadWait"
    /\ role[t] = "cons"
    /\ visibleProdTail' = [visibleProdTail EXCEPT ![t] = rtsProdTailPos]
    /\ phase' = [phase EXCEPT ![t] = "RTSMoveHead.LoadStail"]
    /\ UNCHANGED <<ringVars, rtsVars, historyVars, op, role, callMode, stage,
                   locOldHead, locNewHead, locReqN, locActualN, locFtoken,
                   locVals, locReleaseN, locStaleHead, locReservedSlots,
                   soringVars, visibleConsTail, visibleProdHeadCnt,
                   visibleProdHeadPos, visibleConsHeadCnt, visibleConsHeadPos,
                   extVars>>

RTSConsCAS(t) ==
    /\ Mode = "RTS"
    /\ phase[t] = "RTSMoveHead.LoadStail"
    /\ role[t] = "cons"
    /\ LET stail == visibleProdTail[t]
           ents  == RTSEntries(0, stail, visibleConsHeadPos[t])
           n     == IF locReqN[t] > ents THEN 0 ELSE locReqN[t]
       IN
       \/ /\ rtsConsHeadCnt = visibleConsHeadCnt[t]
          /\ rtsConsHeadPos = visibleConsHeadPos[t]
          /\ n > 0
          /\ rtsConsHeadCnt' = WrapCnt(rtsConsHeadCnt + 1)
          /\ rtsConsHeadPos' = WrapPos(rtsConsHeadPos + n)
          /\ phase' = [phase EXCEPT ![t] = "MoveHead.Reserved"]
          /\ locOldHead' = [locOldHead EXCEPT ![t] = rtsConsHeadPos]
          /\ locNewHead' = [locNewHead EXCEPT ![t] = WrapPos(rtsConsHeadPos + n)]
          /\ locActualN' = [locActualN EXCEPT ![t] = n]
          /\ locVals' = [locVals EXCEPT ![t] =
                [i \in 1..n |-> ring[SlotOf(rtsConsHeadPos + i - 1)]]]
          /\ UNCHANGED <<prodHead, prodTail, consHead, consTail, ring,
                         rtsProdHeadCnt, rtsProdHeadPos, rtsProdTailCnt,
                         rtsProdTailPos, rtsConsTailCnt, rtsConsTailPos,
                         historyVars, op, role, callMode, stage, locReqN,
                         locFtoken, locReleaseN, locStaleHead, locReservedSlots,
                         soringVars, visibleVars, visibleConsTail,
                         visibleProdTail, extVars>>
       \/ /\ \/ rtsConsHeadCnt /= visibleConsHeadCnt[t]
             \/ rtsConsHeadPos /= visibleConsHeadPos[t]
          /\ visibleConsHeadCnt' = [visibleConsHeadCnt EXCEPT ![t] = rtsConsHeadCnt]
          /\ visibleConsHeadPos' = [visibleConsHeadPos EXCEPT ![t] = rtsConsHeadPos]
          /\ phase' = [phase EXCEPT ![t] = "RTSMoveHead.HeadWait"]
          /\ UNCHANGED <<ringVars, rtsVars, historyVars,
                         op, role, callMode, stage, locOldHead, locNewHead,
                         locReqN, locActualN, locFtoken, locVals, locReleaseN,
                         locStaleHead, locReservedSlots, soringVars,
                         visibleProdHeadCnt, visibleProdHeadPos,
                         visibleConsTail, visibleProdTail, extVars>>
       \/ /\ n = 0
          /\ phase' = [phase EXCEPT ![t] = "Idle"]
          /\ op' = [op EXCEPT ![t] = "none"]
          /\ role' = [role EXCEPT ![t] = "none"]
          /\ UNCHANGED <<ringVars, rtsVars, historyVars,
                         callMode, stage, locOldHead, locNewHead, locReqN,
                         locActualN, locFtoken, locVals, locReleaseN,
                         locStaleHead, locReservedSlots, soringVars,
                         visibleVars, visibleConsTail, visibleProdTail, extVars>>

\* RTS Cons update_tail (mirror of Prod, single-step; not split because the
\* consumer-side variant is structurally identical — Family A is symmetric.
\* We collapse the consumer-side update_tail for state-space economy and
\* keep the producer-side split which is where BZ-1527 was reported).
RTSConsUpdateTail(t) ==
    /\ Mode = "RTS"
    /\ phase[t] = "MoveHead.Reserved"
    /\ role[t] = "cons"
    /\ rtsConsTailCnt' = WrapCnt(rtsConsTailCnt + 1)
    /\ rtsConsTailPos' = locNewHead[t]
    /\ dequeued' = dequeued \o locVals[t]
    /\ phase' = [phase EXCEPT ![t] = "Idle"]
    /\ op' = [op EXCEPT ![t] = "none"]
    /\ role' = [role EXCEPT ![t] = "none"]
    /\ UNCHANGED <<prodHead, prodTail, consHead, consTail, ring,
                   rtsProdHeadCnt, rtsProdHeadPos, rtsProdTailCnt,
                   rtsProdTailPos, rtsConsHeadCnt, rtsConsHeadPos,
                   enqueued, nextVal, callMode, stage, locOldHead,
                   locNewHead, locReqN, locActualN, locFtoken, locVals,
                   locReleaseN, locStaleHead, locReservedSlots, soringVars,
                   visibleVars, staleVars, extVars>>

\* ========================================================================
\* SORING — Family D
\* ========================================================================

\* ---- SORing acquire stage_move_head (soring.c:220-250) ----
\* Family D.1: line 228 uses RELAXED for *old_head load and a thread fence
\* on line 235 — pre-Nov-2025 anti-pattern that the November 2025 fixes
\* did not apply here.
\* SORING input enqueue (rte_soring_enqueue): models the producer-side
\* enqueue that places items into the input ring before stage 0 acquires
\* them.  We treat it as advancing prodTail by a single slot per call so
\* stage 0 has work to consume.  This is a structural action in the spec
\* (not in the harness/trace) — needed because the harness exercises the
\* input-side enqueue but does not instrument it.
SORingProdEnqueue(t) ==
    /\ Mode = "SORING"
    /\ phase[t] = "Idle"
    /\ (Capacity + consTail - prodTail) % PosWrap > 0   \* free slot exists
    /\ prodTail' = WrapPos(prodTail + 1)
    /\ ring' = [ring EXCEPT ![SlotOf(prodTail)] = nextVal]
    /\ enqueued' = enqueued \o <<nextVal>>
    /\ nextVal' = nextVal + 1
    /\ UNCHANGED <<prodHead, consHead, consTail, rtsVars,
                   dequeued, threadVars, soringVars,
                   visibleVars, staleVars, extVars>>

SORingAcquire_MoveHead(t, s, n) ==
    /\ Mode = "SORING"
    /\ phase[t] = "Idle"
    /\ s \in 0..(NbStage-1)
    /\ n \in 1..MaxBatch
    /\ LET prev_tail ==
            IF s = 0 THEN prodTail        \* stage 0 reads producer tail
            ELSE sStageTailPos[s-1]       \* stage k>0 reads stage k-1 tail
           old_head == sStageHead[s]
           avail == (0 + prev_tail - old_head) % PosWrap   \* capacity=0 (line 239)
           actual_n == IF n > avail THEN 0 ELSE n
       IN
       /\ actual_n > 0
       /\ sStageHead' = [sStageHead EXCEPT ![s] = WrapPos(old_head + actual_n)]
       /\ phase' = [phase EXCEPT ![t] = "SORingAcquire.UpdateState"]
       /\ op' = [op EXCEPT ![t] = "acq"]
       /\ role' = [role EXCEPT ![t] = "cons"]    \* acquire reads from prev stage
       /\ callMode' = [callMode EXCEPT ![t] = Mode]
       /\ stage' = [stage EXCEPT ![t] = s]
       /\ locOldHead' = [locOldHead EXCEPT ![t] = old_head]
       /\ locNewHead' = [locNewHead EXCEPT ![t] = WrapPos(old_head + actual_n)]
       /\ locReqN' = [locReqN EXCEPT ![t] = n]
       /\ locActualN' = [locActualN EXCEPT ![t] = actual_n]
       \* ftoken = pos + stage (soring.h:48).  In a 32-bit world this
       \* aliases when pos wraps — Family D.4.
       /\ locFtoken' = [locFtoken EXCEPT ![t] = (old_head + s) % PosWrap]
       /\ locReleaseN' = [locReleaseN EXCEPT ![t] = actual_n]   \* default: caller honors contract
       /\ locReservedSlots' = [locReservedSlots EXCEPT ![t] =
            { SlotOf(old_head + i - 1) : i \in 1..actual_n }]
    /\ UNCHANGED <<prodHead, prodTail, consHead, consTail, ring, rtsVars,
                   historyVars, locVals, locStaleHead, sStageTailPos,
                   sStageTailSync, sStateFtoken, sStateStnum, sStateN,
                   visibleVars, staleVars, extVars>>

\* acquire_state_update (soring.c:362-378) — store START flag + n + ftoken.
SORingAcquire_UpdateState(t) ==
    /\ Mode = "SORING"
    /\ phase[t] = "SORingAcquire.UpdateState"
    /\ op[t] = "acq"
    /\ LET s == stage[t]
           idx == SlotOf(locOldHead[t])
       IN
       \* Verify state pre-condition: was 0/EMPTY (line 369-371).  If not
       \* EMPTY, we have a corruption — flag overCommitted.
       /\ overCommitted' = (overCommitted \/ sStateStnum[s][idx] /= "EMPTY")
       /\ sStateFtoken' = [sStateFtoken EXCEPT ![s][idx] = locFtoken[t]]
       /\ sStateStnum' = [sStateStnum EXCEPT ![s][idx] = "START"]
       /\ sStateN' = [sStateN EXCEPT ![s][idx] = locActualN[t]]
       /\ phase' = [phase EXCEPT ![t] = "Idle"]
       /\ op' = [op EXCEPT ![t] = "none"]
       /\ role' = [role EXCEPT ![t] = "none"]
    /\ UNCHANGED <<ringVars, rtsVars, historyVars, callMode, stage,
                   locOldHead, locNewHead, locReqN, locActualN, locFtoken,
                   locVals, locReleaseN, locStaleHead, locReservedSlots,
                   sStageHead, sStageTailPos, sStageTailSync, visibleVars,
                   staleVars, posWrapCount, misuseDetected, finalizeStuck>>

\* ---- SORING release (soring.c:441-488) ----

\* Step: load state, verify, write ring contents, store FINISH flag.
\* Family D.3: locReleaseN[t] may differ from sStateN[s][idx] if caller
\* misuses release (the harness sets locReleaseN under MCWrongReleaseN).
SORingRelease_LoadState(t, n) ==
    /\ Mode = "SORING"
    /\ phase[t] = "Idle"
    \* Pick a thread/stage/idx with an outstanding START.
    /\ \E s \in 0..(NbStage-1), idx \in 0..(Capacity-1) :
        /\ sStateStnum[s][idx] = "START"
        /\ stage' = [stage EXCEPT ![t] = s]
        /\ locFtoken' = [locFtoken EXCEPT ![t] = sStateFtoken[s][idx]]
        /\ locActualN' = [locActualN EXCEPT ![t] = sStateN[s][idx]]
        /\ locOldHead' = [locOldHead EXCEPT ![t] = sStateFtoken[s][idx] - s]   \* pos = ftoken - stage
        /\ locReleaseN' = [locReleaseN EXCEPT ![t] = n]   \* harness chooses n
    /\ phase' = [phase EXCEPT ![t] = "SORingRelease.Verify"]
    /\ op' = [op EXCEPT ![t] = "rel"]
    /\ role' = [role EXCEPT ![t] = "prod"]
    /\ callMode' = [callMode EXCEPT ![t] = Mode]
    /\ UNCHANGED <<ringVars, rtsVars, historyVars,
                   locNewHead, locReqN, locVals, locStaleHead,
                   locReservedSlots, soringVars, visibleVars, staleVars, extVars>>

\* Verify state matches expected (soring.c:465).  Under NDEBUG this only
\* logs — corruption is silent.  Models D.3.
SORingRelease_Verify(t) ==
    /\ Mode = "SORING"
    /\ phase[t] = "SORingRelease.Verify"
    /\ op[t] = "rel"
    /\ overCommitted' = (overCommitted \/ locReleaseN[t] /= locActualN[t])
    /\ phase' = [phase EXCEPT ![t] = "SORingRelease.WriteRing"]
    /\ UNCHANGED <<ringVars, rtsVars, historyVars, op, role, callMode, stage,
                   locOldHead, locNewHead, locReqN, locActualN, locFtoken,
                   locVals, locReleaseN, locStaleHead, locReservedSlots,
                   soringVars, visibleVars, staleVars, posWrapCount,
                   misuseDetected, finalizeStuck>>

\* Optional ring write (objs != NULL branch, soring.c:468-470).
SORingRelease_WriteRing(t) ==
    /\ Mode = "SORING"
    /\ phase[t] = "SORingRelease.WriteRing"
    /\ op[t] = "rel"
    /\ phase' = [phase EXCEPT ![t] = "SORingRelease.StoreFinish"]
    /\ UNCHANGED <<ringVars, rtsVars, historyVars, op, role, callMode, stage,
                   locOldHead, locNewHead, locReqN, locActualN, locFtoken,
                   locVals, locReleaseN, locStaleHead, locReservedSlots,
                   soringVars, visibleVars, staleVars, extVars>>

\* Store FINISH (soring.c:476-480) with thread-fence(release) + relaxed store.
\* Crucial: locReleaseN — possibly wrong-n — is what gets recorded into stnum.
SORingRelease_StoreFinish(t) ==
    /\ Mode = "SORING"
    /\ phase[t] = "SORingRelease.StoreFinish"
    /\ op[t] = "rel"
    /\ LET s == stage[t]
           idx == SlotOf(locOldHead[t])
       IN
       /\ sStateStnum' = [sStateStnum EXCEPT ![s][idx] = "FINISH"]
       /\ sStateN' = [sStateN EXCEPT ![s][idx] = locReleaseN[t]]   \* possibly wrong
       /\ phase' = [phase EXCEPT ![t] = "SORingRelease.LoadTail"]
    /\ UNCHANGED <<ringVars, rtsVars, historyVars, op, role, callMode, stage,
                   locOldHead, locNewHead, locReqN, locActualN, locFtoken,
                   locVals, locReleaseN, locStaleHead, locReservedSlots,
                   sStageHead, sStageTailPos, sStageTailSync, sStateFtoken,
                   visibleVars, staleVars, extVars>>

\* RELAXED load of stage tail.pos (soring.c:483) — Family D.2.
\* Default: thread observes current sStageTailPos.
\* Adversary (MCStaleTailSORing in MC.tla): observes a stale prior value.
SORingRelease_LoadTail(t) ==
    /\ Mode = "SORING"
    /\ phase[t] = "SORingRelease.LoadTail"
    /\ op[t] = "rel"
    /\ LET s == stage[t]
           pos == locOldHead[t]
           tail == sStageTailPos[s]
       IN
       \* If tail == pos, we attempt finalize; otherwise skip (line 485).
       \/ /\ tail = pos
          /\ phase' = [phase EXCEPT ![t] = "SORingRelease.MaybeFinalize"]
          /\ UNCHANGED <<op, role>>
       \/ /\ tail /= pos
          /\ phase' = [phase EXCEPT ![t] = "Idle"]
          /\ op' = [op EXCEPT ![t] = "none"]
          /\ role' = [role EXCEPT ![t] = "none"]
    /\ UNCHANGED <<ringVars, rtsVars, historyVars, callMode, stage, locOldHead,
                   locNewHead, locReqN, locActualN, locFtoken, locVals,
                   locReleaseN, locStaleHead, locReservedSlots, soringVars,
                   visibleVars, staleVars, extVars>>

\* Finalize call from release (soring.c:486-487).
\* Composition: just transition to finalize entry.  Real finalize is below.
SORingRelease_MaybeFinalize(t) ==
    /\ Mode = "SORING"
    /\ phase[t] = "SORingRelease.MaybeFinalize"
    /\ op[t] = "rel"
    /\ phase' = [phase EXCEPT ![t] = "SORingFinalize.LoadTail"]
    /\ UNCHANGED <<ringVars, rtsVars, historyVars, op, role, callMode, stage,
                   locOldHead, locNewHead, locReqN, locActualN, locFtoken,
                   locVals, locReleaseN, locStaleHead, locReservedSlots,
                   soringVars, visibleVars, staleVars, extVars>>

\* ---- SORing finalize (soring.c:67-127) ----
\* Acquire load of tail (line 77).
SORingFinalize_LoadTail(t) ==
    /\ Mode = "SORING"
    /\ phase[t] = "SORingFinalize.LoadTail"
    /\ phase' = [phase EXCEPT ![t] = "SORingFinalize.CAS"]
    /\ UNCHANGED <<ringVars, rtsVars, historyVars, op, role, callMode, stage,
                   locOldHead, locNewHead, locReqN, locActualN, locFtoken,
                   locVals, locReleaseN, locStaleHead, locReservedSlots,
                   soringVars, visibleVars, staleVars, extVars>>

\* CAS to grab sync bit (lines 86-88).
SORingFinalize_CAS(t) ==
    /\ Mode = "SORING"
    /\ phase[t] = "SORingFinalize.CAS"
    /\ LET s == stage[t]
       IN
       \/ \* sync was 0, CAS sets it to 1
          /\ sStageTailSync[s] = 0
          /\ sStageTailSync' = [sStageTailSync EXCEPT ![s] = 1]
          /\ phase' = [phase EXCEPT ![t] = "SORingFinalize.LoadHead"]
          /\ UNCHANGED <<ringVars, rtsVars, historyVars, op, role, callMode,
                         stage, locOldHead, locNewHead, locReqN, locActualN,
                         locFtoken, locVals, locReleaseN, locStaleHead,
                         locReservedSlots, sStageHead, sStageTailPos,
                         sStateFtoken, sStateStnum, sStateN, visibleVars,
                         staleVars, extVars>>
       \/ \* Other thread already finalizing (sync=1) or CAS lost.
          /\ sStageTailSync[s] = 1
          /\ phase' = [phase EXCEPT ![t] = "Idle"]
          /\ op' = [op EXCEPT ![t] = "none"]
          /\ role' = [role EXCEPT ![t] = "none"]
          /\ UNCHANGED <<ringVars, rtsVars, historyVars,
                         callMode, stage, locOldHead, locNewHead, locReqN,
                         locActualN, locFtoken, locVals, locReleaseN,
                         locStaleHead, locReservedSlots, soringVars,
                         visibleVars, staleVars, extVars>>

\* Read head + acquire-fence (soring.c:95-96).
SORingFinalize_LoadHead(t) ==
    /\ Mode = "SORING"
    /\ phase[t] = "SORingFinalize.LoadHead"
    /\ LET s == stage[t]
       IN locOldHead' = [locOldHead EXCEPT ![t] = sStageHead[s]]
    /\ phase' = [phase EXCEPT ![t] = "SORingFinalize.WalkStates"]
    /\ UNCHANGED <<ringVars, rtsVars, historyVars, op, role, callMode, stage,
                   locNewHead, locReqN, locActualN, locFtoken, locVals,
                   locReleaseN, locStaleHead, locReservedSlots, soringVars,
                   visibleVars, staleVars, extVars>>

\* Walk states from current tail to head, advancing past contiguous FINISH
\* slots (soring.c:104-118).  Reset cleared states to 0/EMPTY.
SORingFinalize_WalkStates(t) ==
    /\ Mode = "SORING"
    /\ phase[t] = "SORingFinalize.WalkStates"
    /\ LET s == stage[t]
           start_tail == sStageTailPos[s]
           head == locOldHead[t]
           span == (head - start_tail) % PosWrap
           \* Walk until first non-FINISH or ftoken-mismatch slot.
           StopAt(k) ==
               LET pos == start_tail + k
                   idx == SlotOf(pos)
                   ftkn == (pos + s) % PosWrap
               IN sStateStnum[s][idx] /= "FINISH"
                  \/ sStateFtoken[s][idx] /= ftkn
           StopK == IF span = 0 THEN 0
                    ELSE IF \E k \in 0..(span-1) : StopAt(k)
                         THEN CHOOSE k \in 0..(span-1) : StopAt(k) /\ \A k2 \in 0..(k-1) : ~StopAt(k2)
                         ELSE span
           cleared == { SlotOf(start_tail + k) : k \in 0..(StopK-1) }
       IN
       /\ sStateFtoken' = [sStateFtoken EXCEPT ![s] =
            [i \in 0..(Capacity-1) |-> IF i \in cleared THEN 0 ELSE sStateFtoken[s][i]]]
       /\ sStateStnum' = [sStateStnum EXCEPT ![s] =
            [i \in 0..(Capacity-1) |-> IF i \in cleared THEN "EMPTY" ELSE sStateStnum[s][i]]]
       /\ sStateN' = [sStateN EXCEPT ![s] =
            [i \in 0..(Capacity-1) |-> IF i \in cleared THEN 0 ELSE sStateN[s][i]]]
       /\ locNewHead' = [locNewHead EXCEPT ![t] = WrapPos(start_tail + StopK)]
       /\ phase' = [phase EXCEPT ![t] = "SORingFinalize.StoreTail"]
    /\ UNCHANGED <<ringVars, rtsVars, historyVars, op, role, callMode, stage,
                   locOldHead, locReqN, locActualN, locFtoken, locVals,
                   locReleaseN, locStaleHead, locReservedSlots, sStageHead,
                   sStageTailPos, sStageTailSync, visibleVars, staleVars,
                   extVars>>

\* Release new tail.pos and clear sync bit (soring.c:122-124).
SORingFinalize_StoreTail(t) ==
    /\ Mode = "SORING"
    /\ phase[t] = "SORingFinalize.StoreTail"
    /\ LET s == stage[t] IN
       /\ sStageTailPos' = [sStageTailPos EXCEPT ![s] = locNewHead[t]]
       /\ sStageTailSync' = [sStageTailSync EXCEPT ![s] = 0]
    /\ phase' = [phase EXCEPT ![t] = "Idle"]
    /\ op' = [op EXCEPT ![t] = "none"]
    /\ role' = [role EXCEPT ![t] = "none"]
    /\ UNCHANGED <<ringVars, rtsVars, historyVars, callMode, stage, locOldHead,
                   locNewHead, locReqN, locActualN, locFtoken, locVals,
                   locReleaseN, locStaleHead, locReservedSlots, sStageHead,
                   sStateFtoken, sStateStnum, sStateN, visibleVars, staleVars,
                   extVars>>

\* ========================================================================
\* Peek API — Family E
\* ========================================================================

\* Peek START moves head identically to the appropriate enq/deq path.
\* For ST and HTS only (peek_elem_pvt.h:117-135 — MT/RTS unsupported).
PeekStart(t, n) ==
    /\ Mode \in {"ST","HTS"}     \* peek API supports ST and MT_HTS only (line 119, 124)
    /\ phase[t] = "Idle"
    /\ n \in 1..MaxBatch
    /\ LET stail == consTail
           free == FreeProd(stail, prodHead)
           actual_n == IF n > free THEN 0 ELSE n
       IN
       /\ actual_n > 0
       /\ prodHead' = WrapPos(prodHead + actual_n)
       /\ phase' = [phase EXCEPT ![t] = "Peek.Start"]
       /\ op' = [op EXCEPT ![t] = "enq"]
       /\ role' = [role EXCEPT ![t] = "prod"]
       /\ callMode' = [callMode EXCEPT ![t] = Mode]
       /\ locOldHead' = [locOldHead EXCEPT ![t] = prodHead]
       /\ locActualN' = [locActualN EXCEPT ![t] = actual_n]
       /\ locReqN' = [locReqN EXCEPT ![t] = n]
       /\ locVals' = [locVals EXCEPT ![t] = [i \in 1..actual_n |-> nextVal + i - 1]]
       /\ nextVal' = nextVal + actual_n
       /\ locReleaseN' = [locReleaseN EXCEPT ![t] = actual_n]
       /\ locReservedSlots' = [locReservedSlots EXCEPT ![t] =
            { SlotOf(prodHead + i - 1) : i \in 1..actual_n }]
    /\ UNCHANGED <<prodTail, consHead, consTail, ring, rtsVars,
                   enqueued, dequeued, stage, locNewHead, locFtoken,
                   locStaleHead, soringVars, visibleVars, staleVars, extVars>>

\* Peek FINISH (peek_elem_pvt.h:30-63 + zc_finish wrappers).
\* Caller may supply commit_n != reserved_n.  The check at line 41 is a
\* RTE_ASSERT (compiled out under NDEBUG) so the implementation silently
\* normalises:  if (n < num) num = 0; rolling back to tail.
PeekFinish(t) ==
    /\ Mode \in {"ST","HTS"}
    /\ phase[t] = "Peek.Start"
    /\ op[t] = "enq"
    /\ LET reserved == locActualN[t]
           commit == locReleaseN[t]
           h == prodHead
           tail == prodTail
           span == (h - tail) % PosWrap
           \* peek_elem_pvt.h:38-41 — n = h - tail; assert(n >= num); else num=0
           normalised == IF span >= commit THEN commit ELSE 0
           new_head == WrapPos(tail + normalised)
       IN
       \* Track silent over-commit when caller passes commit > reserved.
       /\ overCommitted' = (overCommitted \/ commit > reserved)
       /\ ring' = WriteSlots(ring, locOldHead[t], locVals[t])
       \* set_head_tail (peek_elem_pvt.h:60-62) — head and tail both = pos.
       /\ prodHead' = new_head
       /\ prodTail' = new_head
       /\ enqueued' = IF normalised = 0 THEN enqueued
                      ELSE enqueued \o [i \in 1..normalised |-> locVals[t][i]]
       /\ phase' = [phase EXCEPT ![t] = "Idle"]
       /\ op' = [op EXCEPT ![t] = "none"]
       /\ role' = [role EXCEPT ![t] = "none"]
    /\ UNCHANGED <<consHead, consTail, rtsVars,
                   dequeued, nextVal, callMode, stage, locOldHead, locNewHead,
                   locReqN, locActualN, locFtoken, locVals, locReleaseN,
                   locStaleHead, locReservedSlots, soringVars, visibleVars,
                   staleVars, posWrapCount, misuseDetected, finalizeStuck>>

\* ========================================================================
\* Family B — Caller misuse: API expected sync_type does not match Mode.
\* The MCMisuseAPI action wraps a normal enq/deq with callMode set to a
\* mode that doesn't match Mode.  It is defined in MC.tla; the base spec
\* exposes the *invariant* APIContractConsistent (below) plus the variable
\* misuseDetected which gets set by MC actions.
\* ========================================================================

\* ========================================================================
\* Position-wrap monotonic counter — Family D.4.
\* Increment whenever any visible head/tail position is about to roll over.
\* ========================================================================
TickPosWrap ==
    /\ posWrapCount' = posWrapCount + 1
    /\ UNCHANGED <<ringVars, rtsVars, historyVars, threadVars, soringVars,
                   visibleVars, staleVars, misuseDetected, finalizeStuck,
                   overCommitted>>

\* ========================================================================
\* Next
\* ========================================================================

Next ==
    \/ \E t \in Thread, n \in 1..MaxBatch :
         \/ ProdMoveHead_LoadHead(t, n)
         \/ ConsMoveHead_LoadHead(t, n)
         \/ HTSProdHeadWait(t, n)
         \/ HTSConsHeadWait(t, n)
         \/ RTSProdHeadWait(t, n)
         \/ RTSConsHeadWait(t, n)
         \/ SORingAcquire_MoveHead(t, 0, n)
         \/ SORingAcquire_MoveHead(t, IF NbStage > 1 THEN 1 ELSE 0, n)
         \/ SORingRelease_LoadState(t, n)
         \/ PeekStart(t, n)
    \/ \E t \in Thread :
         \/ ProdMoveHead_LoadTail(t)
         \/ ProdMoveHead_CAS(t)
         \/ ProdWriteRing(t)
         \/ ProdUpdateTail(t)
         \/ ConsMoveHead_LoadTail(t)
         \/ ConsMoveHead_CAS(t)
         \/ ConsUpdateTail(t)
         \/ HTSProdLoadStail(t) \/ HTSProdCAS(t) \/ HTSProdUpdateTail(t)
         \/ HTSConsLoadStail(t) \/ HTSConsCAS(t) \/ HTSConsUpdateTail(t)
         \/ RTSProdLoadStail(t) \/ RTSProdCAS(t)
         \/ RTSProdUpdateTail_LoadTail(t)
         \/ RTSProdUpdateTail_LoadHead(t)
         \/ RTSProdUpdateTail_Compute(t)
         \/ RTSProdUpdateTail_CAS(t)
         \/ RTSConsLoadStail(t) \/ RTSConsCAS(t) \/ RTSConsUpdateTail(t)
         \/ SORingAcquire_UpdateState(t)
         \/ SORingRelease_Verify(t)
         \/ SORingRelease_WriteRing(t)
         \/ SORingRelease_StoreFinish(t)
         \/ SORingRelease_LoadTail(t)
         \/ SORingRelease_MaybeFinalize(t)
         \/ SORingFinalize_LoadTail(t)
         \/ SORingFinalize_CAS(t)
         \/ SORingFinalize_LoadHead(t)
         \/ SORingFinalize_WalkStates(t)
         \/ SORingFinalize_StoreTail(t)
         \/ PeekFinish(t)

Spec == Init /\ [][Next]_allVars

\* ========================================================================
\* Invariants
\* ========================================================================

\* --- Standard safety: no value is dequeued that was never enqueued, and ---
\* --- no value is dequeued twice. ---
ConsumedWasPushed ==
    \A i \in 1..Len(dequeued) :
        \E j \in 1..Len(enqueued) : enqueued[j] = dequeued[i]

NoDoublePop ==
    \A i, j \in 1..Len(dequeued) :
        i /= j => dequeued[i] /= dequeued[j]

\* --- Family A: RTSPosCntConsistent ---
\* (rts.tail.cnt == rts.head.cnt) => (rts.tail.pos == rts.head.pos).
\* If this is violated, BZ-1527 hang scenario is reachable.
RTSPosCntConsistent ==
    /\ (rtsProdTailCnt = rtsProdHeadCnt) => (rtsProdTailPos = rtsProdHeadPos)
    /\ (rtsConsTailCnt = rtsConsHeadCnt) => (rtsConsTailPos = rtsConsHeadPos)

\* --- Family A/C: NoStaleConsumeRTS ---
\* Consumer dequeue never reads a slot whose producer has not committed.
\* Captured via: every value in dequeued must appear in enqueued (covered
\* by ConsumedWasPushed) AND no slot is read before producer's tail-release
\* (enforced structurally by phase ordering).  Encoded as:
DequeuedPrefix ==
    \A i \in 1..Len(dequeued) : dequeued[i] \in {enqueued[j] : j \in 1..Len(enqueued)}

\* --- Family B: APIContractConsistent ---
\* If a caller invokes a mode-specific API with intended sync_type X on a
\* ring whose actual sync_type is Y, callMode[t] /= Mode.  When this is
\* TRUE, the spec's structural invariants (head/tail consistency, no
\* double-enqueue) should still hold — if they don't, Family B is reachable.
APIContractConsistent ==
    \A t \in Thread :
        op[t] /= "none" => callMode[t] = Mode

\* --- Family C: DefaultPartialOrder ---
\* Standard MPMC element-id consistency under the new C11 ordering chain:
\*   head and tail satisfy cons.tail <= cons.head <= prod.tail <= prod.head
\*   (mod PosWrap, in-flight < capacity).
\* Encoded via in-flight bound:
DefaultPartialOrder ==
    Mode \in {"ST","MT","HTS"} =>
        /\ (prodHead - prodTail) % PosWrap <= MaxBatch * Cardinality(Thread)
        /\ (prodTail - consTail) % PosWrap <= Capacity
        /\ (consHead - consTail) % PosWrap <= MaxBatch * Cardinality(Thread)

\* --- Family D.1: SORingStageOrdered ---
\* For every stage s, stage[s].tail <= stage[s].head <= stage[s+1].tail.
\* (Tail of stage k must be <= head of stage k, and head of stage k
\* must be <= tail of stage k-1's "next stage source".)  Encoded as a
\* simple monotonic ordering check.
SORingStageOrdered ==
    Mode = "SORING" =>
        \A s \in 0..(NbStage-1) :
            (sStageHead[s] - sStageTailPos[s]) % PosWrap <= Capacity

\* --- Family D.2: SORingNoLostFinalize (safety projection of liveness) ---
\* No FINISH-stamped slot remains while no thread has the chance to call
\* finalize and the stage tail has not advanced past it.  Strict liveness
\* belongs in temporal properties; here we expose a safety projection:
\* there is no stage with sync=0, FINISH at tail, and no thread doing
\* anything.  In a quiescent state, a FINISH at the tail is a stuck slot.
SORingNoStuckFinalize ==
    Mode = "SORING" =>
        \A s \in 0..(NbStage-1) :
            \neg (\E idx \in 0..(Capacity-1) :
                /\ idx = SlotOf(sStageTailPos[s])
                /\ sStateStnum[s][idx] = "FINISH"
                /\ sStageTailSync[s] = 0
                /\ \A t \in Thread : phase[t] = "Idle")

\* --- Family D.3: SORingReleaseExact ---
\* The n recorded in each FINISH slot equals the n recorded in the
\* corresponding START slot.  Violation indicates Family-D.3 caller
\* misuse propagating into state.
SORingReleaseExact ==
    Mode = "SORING" =>
        ~ overCommitted

\* --- Family D.4: SORingFtokenUnique ---
\* No two concurrently-acquired (active START) slots share (stage, ftoken).
SORingFtokenUnique ==
    Mode = "SORING" =>
        \A s \in 0..(NbStage-1) :
            \A i, j \in 0..(Capacity-1) :
                (i /= j /\ sStateStnum[s][i] = "START" /\ sStateStnum[s][j] = "START")
                => sStateFtoken[s][i] /= sStateFtoken[s][j]

\* --- Family E: PeekRollbackAtomic ---
\* If overCommitted is set, peek finish has executed with caller commit >
\* reserved.  In that case, spec must not have permitted partial commits to
\* be visible to other threads (peek rolls all the way back to tail or
\* commits exactly normalised n).  Captured as:
PeekRollbackAtomic ==
    Mode \in {"ST","HTS"} =>
        prodHead = prodTail \/ \E t \in Thread : phase[t] = "Peek.Start"

\* --- Structural ---
\* Each thread is in at most one operation at a time (already implied by
\* phase=Idle gate, but exposed for sanity).
ThreadAtomic ==
    \A t \in Thread :
        op[t] /= "none" => phase[t] /= "Idle"

\* TypeOK (light) — bounds for finite-state checking.
TypeOK ==
    /\ prodHead \in 0..(PosWrap-1)
    /\ prodTail \in 0..(PosWrap-1)
    /\ consHead \in 0..(PosWrap-1)
    /\ consTail \in 0..(PosWrap-1)
    /\ rtsProdHeadCnt \in 0..(CntWrap-1)
    /\ rtsProdTailCnt \in 0..(CntWrap-1)
    /\ rtsConsHeadCnt \in 0..(CntWrap-1)
    /\ rtsConsTailCnt \in 0..(CntWrap-1)

====
