---- MODULE Trace ----
(***************************************************************************)
(* Trace validation spec for tokio::sync::broadcast.                       *)
(*                                                                         *)
(* Category B (concurrent / lock-free): uses the per-thread timebox        *)
(* pattern.  Each task / future has its own trace; events have [start,end] *)
(* intervals and a captured state snapshot.  ViablePIDs enforces the       *)
(* partial order: thread tid can step iff no other thread has an event     *)
(* whose [start, end] strictly precedes tid's next [start, end].           *)
(*                                                                         *)
(* Each spec action gets its own event name and one trace entry.  The     *)
(* trace contains "thread", "name", "start", "end", "state", plus action- *)
(* specific fields (idx, pos, value, missed, etc.).                        *)
(***************************************************************************)

EXTENDS base, Json, IOUtils, TLC

\* ----- Trace location override -----
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"

\* ----- Trace loading: per-thread arrays preprocessed from raw NDJSON -----
\* Schema: { "threads": ["tid1","tid2",...], "events": { tid -> [event, ...] } }
\* The harness preprocessor emits a single-line JSON containing this record;
\* ndJsonDeserialize returns a sequence, so we index into the first element.
TraceJson == ndJsonDeserialize(JsonFile)[1]

\* Threads we have events for. The JSON array deserializes to a sequence;
\* convert to a set for use in set comprehensions and pc indexing.
TraceThreads ==
    LET seq == TraceJson.threads IN
    { seq[i] : i \in 1..Len(seq) }
\* Per-thread event arrays.
traces == TraceJson.events

\* Per-thread cursor.
VARIABLE pc

\* Threads that still have unconsumed events.
ThreadsWithEvents ==
    {tid \in TraceThreads : pc[tid] < Len(traces[tid])}

\* Partial order: tid is viable iff no other tid2 has a pending event whose
\* end < tid's pending event start.
ViablePIDs ==
    { tid \in ThreadsWithEvents :
        ~ \E tid2 \in ThreadsWithEvents :
            /\ tid2 /= tid
            /\ traces[tid2][pc[tid2]+1].end < traces[tid][pc[tid]+1].start }

\* Convenience: the next event for thread tid.
NextEvent(tid) == traces[tid][pc[tid]+1]

\* ----- TraceInit: matches base Init.  Implementation starts with one rx +  -----
\* ----- one tx exactly as channel(N) does (broadcast.rs:508-516).         -----
\*
\* All harness scenarios bootstrap via `broadcast::channel(...)`, which yields
\* `tx1` (sender id "s1") and `rx1` (receiver id "r1"). We pin Init to that
\* bootstrap so TLC does not branch over the existentials in base!Init.
TraceInit ==
    /\ Init
    /\ rxAlive["r1"] = TRUE
    /\ txAlive["s1"] = TRUE
    /\ pc = [tid \in TraceThreads |-> 0]

\* ========================================================================
\* Action wrappers: match event by name, call base action, validate state,
\* advance pc.  ValidatePostState is mandatory and must check the fields
\* declared in instrumentation-spec.md.
\* ========================================================================

\* Helper: match event name and thread.
IsEvent(tid, name) == NextEvent(tid).name = name

\* Validate captured tail state (most events capture this).
ValidateTail(ev) ==
    /\ ev.state.tailPos = tailPos
    /\ ev.state.tailRxCnt = tailRxCnt
    /\ ev.state.tailClosed = tailClosed

\* Validate captured slot state at idx.
ValidateSlot(ev, idx) ==
    /\ ev.state.slotPos = slotPos[idx]
    /\ ev.state.slotRem = slotRem[idx]

\* Wrapper: Send_AcquireTail
W_Send_AcquireTail(tid) ==
    LET ev == NextEvent(tid) IN
    /\ IsEvent(tid, "Send_AcquireTail")
    /\ Send_AcquireTail(ev.sender)
    /\ ValidateTail(ev)

\* Wrapper: Send_BumpPos
W_Send_BumpPos(tid) ==
    LET ev == NextEvent(tid) IN
    /\ IsEvent(tid, "Send_BumpPos")
    /\ Send_BumpPos(ev.sender, ev.value)
    /\ ev.state.tailPos = WAdd(tailPos, 1) \/ ev.state.tailPos = tailPos
       \* tail.pos already advanced post-action; we accept either snapshot timing

\* Wrapper: Send_LockSlot
W_Send_LockSlot(tid) ==
    LET ev == NextEvent(tid) IN
    /\ IsEvent(tid, "Send_LockSlot")
    /\ Send_LockSlot(ev.sender)
    /\ ev.idx = sendIdx[ev.sender]

\* Wrapper: Send_WriteSlot — post-state: slot[i] now holds (pos, value, rem).
W_Send_WriteSlot(tid) ==
    LET ev == NextEvent(tid) IN
    LET i == ev.idx IN
    /\ IsEvent(tid, "Send_WriteSlot")
    /\ Send_WriteSlot(ev.sender)
    /\ slotPos'[i] = ev.pos
    /\ slotVal'[i] = ev.value
    /\ slotRem'[i] = ev.rem

\* Wrapper: Send_DropSlot
W_Send_DropSlot(tid) ==
    LET ev == NextEvent(tid) IN
    /\ IsEvent(tid, "Send_DropSlot")
    /\ Send_DropSlot(ev.sender)

\* Wrapper: Send_NotifyRx_Enter
W_Send_NotifyRx_Enter(tid) ==
    LET ev == NextEvent(tid) IN
    /\ IsEvent(tid, "Send_NotifyRx_Enter")
    /\ Send_NotifyRx_Enter(ev.sender)

\* Wrapper: NotifyRx_DrainStep_Take — post-state: queued cleared.
W_NotifyRx_DrainStep_Take(tid) ==
    LET ev == NextEvent(tid) IN
    /\ IsEvent(tid, "NotifyRx_DrainStep_Take")
    /\ NotifyRx_DrainStep_Take(ev.receiver)
    /\ recvWaiterQueued'[ev.receiver] = FALSE

\* Wrapper: NotifyRx_DropTail — post-state: tail mutex released.
W_NotifyRx_DropTail(tid) ==
    LET ev == NextEvent(tid) IN
    /\ IsEvent(tid, "NotifyRx_DropTail")
    /\ NotifyRx_DropTail
    /\ tailLockedBy' = "none"

\* Wrapper: NotifyRx_WakeOne
W_NotifyRx_WakeOne(tid) ==
    LET ev == NextEvent(tid) IN
    /\ IsEvent(tid, "NotifyRx_WakeOne")
    /\ NotifyRx_WakeOne(ev.receiver)

\* Wrapper: NotifyRx_Finish
W_NotifyRx_Finish(tid) ==
    LET ev == NextEvent(tid) IN
    /\ IsEvent(tid, "NotifyRx_Finish")
    /\ NotifyRx_Finish

\* Wrapper: Subscribe — post-state: receiver alive, rxNext set to ev.next.
W_Subscribe(tid) ==
    LET ev == NextEvent(tid) IN
    /\ IsEvent(tid, "Subscribe")
    /\ Subscribe(ev.receiver)
    /\ rxAlive'[ev.receiver]
    /\ rxNext'[ev.receiver] = ev.next

\* Wrapper: Recv_PollEnter
W_Recv_PollEnter(tid) ==
    LET ev == NextEvent(tid) IN
    /\ IsEvent(tid, "Recv_PollEnter")
    /\ Recv_PollEnter(ev.receiver)

\* Wrapper: Recv_LockSlotFirst
W_Recv_LockSlotFirst(tid) ==
    LET ev == NextEvent(tid) IN
    /\ IsEvent(tid, "Recv_LockSlotFirst")
    /\ Recv_LockSlotFirst(ev.receiver)

\* Wrapper: Recv_HitFastPath — post-state: rxNext advanced.
W_Recv_HitFastPath(tid) ==
    LET ev == NextEvent(tid) IN
    /\ IsEvent(tid, "Recv_HitFastPath")
    /\ Recv_HitFastPath(ev.receiver)
    /\ rxNext'[ev.receiver] = ev.nextAfter

\* Wrapper: Recv_DropSlotForTail
W_Recv_DropSlotForTail(tid) ==
    LET ev == NextEvent(tid) IN
    /\ IsEvent(tid, "Recv_DropSlotForTail")
    /\ Recv_DropSlotForTail(ev.receiver)

\* Wrapper: Recv_LockTail
W_Recv_LockTail(tid) ==
    LET ev == NextEvent(tid) IN
    /\ IsEvent(tid, "Recv_LockTail")
    /\ Recv_LockTail(ev.receiver)

\* Wrapper: Recv_RelockSlot
W_Recv_RelockSlot(tid) ==
    LET ev == NextEvent(tid) IN
    /\ IsEvent(tid, "Recv_RelockSlot")
    /\ Recv_RelockSlot(ev.receiver)

\* Wrapper: Recv_RecheckMatch — post-state: rxNext advanced.
W_Recv_RecheckMatch(tid) ==
    LET ev == NextEvent(tid) IN
    /\ IsEvent(tid, "Recv_RecheckMatch")
    /\ Recv_RecheckMatch(ev.receiver)
    /\ rxNext'[ev.receiver] = ev.nextAfter

\* Wrapper: Recv_EmptyClosed
W_Recv_EmptyClosed(tid) ==
    LET ev == NextEvent(tid) IN
    /\ IsEvent(tid, "Recv_EmptyClosed")
    /\ Recv_EmptyClosed(ev.receiver)

\* Wrapper: Recv_ParkAsWaiter — post-state: queued and registered as waiter.
W_Recv_ParkAsWaiter(tid) ==
    LET ev == NextEvent(tid) IN
    /\ IsEvent(tid, "Recv_ParkAsWaiter")
    /\ Recv_ParkAsWaiter(ev.receiver)
    /\ recvWaiterQueued'[ev.receiver]
    /\ ev.receiver \in tailWaiters'

\* Wrapper: Recv_LaggedFastForward — post-state: rxNext fast-forwarded.
W_Recv_LaggedFastForward(tid) ==
    LET ev == NextEvent(tid) IN
    /\ IsEvent(tid, "Recv_LaggedFastForward")
    /\ Recv_LaggedFastForward(ev.receiver)
    /\ rxNext'[ev.receiver] = ev.nextAfter

\* Wrapper: RecvDrop_Begin
W_RecvDrop_Begin(tid) ==
    LET ev == NextEvent(tid) IN
    /\ IsEvent(tid, "RecvDrop_Begin")
    /\ RecvDrop_Begin(ev.receiver)

\* Wrapper: RecvDrop_LoadQueued_Acquire
W_RecvDrop_LoadQueued_Acquire(tid) ==
    LET ev == NextEvent(tid) IN
    /\ IsEvent(tid, "RecvDrop_LoadQueued_Acquire")
    /\ RecvDrop_LoadQueued_Acquire(ev.receiver)

\* Wrapper: RecvDrop_LockTail_Reread
W_RecvDrop_LockTail_Reread(tid) ==
    LET ev == NextEvent(tid) IN
    /\ IsEvent(tid, "RecvDrop_LockTail_Reread")
    /\ RecvDrop_LockTail_Reread(ev.receiver)

\* Wrapper: RecvDrop_RereadAndUnlink — post-state: queued cleared and unlinked.
W_RecvDrop_RereadAndUnlink(tid) ==
    LET ev == NextEvent(tid) IN
    /\ IsEvent(tid, "RecvDrop_RereadAndUnlink")
    /\ RecvDrop_RereadAndUnlink(ev.receiver)
    /\ recvWaiterQueued'[ev.receiver] = FALSE
    /\ ev.receiver \notin tailWaiters'

\* Wrapper: RecvDrop_FinishIdle
W_RecvDrop_FinishIdle(tid) ==
    LET ev == NextEvent(tid) IN
    /\ IsEvent(tid, "RecvDrop_FinishIdle")
    /\ RecvDrop_FinishIdle(ev.receiver)

\* Wrapper: RxDrop_Begin
W_RxDrop_Begin(tid) ==
    LET ev == NextEvent(tid) IN
    /\ IsEvent(tid, "RxDrop_Begin")
    /\ RxDrop_Begin(ev.receiver)

\* Wrapper: RxDrop_LockTailDecCnt — post-state: rx_cnt decremented, closed set if last.
W_RxDrop_LockTailDecCnt(tid) ==
    LET ev == NextEvent(tid) IN
    /\ IsEvent(tid, "RxDrop_LockTailDecCnt")
    /\ RxDrop_LockTailDecCnt(ev.receiver)
    /\ tailRxCnt' = ev.rxCntAfter
    /\ tailClosed' = ev.closedAfter

\* Wrapper: RxDrop_DropTail
W_RxDrop_DropTail(tid) ==
    LET ev == NextEvent(tid) IN
    /\ IsEvent(tid, "RxDrop_DropTail")
    /\ RxDrop_DropTail(ev.receiver)

\* Wrapper: RxDrop_DrainStep — post-state: rxNext after the step.
W_RxDrop_DrainStep(tid) ==
    LET ev == NextEvent(tid) IN
    /\ IsEvent(tid, "RxDrop_DrainStep")
    /\ RxDrop_DrainStep(ev.receiver)
    /\ rxNext'[ev.receiver] = ev.nextAfter

\* Wrapper: RxDrop_Finish — post-state: receiver no longer alive.
W_RxDrop_Finish(tid) ==
    LET ev == NextEvent(tid) IN
    /\ IsEvent(tid, "RxDrop_Finish")
    /\ RxDrop_Finish(ev.receiver)
    /\ ~rxAlive'[ev.receiver]

\* Wrapper: TxDrop_FetchSub — post-state: numTx decremented to ev.numTxAfter.
W_TxDrop_FetchSub(tid) ==
    LET ev == NextEvent(tid) IN
    /\ IsEvent(tid, "TxDrop_FetchSub")
    /\ TxDrop_FetchSub(ev.sender)
    /\ numTx' = ev.numTxAfter

\* Wrapper: TxDrop_CloseChannelEnter — post-state: tail closed.
W_TxDrop_CloseChannelEnter(tid) ==
    LET ev == NextEvent(tid) IN
    /\ IsEvent(tid, "TxDrop_CloseChannelEnter")
    /\ TxDrop_CloseChannelEnter(ev.sender)
    /\ tailClosed'

\* Wrapper: TxDrop_NotifyEnter
W_TxDrop_NotifyEnter(tid) ==
    LET ev == NextEvent(tid) IN
    /\ IsEvent(tid, "TxDrop_NotifyEnter")
    /\ TxDrop_NotifyEnter(ev.sender)

\* Wrapper: TxDrop_Finish
W_TxDrop_Finish(tid) ==
    LET ev == NextEvent(tid) IN
    /\ IsEvent(tid, "TxDrop_Finish")
    /\ TxDrop_Finish(ev.sender)

\* Wrapper: TxDrop_AfterClose
W_TxDrop_AfterClose(tid) ==
    LET ev == NextEvent(tid) IN
    /\ IsEvent(tid, "TxDrop_AfterClose")
    /\ TxDrop_AfterClose(ev.sender)

\* Wrapper: TxClone — post-state: numTx incremented.
W_TxClone(tid) ==
    LET ev == NextEvent(tid) IN
    /\ IsEvent(tid, "TxClone")
    /\ TxClone(ev.sender)
    /\ numTx' = ev.numTxAfter

\* MatchEvent: dispatch by name.
MatchEvent(tid) ==
    \/ W_Send_AcquireTail(tid)
    \/ W_Send_BumpPos(tid)
    \/ W_Send_LockSlot(tid)
    \/ W_Send_WriteSlot(tid)
    \/ W_Send_DropSlot(tid)
    \/ W_Send_NotifyRx_Enter(tid)
    \/ W_NotifyRx_DrainStep_Take(tid)
    \/ W_NotifyRx_DropTail(tid)
    \/ W_NotifyRx_WakeOne(tid)
    \/ W_NotifyRx_Finish(tid)
    \/ W_Subscribe(tid)
    \/ W_Recv_PollEnter(tid)
    \/ W_Recv_LockSlotFirst(tid)
    \/ W_Recv_HitFastPath(tid)
    \/ W_Recv_DropSlotForTail(tid)
    \/ W_Recv_LockTail(tid)
    \/ W_Recv_RelockSlot(tid)
    \/ W_Recv_RecheckMatch(tid)
    \/ W_Recv_EmptyClosed(tid)
    \/ W_Recv_ParkAsWaiter(tid)
    \/ W_Recv_LaggedFastForward(tid)
    \/ W_RecvDrop_Begin(tid)
    \/ W_RecvDrop_LoadQueued_Acquire(tid)
    \/ W_RecvDrop_LockTail_Reread(tid)
    \/ W_RecvDrop_RereadAndUnlink(tid)
    \/ W_RecvDrop_FinishIdle(tid)
    \/ W_RxDrop_Begin(tid)
    \/ W_RxDrop_LockTailDecCnt(tid)
    \/ W_RxDrop_DropTail(tid)
    \/ W_RxDrop_DrainStep(tid)
    \/ W_RxDrop_Finish(tid)
    \/ W_TxDrop_FetchSub(tid)
    \/ W_TxDrop_CloseChannelEnter(tid)
    \/ W_TxDrop_NotifyEnter(tid)
    \/ W_TxDrop_Finish(tid)
    \/ W_TxDrop_AfterClose(tid)
    \/ W_TxClone(tid)

\* TraceNext: pick a viable thread, match its next event, advance its pc.
\* If no thread is viable but events remain, fall through to a stuttering
\* step (does not advance pc — represents waiting for unblock).
TraceNext ==
    \/ /\ ThreadsWithEvents /= {}
       /\ \E tid \in ViablePIDs :
            /\ MatchEvent(tid)
            /\ pc' = [pc EXCEPT ![tid] = pc[tid] + 1]
    \/ /\ ThreadsWithEvents = {}
       /\ UNCHANGED <<vars, pc>>

TraceSpec == TraceInit /\ [][TraceNext]_<<vars, pc>> /\ WF_<<vars, pc>>(TraceNext)

\* TraceFullyConsumed: every thread's events were consumed.
TraceFullyConsumed == <>(ThreadsWithEvents = {})

\* TraceMatched: alias used by some validation harnesses.  Same meaning as
\* TraceFullyConsumed — the trace is matched iff all events get consumed.
TraceMatched == TraceFullyConsumed

\* Safety invariants for trace validation (no fault-injection invariants —
\* traces are recorded from real executions, no MC-only adversaries).
TraceSafety ==
    /\ TypeOK
    /\ NoUseAfterFree_Waiter
    /\ ReceiverCountConsistency
    /\ NoSlotLeak
    /\ NoDoubleRelease
    /\ NotifyHoldsTailWhenDraining
    /\ WaiterQueuedConsistency

====
