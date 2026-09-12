------------------------------ MODULE Trace ------------------------------
EXTENDS base, Json, IOUtils
VARIABLE l
tracevars == <<vars, l>>

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"
InputLog == ndJsonDeserialize(JsonFile)
TaggedLog == SelectSeq(InputLog, LAMBDA e: e.tag = "temporal-nexus")
Header == Head(TaggedLog)
TraceLog == Tail(TaggedLog)
logline == TraceLog[l]
TraceOps == Elems(Header.config.ops)
TraceCapacity == Header.config.Capacity
TraceS2C == Header.config.S2C
TraceS2S == Header.config.S2S
TraceSTC == Header.config.STC
TraceRequestTimeout == Header.config.RequestTimeout
TraceMinRequestTimeout == Header.config.MinRequestTimeout
TraceRetryDelay == Header.config.RetryDelay
TraceStartModes == Elems(Header.config.StartModes)
TraceRemoteResults == Elems(Header.config.RemoteResults)

\* JSON arrays are sequences; convert only the explicitly declared set fields.
DecodeDB(d) == [d EXCEPT !.timers = Elems(@), !.wakeScheduled = Elems(@)]
DecodeTx(t) == [t EXCEPT !.emitted = Elems(@), !.wakes = Elems(@),
                        !.deleted = Elems(@), !.consumed = Elems(@)]
DecodeState(p) ==
    [p EXCEPT !.d = DecodeDB(@), !.v = DecodeDB(@), !.tx = DecodeTx(@),
        !.queue = Elems(@), !.published = Elems(@), !.messages = Elems(@),
        !.replies = Elems(@), !.observed = Elems(@), !.notified = Elems(@),
        !.sealed = [o \in Ops |-> Elems(p.sealed[o])]]

HeaderOK ==
    /\ Header.event = "Init" /\ Header.schema = 1
    /\ Header.recordingKind \in {"implementation","synthetic"}
    /\ Header.sourceRevision = "0c010ce5fe8c0180aa7573c72fe8fc87c6df7025"
    /\ Header.route = "legacy-hsm" /\ Header.backend = "sqlite"
    /\ Header.transitionHistory /\ Header.cancelAckEvents /\ Header.outboundEnabled
    /\ ~Header.chasmWorkflowOperations /\ Header.chasmRollout = 0
    /\ Header.complete = [endpoint |-> TRUE, hsm |-> TRUE, persistence |-> TRUE,
                           tasks |-> TRUE, history |-> TRUE]
    /\ Len(TaggedLog) = Len(InputLog) /\ Len(TraceLog) > 0
    /\ Capacity > 0 /\ Ops /= {} /\ RequestTimeout >= MinRequestTimeout
    /\ S2C > 0 => (S2S <= S2C /\ STC <= S2C)

IsEvent(name) == l <= Len(TraceLog) /\ logline.event = name

CaptureSource(name) ==
    CASE name \in {"HandleScheduleCommand", "HandleScheduleCommandLimit", "HandleCancelCommand", "loadOperationArgs", "executeInvocationTaskBelowMin", "saveStartedResult", "handleStartOperationErrorRetryable", "saveResultSucceeded", "handleOperationErrorFailed", "handleOperationErrorCanceled", "handleNonRetryableStartOperationError", "handleStartOperationErrorBelowMin", "RejectStaleCall", "CompletionHandlerHandle", "CompletionHandlerReject", "loadArgsForCancelation", "executeCancelationTaskBelowMin", "saveCancelationResultAck", "saveCancelationResultFailed", "saveCancelationResultRetryable", "executeStateMachineTimerTask", "executeBackoffTask", "executeCancelationBackoffTask", "executeOperationTimeout", "SkipStaleTimer", "FinishStateMachineTimers", "GenerateDirtySubStateMachineTasks", "StartWorkflowTask", "CompleteWorkflowTask", "CloseWorkflowExecution"} -> "workflow-lock"
      [] name \in {"executeInvocationTask", "ReceiveStartResponse", "LoseResponse", "RequestDeadlineExceeded", "DiscardLateResponse", "SendCompletionCallback", "executeCancelationTask", "ReceiveCancelResponse", "ReceiveCompletionReply", "LoseCompletionReply"} -> "transport"
      [] name \in {"EndpointAccept", "EndpointStartFailure", "EndpointComplete", "EndpointCancelAck", "EndpointCancelFailure"} -> "endpoint"
      [] name \in {"AppendHistoryNodes", "UpdateWorkflowExecution", "ConditionalWriteRejected", "NotifyOnExecutionMutation", "AccessReturn"} -> "persistence"
      [] name \in {"CacheLoss", "LoseShard", "ReacquireShard", "LoadMutableState", "RefreshWorkflowTasks", "DropStaleOutboundTask", "DropStaleWake", "DuplicateOutboundTask"} -> "recovery"
      [] name \in {"AdvanceTime"} -> "clock"
      [] OTHER -> "invalid"

\* Required duplicate observations come from separate capture points. Their
\* authenticity is an evidence-review obligation; the checker verifies agreement.
ValidateEvidence(e) ==
    /\ e.provenance.receipt \in STRING /\ e.provenance.receipt /= ""
    /\ e.provenance.source = CaptureSource(e.event)
    /\ IF e.event = "UpdateWorkflowExecution"
       THEN /\ e.evidence.outcome = e.args.outcome
            /\ DecodeDB(e.evidence.durable) = s'.d
            /\ Elems(e.evidence.queue) = s'.queue
       ELSE IF e.event = "LoadMutableState"
       THEN /\ DecodeDB(e.evidence.durable) = s'.d
            /\ Elems(e.evidence.queue) = s'.queue
       ELSE IF e.event = "GenerateDirtySubStateMachineTasks"
       THEN /\ Elems(e.evidence.logicalTimers) = s'.v.timers
            /\ Elems(e.evidence.emitted) = s'.tx.emitted
       ELSE IF e.event \in {"executeInvocationTask","executeCancelationTask"}
       THEN /\ e.evidence.wire \in s'.messages
            /\ e.evidence.wire.id = e.args.i
            /\ e.evidence.wire.kind \in {"StartRequest","CancelRequest"}
       ELSE IF e.event \in {"EndpointAccept","EndpointCancelAck"}
       THEN e.evidence.endpoint = s'.remote[e.args.m.op]
       ELSE IF e.event = "EndpointComplete"
       THEN e.evidence.endpoint = s'.remote[e.args.o]
       ELSE e.evidence = [boundary |-> e.event]

\* No conditional field omission: all semantic post-state fields must be present,
\* including durable vs volatile state, timers/tasks, remote and caller knowledge.
ValidatePostState ==
    /\ s' = DecodeState(logline.post)
    /\ ValidateEvidence(logline)
    /\ logline.index = l

Trace_HandleScheduleCommand ==
    /\ IsEvent("HandleScheduleCommand")
    /\ HandleScheduleCommand(logline.args.o)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_HandleScheduleCommandLimit ==
    /\ IsEvent("HandleScheduleCommandLimit")
    /\ HandleScheduleCommandLimit(logline.args.o)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_HandleCancelCommand ==
    /\ IsEvent("HandleCancelCommand")
    /\ HandleCancelCommand(logline.args.o)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_loadOperationArgs ==
    /\ IsEvent("loadOperationArgs")
    /\ loadOperationArgs(logline.args.t)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_executeInvocationTask ==
    /\ IsEvent("executeInvocationTask")
    /\ executeInvocationTask(logline.args.i)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_executeInvocationTaskBelowMin ==
    /\ IsEvent("executeInvocationTaskBelowMin")
    /\ executeInvocationTaskBelowMin(logline.args.i)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_EndpointAccept ==
    /\ IsEvent("EndpointAccept")
    /\ EndpointAccept(logline.args.m,logline.args.mode)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_EndpointStartFailure ==
    /\ IsEvent("EndpointStartFailure")
    /\ EndpointStartFailure(logline.args.m,logline.args.result)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_ReceiveStartResponse ==
    /\ IsEvent("ReceiveStartResponse")
    /\ ReceiveStartResponse(logline.args.m)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_LoseResponse ==
    /\ IsEvent("LoseResponse")
    /\ LoseResponse(logline.args.m)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_RequestDeadlineExceeded ==
    /\ IsEvent("RequestDeadlineExceeded")
    /\ RequestDeadlineExceeded(logline.args.i)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_DiscardLateResponse ==
    /\ IsEvent("DiscardLateResponse")
    /\ DiscardLateResponse(logline.args.m)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_saveStartedResult ==
    /\ IsEvent("saveStartedResult")
    /\ saveStartedResult(logline.args.i)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_handleStartOperationErrorRetryable ==
    /\ IsEvent("handleStartOperationErrorRetryable")
    /\ handleStartOperationErrorRetryable(logline.args.i)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_saveResultSucceeded ==
    /\ IsEvent("saveResultSucceeded")
    /\ saveResultSucceeded(logline.args.i)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_handleOperationErrorFailed ==
    /\ IsEvent("handleOperationErrorFailed")
    /\ handleOperationErrorFailed(logline.args.i)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_handleOperationErrorCanceled ==
    /\ IsEvent("handleOperationErrorCanceled")
    /\ handleOperationErrorCanceled(logline.args.i)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_handleNonRetryableStartOperationError ==
    /\ IsEvent("handleNonRetryableStartOperationError")
    /\ handleNonRetryableStartOperationError(logline.args.i)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_handleStartOperationErrorBelowMin ==
    /\ IsEvent("handleStartOperationErrorBelowMin")
    /\ handleStartOperationErrorBelowMin(logline.args.i)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_RejectStaleCall ==
    /\ IsEvent("RejectStaleCall")
    /\ RejectStaleCall(logline.args.i)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_EndpointComplete ==
    /\ IsEvent("EndpointComplete")
    /\ EndpointComplete(logline.args.o,logline.args.result)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_SendCompletionCallback ==
    /\ IsEvent("SendCompletionCallback")
    /\ SendCompletionCallback(logline.args.o)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_CompletionHandlerHandle ==
    /\ IsEvent("CompletionHandlerHandle")
    /\ CompletionHandlerHandle(logline.args.m)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_CompletionHandlerReject ==
    /\ IsEvent("CompletionHandlerReject")
    /\ CompletionHandlerReject(logline.args.m)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_loadArgsForCancelation ==
    /\ IsEvent("loadArgsForCancelation")
    /\ loadArgsForCancelation(logline.args.t)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_executeCancelationTask ==
    /\ IsEvent("executeCancelationTask")
    /\ executeCancelationTask(logline.args.i)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_executeCancelationTaskBelowMin ==
    /\ IsEvent("executeCancelationTaskBelowMin")
    /\ executeCancelationTaskBelowMin(logline.args.i)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_EndpointCancelAck ==
    /\ IsEvent("EndpointCancelAck")
    /\ EndpointCancelAck(logline.args.m)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_EndpointCancelFailure ==
    /\ IsEvent("EndpointCancelFailure")
    /\ EndpointCancelFailure(logline.args.m,logline.args.result)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_ReceiveCancelResponse ==
    /\ IsEvent("ReceiveCancelResponse")
    /\ ReceiveCancelResponse(logline.args.m)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_saveCancelationResultAck ==
    /\ IsEvent("saveCancelationResultAck")
    /\ saveCancelationResultAck(logline.args.i)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_saveCancelationResultFailed ==
    /\ IsEvent("saveCancelationResultFailed")
    /\ saveCancelationResultFailed(logline.args.i)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_saveCancelationResultRetryable ==
    /\ IsEvent("saveCancelationResultRetryable")
    /\ saveCancelationResultRetryable(logline.args.i)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_executeStateMachineTimerTask ==
    /\ IsEvent("executeStateMachineTimerTask")
    /\ executeStateMachineTimerTask(logline.args.w)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_executeBackoffTask ==
    /\ IsEvent("executeBackoffTask")
    /\ executeBackoffTask(logline.args.t)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_executeCancelationBackoffTask ==
    /\ IsEvent("executeCancelationBackoffTask")
    /\ executeCancelationBackoffTask(logline.args.t)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_executeOperationTimeout ==
    /\ IsEvent("executeOperationTimeout")
    /\ executeOperationTimeout(logline.args.t)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_SkipStaleTimer ==
    /\ IsEvent("SkipStaleTimer")
    /\ SkipStaleTimer(logline.args.t)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_FinishStateMachineTimers ==
    /\ IsEvent("FinishStateMachineTimers")
    /\ FinishStateMachineTimers
    /\ ValidatePostState
    /\ l' = l + 1

Trace_GenerateDirtySubStateMachineTasks ==
    /\ IsEvent("GenerateDirtySubStateMachineTasks")
    /\ GenerateDirtySubStateMachineTasks
    /\ ValidatePostState
    /\ l' = l + 1

Trace_AppendHistoryNodes ==
    /\ IsEvent("AppendHistoryNodes")
    /\ AppendHistoryNodes
    /\ ValidatePostState
    /\ l' = l + 1

Trace_UpdateWorkflowExecution ==
    /\ IsEvent("UpdateWorkflowExecution")
    /\ UpdateWorkflowExecution(logline.args.outcome)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_ConditionalWriteRejected ==
    /\ IsEvent("ConditionalWriteRejected")
    /\ ConditionalWriteRejected
    /\ ValidatePostState
    /\ l' = l + 1

Trace_NotifyOnExecutionMutation ==
    /\ IsEvent("NotifyOnExecutionMutation")
    /\ NotifyOnExecutionMutation
    /\ ValidatePostState
    /\ l' = l + 1

Trace_AccessReturn ==
    /\ IsEvent("AccessReturn")
    /\ AccessReturn
    /\ ValidatePostState
    /\ l' = l + 1

Trace_ReceiveCompletionReply ==
    /\ IsEvent("ReceiveCompletionReply")
    /\ ReceiveCompletionReply(logline.args.r)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_LoseCompletionReply ==
    /\ IsEvent("LoseCompletionReply")
    /\ LoseCompletionReply(logline.args.r)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_CacheLoss ==
    /\ IsEvent("CacheLoss")
    /\ CacheLoss
    /\ ValidatePostState
    /\ l' = l + 1

Trace_LoseShard ==
    /\ IsEvent("LoseShard")
    /\ LoseShard
    /\ ValidatePostState
    /\ l' = l + 1

Trace_ReacquireShard ==
    /\ IsEvent("ReacquireShard")
    /\ ReacquireShard
    /\ ValidatePostState
    /\ l' = l + 1

Trace_LoadMutableState ==
    /\ IsEvent("LoadMutableState")
    /\ LoadMutableState
    /\ ValidatePostState
    /\ l' = l + 1

Trace_RefreshWorkflowTasks ==
    /\ IsEvent("RefreshWorkflowTasks")
    /\ RefreshWorkflowTasks
    /\ ValidatePostState
    /\ l' = l + 1

Trace_DropStaleOutboundTask ==
    /\ IsEvent("DropStaleOutboundTask")
    /\ DropStaleOutboundTask(logline.args.t)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_DropStaleWake ==
    /\ IsEvent("DropStaleWake")
    /\ DropStaleWake(logline.args.w)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_DuplicateOutboundTask ==
    /\ IsEvent("DuplicateOutboundTask")
    /\ DuplicateOutboundTask(logline.args.t)
    /\ ValidatePostState
    /\ l' = l + 1

Trace_StartWorkflowTask ==
    /\ IsEvent("StartWorkflowTask")
    /\ StartWorkflowTask
    /\ ValidatePostState
    /\ l' = l + 1

Trace_CompleteWorkflowTask ==
    /\ IsEvent("CompleteWorkflowTask")
    /\ CompleteWorkflowTask
    /\ ValidatePostState
    /\ l' = l + 1

Trace_CloseWorkflowExecution ==
    /\ IsEvent("CloseWorkflowExecution")
    /\ CloseWorkflowExecution
    /\ ValidatePostState
    /\ l' = l + 1

Trace_AdvanceTime ==
    /\ IsEvent("AdvanceTime")
    /\ AdvanceTime(logline.args.to)
    /\ ValidatePostState
    /\ l' = l + 1

TraceStep ==
    \/ Trace_HandleScheduleCommand
    \/ Trace_HandleScheduleCommandLimit
    \/ Trace_HandleCancelCommand
    \/ Trace_loadOperationArgs
    \/ Trace_executeInvocationTask
    \/ Trace_executeInvocationTaskBelowMin
    \/ Trace_EndpointAccept
    \/ Trace_EndpointStartFailure
    \/ Trace_ReceiveStartResponse
    \/ Trace_LoseResponse
    \/ Trace_RequestDeadlineExceeded
    \/ Trace_DiscardLateResponse
    \/ Trace_saveStartedResult
    \/ Trace_handleStartOperationErrorRetryable
    \/ Trace_saveResultSucceeded
    \/ Trace_handleOperationErrorFailed
    \/ Trace_handleOperationErrorCanceled
    \/ Trace_handleNonRetryableStartOperationError
    \/ Trace_handleStartOperationErrorBelowMin
    \/ Trace_RejectStaleCall
    \/ Trace_EndpointComplete
    \/ Trace_SendCompletionCallback
    \/ Trace_CompletionHandlerHandle
    \/ Trace_CompletionHandlerReject
    \/ Trace_loadArgsForCancelation
    \/ Trace_executeCancelationTask
    \/ Trace_executeCancelationTaskBelowMin
    \/ Trace_EndpointCancelAck
    \/ Trace_EndpointCancelFailure
    \/ Trace_ReceiveCancelResponse
    \/ Trace_saveCancelationResultAck
    \/ Trace_saveCancelationResultFailed
    \/ Trace_saveCancelationResultRetryable
    \/ Trace_executeStateMachineTimerTask
    \/ Trace_executeBackoffTask
    \/ Trace_executeCancelationBackoffTask
    \/ Trace_executeOperationTimeout
    \/ Trace_SkipStaleTimer
    \/ Trace_FinishStateMachineTimers
    \/ Trace_GenerateDirtySubStateMachineTasks
    \/ Trace_AppendHistoryNodes
    \/ Trace_UpdateWorkflowExecution
    \/ Trace_ConditionalWriteRejected
    \/ Trace_NotifyOnExecutionMutation
    \/ Trace_AccessReturn
    \/ Trace_ReceiveCompletionReply
    \/ Trace_LoseCompletionReply
    \/ Trace_CacheLoss
    \/ Trace_LoseShard
    \/ Trace_ReacquireShard
    \/ Trace_LoadMutableState
    \/ Trace_RefreshWorkflowTasks
    \/ Trace_DropStaleOutboundTask
    \/ Trace_DropStaleWake
    \/ Trace_DuplicateOutboundTask
    \/ Trace_StartWorkflowTask
    \/ Trace_CompleteWorkflowTask
    \/ Trace_CloseWorkflowExecution
    \/ Trace_AdvanceTime

\* All base actions have wrappers. There are NO silent state-changing actions.
TraceInit == Init /\ Assert(HeaderOK,"Invalid or incomplete trace header")
                  /\ Assert(s = DecodeState(Header.post),"Bootstrap state mismatch") /\ l = 1
TraceNext ==
    \/ /\ l <= Len(TraceLog) /\ TraceStep
    \/ /\ l > Len(TraceLog) /\ UNCHANGED tracevars
TraceSpec == TraceInit /\ [][TraceNext]_tracevars /\ WF_tracevars(TraceNext)
TraceMatched == <>(l > Len(TraceLog))
=============================================================================
