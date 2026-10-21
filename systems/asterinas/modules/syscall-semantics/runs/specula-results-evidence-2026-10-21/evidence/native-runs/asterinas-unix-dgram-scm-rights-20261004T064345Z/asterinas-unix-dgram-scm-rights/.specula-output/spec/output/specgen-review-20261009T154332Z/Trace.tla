---- MODULE Trace ----
EXTENDS base, Json, IOUtils

\* Category B timeboxes, grouped per thread without imposing file order.
\* The first NDJSON line is fixture metadata; every remaining line is an event.
JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"
TraceLog == ndJsonDeserialize(JsonFile)
Meta == TraceLog[1]
Events == SubSeq(TraceLog, 2, Len(TraceLog))
TraceThreads == SeqSet(Meta.receivers)
TraceAttemptSlots == Meta.attemptSlots
TraceRightsCount == Meta.rightsCount
TraceObjectA == Meta.objectA
TraceObjectB == Meta.objectB
TraceSharedTable == Meta.sharedTable
TraceSetupFDCount == Meta.setupFDCount
TraceMaxFD == Meta.maxFD
TracePayloadSize == Meta.payloadSize
TraceTIDs == SeqSet(Meta.tids)
traces == [tid \in TraceTIDs |-> SelectSeq(Events, LAMBDA e : e.tid = tid)]

VARIABLE tracePC
traceVars == <<vars, tracePC>>
ThreadsWithEvents == {tid \in TraceTIDs : tracePC[tid] <= Len(traces[tid])}
ViablePIDs ==
    {tid \in ThreadsWithEvents :
        ~\E other \in ThreadsWithEvents :
            /\ other /= tid
            /\ traces[other][tracePC[other]].end < traces[tid][tracePC[tid]].start}

\* JSON arrays encode sequences; only these five receiver fields are sets.
DecodeReceiver(r) ==
    [r EXCEPT !.installed = SeqSet(@), !.numberComplete = SeqSet(@),
              !.numberFailed = SeqSet(@), !.delivered = SeqSet(@),
              !.dirtyBytes = SeqSet(@)]

RequiredFields(name) ==
    CASE name = "SendBegin" -> {"send"}
      [] name = "FileMessageReadFrom" -> {"send", "balance"}
      [] name = "AuxiliaryDataFromControl" -> {"send"}
      [] name = "MessageQueueTrySendLock" -> {"send", "queue"}
      [] name = "MessageQueueTrySendCopy" -> {"send"}
      [] name = "MessageQueueTrySendEnqueue" -> {"send", "queue"}
      [] name = "MessageQueueTrySendUnlock" -> {"send", "queue"}
      [] name = "SendTemporaryDrop" -> {"send", "balance"}
      [] name = "SysSendmsgComplete" -> {"send"}
      [] name = "RecvBegin" -> {"rx"}
      [] name = "MessageReceiverTryRecvLock" -> {"rx", "queue"}
      [] name = "MessageReceiverTryRecvSelect" -> {"rx", "queue"}
      [] name = "MessageReceiverTryRecvCopy" -> {"rx", "queue"}
      [] name = "MessageReceiverTryRecvDequeue" -> {"rx", "queue"}
      [] name = "AuxiliaryDataGenerateControlRecv" -> {"rx"}
      [] name = "AuxiliaryDataGenerateControlPeek" -> {"rx", "queue", "balance"}
      [] name = "MessageReceiverTryRecvUnlock" -> {"rx", "queue"}
      [] name = "SysRecvmsgReleaseBorrow" -> {"rx"}
      [] name = "CUserMsgHdrWriteControl" -> {"rx"}
      [] name = "FileMessageWriteCapacity" -> {"rx"}
      [] name = "FileMessageWriteHeader" -> {"rx"}
      [] name = "FileTableInsert" -> {"rx", "slot", "balance"}
      [] name = "VmWriterWriteFd" -> {"rx"}
      [] name = "ControlMessageWriteAllTo" -> {"rx"}
      [] name = "SysRecvmsgWriteback" -> {"rx"}
      [] name = "RecvTemporaryDrop" -> {"rx", "balance"}
      [] name = "SysRecvmsgComplete" -> {"rx"}
      [] name = "RequestCleanup" -> {"cleanup"}
      [] name = "FileTableCloseFile" -> {"slot", "pendingClose", "released"}
      [] name = "ClosedFileDrop" -> {"pendingClose", "balance"}
      [] name = "SenderReuse" -> {"slot", "balance", "reuse"}
      [] name = "MessageReceiverDropBegin" -> {"queue"}
      [] name = "MessageReceiverDropReference" -> {"queue", "balance"}
      [] name = "MessageReceiverDropComplete" -> {"queue"}
      [] OTHER -> {}

TouchedSlot(e) ==
    CASE e.event = "FileTableInsert" ->
           <<ReceiverTable, rx'[e.op].fdForEntry[rx[e.op].index]>>
      [] e.event = "SenderReuse" -> SenderA
      [] OTHER -> e.args.slot

\* Fields are mandatory by event type, not optional checks that can go vacuous.
\* Only a touched FD slot is captured under its existing lock. Global refBalance
\* is checked through independently observed clone/drop deltas, not a fabricated
\* cross-thread Arc::strong_count snapshot. No trace action sets base variables.
ValidatePostState(e) ==
    /\ DOMAIN e.post = RequiredFields(e.event)
    /\ \A field \in RequiredFields(e.event) :
       CASE field = "send" -> send' = e.post.send
         [] field = "queue" -> queue' = e.post.queue
         [] field = "rx" ->
              /\ e.op \in Ops /\ e.tid = e.op[1]
              /\ rx'[e.op] = DecodeReceiver(e.post.rx)
         [] field = "slot" ->
              /\ DOMAIN e.post.slot = {"slot", "object", "origin"}
              /\ e.post.slot.slot = TouchedSlot(e)
              /\ fdTable'[TouchedSlot(e)] = e.post.slot.object
              /\ fdOrigin'[TouchedSlot(e)] = e.post.slot.origin
         [] field = "pendingClose" ->
              /\ DOMAIN e.post.pendingClose = {"slot", "object"}
              /\ e.post.pendingClose.slot = e.args.slot
              /\ closing'[e.args.slot] = e.post.pendingClose.object
         [] field = "balance" ->
              /\ Len(e.post.balance) = Cardinality(Objects)
              /\ {e.post.balance[j].object : j \in DOMAIN e.post.balance} = Objects
              /\ \A j \in DOMAIN e.post.balance :
                   LET b == e.post.balance[j] IN
                   refBalance'[b.object] - refBalance[b.object] = b.delta
         [] field = "released" ->
              releasedEntries' \ releasedEntries = SeqSet(e.post.released)
         [] field = "cleanup" -> cleanupRequested' = e.post.cleanup
         [] field = "reuse" -> senderReused' = e.post.reuse
         [] OTHER -> FALSE

\* Each case invokes the full source action before checking its post-state.
MatchEvent(e) ==
    /\ e.tag = "trace"
    /\ CASE e.event = "SendBegin" -> SendBegin(e.args.good)
         [] e.event = "FileMessageReadFrom" -> FileMessageReadFrom
         [] e.event = "AuxiliaryDataFromControl" -> AuxiliaryDataFromControl
         [] e.event = "MessageQueueTrySendLock" -> MessageQueueTrySendLock
         [] e.event = "MessageQueueTrySendCopy" -> MessageQueueTrySendCopy
         [] e.event = "MessageQueueTrySendEnqueue" -> MessageQueueTrySendEnqueue
         [] e.event = "MessageQueueTrySendUnlock" -> MessageQueueTrySendUnlock
         [] e.event = "SendTemporaryDrop" -> SendTemporaryDrop
         [] e.event = "SysSendmsgComplete" -> SysSendmsgComplete
         [] e.event = "RecvBegin" -> RecvBegin(e.op, e.args.mode, e.args.layout, e.args.good)
         [] e.event = "MessageReceiverTryRecvLock" -> MessageReceiverTryRecvLock(e.op)
         [] e.event = "MessageReceiverTryRecvSelect" -> MessageReceiverTryRecvSelect(e.op)
         [] e.event = "MessageReceiverTryRecvCopy" -> MessageReceiverTryRecvCopy(e.op)
         [] e.event = "MessageReceiverTryRecvDequeue" -> MessageReceiverTryRecvDequeue(e.op)
         [] e.event = "AuxiliaryDataGenerateControlRecv" -> AuxiliaryDataGenerateControlRecv(e.op)
         [] e.event = "AuxiliaryDataGenerateControlPeek" -> AuxiliaryDataGenerateControlPeek(e.op)
         [] e.event = "MessageReceiverTryRecvUnlock" -> MessageReceiverTryRecvUnlock(e.op)
         [] e.event = "SysRecvmsgReleaseBorrow" -> SysRecvmsgReleaseBorrow(e.op)
         [] e.event = "CUserMsgHdrWriteControl" -> CUserMsgHdrWriteControl(e.op)
         [] e.event = "FileMessageWriteCapacity" -> FileMessageWriteCapacity(e.op)
         [] e.event = "FileMessageWriteHeader" -> FileMessageWriteHeader(e.op)
         [] e.event = "FileTableInsert" -> FileTableInsert(e.op)
         [] e.event = "VmWriterWriteFd" -> VmWriterWriteFd(e.op)
         [] e.event = "ControlMessageWriteAllTo" -> ControlMessageWriteAllTo(e.op)
         [] e.event = "SysRecvmsgWriteback" -> SysRecvmsgWriteback(e.op)
         [] e.event = "RecvTemporaryDrop" -> RecvTemporaryDrop(e.op)
         [] e.event = "SysRecvmsgComplete" -> SysRecvmsgComplete(e.op)
         [] e.event = "RequestCleanup" -> RequestCleanup
         [] e.event = "FileTableCloseFile" -> FileTableCloseFile(e.args.slot)
         [] e.event = "ClosedFileDrop" -> ClosedFileDrop(e.args.slot)
         [] e.event = "SenderReuse" -> SenderReuse
         [] e.event = "MessageReceiverDropBegin" -> MessageReceiverDropBegin
         [] e.event = "MessageReceiverDropReference" -> MessageReceiverDropReference
         [] e.event = "MessageReceiverDropComplete" -> MessageReceiverDropComplete
         [] OTHER -> FALSE
    /\ ValidatePostState(e)

TraceInit ==
    /\ Assert(Len(TraceLog) > 1, "Trace must include metadata and production events")
    /\ Assert(Meta.tag = "fixture" /\ Meta.schema = 1,
              "Invalid fixture metadata or schema")
    /\ Assert(Meta.source = "0c60537098f4c2949ad2d382aaf499de72263d76" /\
              Meta.implementation = "Asterinas", "Trace source identity mismatch")
    /\ Assert(TraceThreads \subseteq TraceTIDs, "Receiver missing from fixture tids")
    /\ Assert(Meta.headerBytes = HeaderBytes /\ Meta.fdBytes = FDBytes /\
              Meta.alignment = Alignment, "Trace ABI metadata mismatch")
    /\ Assert(\A i \in DOMAIN Events :
         /\ Events[i].tag = "trace" /\ Events[i].tid \in TraceTIDs
         /\ Events[i].start <= Events[i].end
         /\ RequiredFields(Events[i].event) /= {},
         "Invalid trace event, thread, or timebox")
    /\ Assert(\A tid \in TraceTIDs :
         \A j \in 1..(Len(traces[tid]) - 1) :
             traces[tid][j].end <= traces[tid][j + 1].start,
         "Non-monotonic per-thread timestamps")
    /\ Init
    /\ tracePC = [tid \in TraceTIDs |-> 1]

TraceStep ==
    /\ ThreadsWithEvents /= {}
    /\ \E tid \in ViablePIDs :
         /\ MatchEvent(traces[tid][tracePC[tid]])
         /\ tracePC' = [tracePC EXCEPT ![tid] = @ + 1]
TraceNext ==
    \/ TraceStep
    \/ /\ ThreadsWithEvents = {}
       /\ UNCHANGED traceVars
\* Fair cursor progress rules out arbitrary stuttering on a matchable event.
\* There are no silent steps: each semantic boundary has its own hook.
TraceSpec == TraceInit /\ [][TraceNext]_traceVars /\ WF_traceVars(TraceStep)
TraceMatched == <>(ThreadsWithEvents = {})
TraceEndComplete == ThreadsWithEvents = {} =>
    /\ send.pc = "Done" /\ Quiescent /\ cleanupRequested /\ AllReleased

\* TraceSearch.cfg uses a violation of this inverse invariant as a complete
\* witness. The terminal predicate prevents a truncated path from qualifying.
TraceNoCompleteMatch == ~(ThreadsWithEvents = {} /\ TraceEndComplete)
====
