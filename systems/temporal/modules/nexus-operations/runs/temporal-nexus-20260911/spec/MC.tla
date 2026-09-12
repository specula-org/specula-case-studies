------------------------------- MODULE MC -------------------------------
EXTENDS base
B == INSTANCE base

CONSTANTS TimeLimit, StartFailureLimit, CancelFailureLimit, ResponseLossLimit, RequestExpiryLimit, CallbackLimit, ReplyLossLimit, CacheLossLimit, ShardLossLimit, RefreshLimit, DuplicateLimit, WFTLimit, CloseLimit, WriteFaultLimit, MessageLimit
VARIABLE faults
mcvars == <<vars, faults>>
Limits == [Time |-> TimeLimit, StartFailure |-> StartFailureLimit, CancelFailure |-> CancelFailureLimit, ResponseLoss |-> ResponseLossLimit, RequestExpiry |-> RequestExpiryLimit, Callback |-> CallbackLimit, ReplyLoss |-> ReplyLossLimit, CacheLoss |-> CacheLossLimit, ShardLoss |-> ShardLossLimit, Refresh |-> RefreshLimit, Duplicate |-> DuplicateLimit, WFT |-> WFTLimit, Close |-> CloseLimit, WriteFault |-> WriteFaultLimit]

\* Only injected/environment actions are bounded; every reactive step passes through.
\* B!Action accesses the original body when cfg overrides Action with MCAction.

MCHandleScheduleCommand(o) ==
    /\ B!HandleScheduleCommand(o)
    /\ UNCHANGED faults

MCHandleScheduleCommandLimit(o) ==
    /\ B!HandleScheduleCommandLimit(o)
    /\ UNCHANGED faults

MCHandleCancelCommand(o) ==
    /\ B!HandleCancelCommand(o)
    /\ UNCHANGED faults

MCloadOperationArgs(t) ==
    /\ B!loadOperationArgs(t)
    /\ UNCHANGED faults

MCexecuteInvocationTask(i) ==
    /\ B!executeInvocationTask(i)
    /\ UNCHANGED faults

MCexecuteInvocationTaskBelowMin(i) ==
    /\ B!executeInvocationTaskBelowMin(i)
    /\ UNCHANGED faults

MCEndpointAccept(m,mode) ==
    /\ B!EndpointAccept(m,mode)
    /\ UNCHANGED faults

MCEndpointStartFailure(m,result) ==
    /\ faults.StartFailure < Limits.StartFailure
    /\ B!EndpointStartFailure(m,result)
    /\ faults' = [faults EXCEPT !.StartFailure = @ + 1]

MCReceiveStartResponse(m) ==
    /\ B!ReceiveStartResponse(m)
    /\ UNCHANGED faults

MCLoseResponse(m) ==
    /\ faults.ResponseLoss < Limits.ResponseLoss
    /\ B!LoseResponse(m)
    /\ faults' = [faults EXCEPT !.ResponseLoss = @ + 1]

MCRequestDeadlineExceeded(i) ==
    /\ faults.RequestExpiry < Limits.RequestExpiry
    /\ B!RequestDeadlineExceeded(i)
    /\ faults' = [faults EXCEPT !.RequestExpiry = @ + 1]

MCDiscardLateResponse(m) ==
    /\ B!DiscardLateResponse(m)
    /\ UNCHANGED faults

MCsaveStartedResult(i) ==
    /\ B!saveStartedResult(i)
    /\ UNCHANGED faults

MChandleStartOperationErrorRetryable(i) ==
    /\ B!handleStartOperationErrorRetryable(i)
    /\ UNCHANGED faults

MCsaveResultSucceeded(i) ==
    /\ B!saveResultSucceeded(i)
    /\ UNCHANGED faults

MChandleOperationErrorFailed(i) ==
    /\ B!handleOperationErrorFailed(i)
    /\ UNCHANGED faults

MChandleOperationErrorCanceled(i) ==
    /\ B!handleOperationErrorCanceled(i)
    /\ UNCHANGED faults

MChandleNonRetryableStartOperationError(i) ==
    /\ B!handleNonRetryableStartOperationError(i)
    /\ UNCHANGED faults

MChandleStartOperationErrorBelowMin(i) ==
    /\ B!handleStartOperationErrorBelowMin(i)
    /\ UNCHANGED faults

MCRejectStaleCall(i) ==
    /\ B!RejectStaleCall(i)
    /\ UNCHANGED faults

MCEndpointComplete(o,result) ==
    /\ B!EndpointComplete(o,result)
    /\ UNCHANGED faults

MCSendCompletionCallback(o) ==
    /\ faults.Callback < Limits.Callback
    /\ B!SendCompletionCallback(o)
    /\ faults' = [faults EXCEPT !.Callback = @ + 1]

MCCompletionHandlerHandle(m) ==
    /\ B!CompletionHandlerHandle(m)
    /\ UNCHANGED faults

MCCompletionHandlerReject(m) ==
    /\ B!CompletionHandlerReject(m)
    /\ UNCHANGED faults

MCloadArgsForCancelation(t) ==
    /\ B!loadArgsForCancelation(t)
    /\ UNCHANGED faults

MCexecuteCancelationTask(i) ==
    /\ B!executeCancelationTask(i)
    /\ UNCHANGED faults

MCexecuteCancelationTaskBelowMin(i) ==
    /\ B!executeCancelationTaskBelowMin(i)
    /\ UNCHANGED faults

MCEndpointCancelAck(m) ==
    /\ B!EndpointCancelAck(m)
    /\ UNCHANGED faults

MCEndpointCancelFailure(m,result) ==
    /\ faults.CancelFailure < Limits.CancelFailure
    /\ B!EndpointCancelFailure(m,result)
    /\ faults' = [faults EXCEPT !.CancelFailure = @ + 1]

MCReceiveCancelResponse(m) ==
    /\ B!ReceiveCancelResponse(m)
    /\ UNCHANGED faults

MCsaveCancelationResultAck(i) ==
    /\ B!saveCancelationResultAck(i)
    /\ UNCHANGED faults

MCsaveCancelationResultFailed(i) ==
    /\ B!saveCancelationResultFailed(i)
    /\ UNCHANGED faults

MCsaveCancelationResultRetryable(i) ==
    /\ B!saveCancelationResultRetryable(i)
    /\ UNCHANGED faults

MCexecuteStateMachineTimerTask(w) ==
    /\ B!executeStateMachineTimerTask(w)
    /\ UNCHANGED faults

MCexecuteBackoffTask(t) ==
    /\ B!executeBackoffTask(t)
    /\ UNCHANGED faults

MCexecuteCancelationBackoffTask(t) ==
    /\ B!executeCancelationBackoffTask(t)
    /\ UNCHANGED faults

MCexecuteOperationTimeout(t) ==
    /\ B!executeOperationTimeout(t)
    /\ UNCHANGED faults

MCSkipStaleTimer(t) ==
    /\ B!SkipStaleTimer(t)
    /\ UNCHANGED faults

MCFinishStateMachineTimers ==
    /\ B!FinishStateMachineTimers
    /\ UNCHANGED faults

MCGenerateDirtySubStateMachineTasks ==
    /\ B!GenerateDirtySubStateMachineTasks
    /\ UNCHANGED faults

MCAppendHistoryNodes ==
    /\ B!AppendHistoryNodes
    /\ UNCHANGED faults

MCUpdateWorkflowExecution(outcome) ==
    /\ outcome = "Success" \/ faults.WriteFault < Limits.WriteFault
    /\ B!UpdateWorkflowExecution(outcome)
    /\ faults' = IF outcome = "Success" THEN faults
                  ELSE [faults EXCEPT !.WriteFault = @ + 1]

MCConditionalWriteRejected ==
    /\ B!ConditionalWriteRejected
    /\ UNCHANGED faults

MCNotifyOnExecutionMutation ==
    /\ B!NotifyOnExecutionMutation
    /\ UNCHANGED faults

MCAccessReturn ==
    /\ B!AccessReturn
    /\ UNCHANGED faults

MCReceiveCompletionReply(r) ==
    /\ B!ReceiveCompletionReply(r)
    /\ UNCHANGED faults

MCLoseCompletionReply(r) ==
    /\ faults.ReplyLoss < Limits.ReplyLoss
    /\ B!LoseCompletionReply(r)
    /\ faults' = [faults EXCEPT !.ReplyLoss = @ + 1]

MCCacheLoss ==
    /\ faults.CacheLoss < Limits.CacheLoss
    /\ B!CacheLoss
    /\ faults' = [faults EXCEPT !.CacheLoss = @ + 1]

MCLoseShard ==
    /\ faults.ShardLoss < Limits.ShardLoss
    /\ B!LoseShard
    /\ faults' = [faults EXCEPT !.ShardLoss = @ + 1]

MCReacquireShard ==
    /\ B!ReacquireShard
    /\ UNCHANGED faults

MCLoadMutableState ==
    /\ B!LoadMutableState
    /\ UNCHANGED faults

MCRefreshWorkflowTasks ==
    /\ faults.Refresh < Limits.Refresh
    /\ B!RefreshWorkflowTasks
    /\ faults' = [faults EXCEPT !.Refresh = @ + 1]

MCDropStaleOutboundTask(t) ==
    /\ B!DropStaleOutboundTask(t)
    /\ UNCHANGED faults

MCDropStaleWake(w) ==
    /\ B!DropStaleWake(w)
    /\ UNCHANGED faults

MCDuplicateOutboundTask(t) ==
    /\ faults.Duplicate < Limits.Duplicate
    /\ B!DuplicateOutboundTask(t)
    /\ faults' = [faults EXCEPT !.Duplicate = @ + 1]

MCStartWorkflowTask ==
    /\ faults.WFT < Limits.WFT
    /\ B!StartWorkflowTask
    /\ faults' = [faults EXCEPT !.WFT = @ + 1]

MCCompleteWorkflowTask ==
    /\ B!CompleteWorkflowTask
    /\ UNCHANGED faults

MCCloseWorkflowExecution ==
    /\ faults.Close < Limits.Close
    /\ B!CloseWorkflowExecution
    /\ faults' = [faults EXCEPT !.Close = @ + 1]

MCAdvanceTime(to) ==
    /\ faults.Time < Limits.Time
    /\ B!AdvanceTime(to)
    /\ faults' = [faults EXCEPT !.Time = @ + 1]

MCInit == Init /\ faults = [k \in DOMAIN Limits |-> 0]
MCClockDomain == 1..(TimeLimit + 1)
MCNext == Next
MCSpec == MCInit /\ [][MCNext]_mcvars
\* Model values for operation identities are interchangeable; no chronological numbering.
Symmetry == Permutations(Ops)
\* Debugging projection only. Do NOT configure VIEW ProtocolView: counters affect reachability.
ProtocolView == s
MessageConstraint == Cardinality(s.messages) + Cardinality(s.replies) <= MessageLimit
MCTypeOK == TypeOK /\ DOMAIN faults = DOMAIN Limits
            /\ (\A k \in DOMAIN Limits: faults[k] \in 0..Limits[k])
\* Liveness is defined in base as EligibleProgress. Safety configs do not assert
\* it under finite TimeLimit: exhaustion could strand an otherwise eligible timer.
\* A future liveness cfg needs fair timers/commits, non-exhausted time, no symmetry.
=============================================================================
