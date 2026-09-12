-------------------------------- MODULE MC --------------------------------
EXTENDS base
B == INSTANCE base
CONSTANTS FaultLimits, MaxNextEvent, MaxGeneration, MaxObjects, MaxTimers,
          MaxWorkerMessages, MaxMessageBuffer, MaxRecordVersion
VARIABLE faults
mcvars == <<s, faults>>
MCInit == B!Init /\ faults = [k \in DOMAIN FaultLimits |-> 0]

(* Only external requests and injected disruptions consume counters. Each
   guard and increment is on the same transition. Automatic due STS timers,
   client retry/soft polling expiration, message handling, effect publication,
   rollback, DB settlement and stale-message disposal are unrestricted. *)

MCUpdateWorkflowExecution(c,u,stage) ==
    /\ faults.request < FaultLimits.request
    /\ B!UpdateWorkflowExecution(c,u,stage)
    /\ faults' = [faults EXCEPT !.request = @+1]

MCUpdaterApplyRequestNew(c) ==
    /\ B!UpdaterApplyRequestNew(c)
    /\ UNCHANGED faults

MCAddWorkflowTaskScheduledEvent ==
    /\ B!AddWorkflowTaskScheduledEvent
    /\ UNCHANGED faults

MCUpdaterApplyRequestExisting(c) ==
    /\ B!UpdaterApplyRequestExisting(c)
    /\ UNCHANGED faults

MCAttachCallbacks(c) ==
    /\ faults.callback < FaultLimits.callback
    /\ B!AttachCallbacks(c)
    /\ faults' = [faults EXCEPT !.callback = @+1]

MCGetUpdateOutcome(c) ==
    /\ B!GetUpdateOutcome(c)
    /\ UNCHANGED faults

MCRegistryFindMissing(c) ==
    /\ B!RegistryFindMissing(c)
    /\ UNCHANGED faults

MCScheduleNormalWorkflowTask ==
    /\ faults.normal < FaultLimits.normal
    /\ B!ScheduleNormalWorkflowTask
    /\ faults' = [faults EXCEPT !.normal = @+1]

MCAddWorkflowTaskToMatching(i) ==
    /\ B!AddWorkflowTaskToMatching(i)
    /\ UNCHANGED faults

MCAddWorkflowTaskToMatchingFailed(i,delivered) ==
    /\ faults.matchingFailure < FaultLimits.matchingFailure
    /\ B!AddWorkflowTaskToMatchingFailed(i,delivered)
    /\ faults' = [faults EXCEPT !.matchingFailure = @+1]

MCStickyWorkerUnavailable(i) ==
    /\ faults.matchingFailure < FaultLimits.matchingFailure
    /\ B!StickyWorkerUnavailable(i)
    /\ faults' = [faults EXCEPT !.matchingFailure = @+1]

MCPushWorkflowTask ==
    /\ B!PushWorkflowTask
    /\ UNCHANGED faults

MCRecordWorkflowTaskStarted(i) ==
    /\ B!RecordWorkflowTaskStarted(i)
    /\ UNCHANGED faults

MCCreateRecordWorkflowTaskStartedResponse ==
    /\ B!CreateRecordWorkflowTaskStartedResponse
    /\ UNCHANGED faults

MCRecordWorkflowTaskStartedReturn(i) ==
    /\ B!RecordWorkflowTaskStartedReturn(i)
    /\ UNCHANGED faults

MCRecordWorkflowTaskStartedNotFound(i) ==
    /\ B!RecordWorkflowTaskStartedNotFound(i)
    /\ UNCHANGED faults

MCWorkerAcceptance(i,u) ==
    /\ B!WorkerAcceptance(i,u)
    /\ UNCHANGED faults

MCWorkerResponse(i,u,k,v) ==
    /\ B!WorkerResponse(i,u,k,v)
    /\ UNCHANGED faults

MCWorkerRejection(i,u) ==
    /\ B!WorkerRejection(i,u)
    /\ UNCHANGED faults

MCWorkerSendCompletion(i) ==
    /\ B!WorkerSendCompletion(i)
    /\ UNCHANGED faults

MCWorkerIgnoreUpdates(i) ==
    /\ faults.ignore < FaultLimits.ignore
    /\ B!WorkerIgnoreUpdates(i)
    /\ faults' = [faults EXCEPT !.ignore = @+1]

MCWorkerCloseWorkflow(i) ==
    /\ faults.close < FaultLimits.close
    /\ B!WorkerCloseWorkflow(i)
    /\ faults' = [faults EXCEPT !.close = @+1]

MCRespondWorkflowTaskCompleted(i) ==
    /\ B!RespondWorkflowTaskCompleted(i)
    /\ UNCHANGED faults

MCRespondWorkflowTaskCompletedNotFound(i) ==
    /\ B!RespondWorkflowTaskCompletedNotFound(i)
    /\ UNCHANGED faults

MCAddWorkflowTaskCompletedEvent ==
    /\ B!AddWorkflowTaskCompletedEvent
    /\ UNCHANGED faults

MCTryResurrect ==
    /\ B!TryResurrect
    /\ UNCHANGED faults

MCOnAcceptanceMsg ==
    /\ B!OnAcceptanceMsg
    /\ UNCHANGED faults

MCOnResponseMsg ==
    /\ B!OnResponseMsg
    /\ UNCHANGED faults

MCOnRejectionMsg ==
    /\ B!OnRejectionMsg
    /\ UNCHANGED faults

MCHandleMessageInvalid ==
    /\ B!HandleMessageInvalid
    /\ UNCHANGED faults

MCHandleCommandsDone ==
    /\ B!HandleCommandsDone
    /\ UNCHANGED faults

MCRejectUnprocessed(o) ==
    /\ B!RejectUnprocessed(o)
    /\ UNCHANGED faults

MCAbortAccepted(o) ==
    /\ B!AbortAccepted(o)
    /\ UNCHANGED faults

MCPrepareWorkflowMutation ==
    /\ B!PrepareWorkflowMutation
    /\ UNCHANGED faults

MCConvertSpeculativeWorkflowTaskToNormal ==
    /\ B!ConvertSpeculativeWorkflowTaskToNormal
    /\ UNCHANGED faults

MCUpdateWorkflowExecutionWithNew ==
    /\ B!UpdateWorkflowExecutionWithNew
    /\ UNCHANGED faults

MCAppendHistoryNodes ==
    /\ B!AppendHistoryNodes
    /\ UNCHANGED faults

MCExecutionTransactionCommit ==
    /\ B!ExecutionTransactionCommit
    /\ UNCHANGED faults

MCExecutionTransactionFenced ==
    /\ B!ExecutionTransactionFenced
    /\ UNCHANGED faults

MCExecutionTransactionNoncommit ==
    /\ faults.noncommit < FaultLimits.noncommit
    /\ B!ExecutionTransactionNoncommit
    /\ faults' = [faults EXCEPT !.noncommit = @+1]

MCExecutionTransactionTimeout ==
    /\ faults.uncertain < FaultLimits.uncertain
    /\ B!ExecutionTransactionTimeout
    /\ faults' = [faults EXCEPT !.uncertain = @+1]

MCAppendHistoryTimeout ==
    /\ faults.appendTimeout < FaultLimits.appendTimeout
    /\ B!AppendHistoryTimeout
    /\ faults' = [faults EXCEPT !.appendTimeout = @+1]

MCHandleWriteResult ==
    /\ B!HandleWriteResult
    /\ UNCHANGED faults

MCBufferApplyFirst ==
    /\ B!BufferApplyFirst
    /\ UNCHANGED faults

MCBufferApplySecond ==
    /\ B!BufferApplySecond
    /\ UNCHANGED faults

MCBufferApplyDone ==
    /\ B!BufferApplyDone
    /\ UNCHANGED faults

MCRegistryAbortAfterClose(o) ==
    /\ B!RegistryAbortAfterClose(o)
    /\ UNCHANGED faults

MCAddSuccessorWorkflowTask ==
    /\ B!AddSuccessorWorkflowTask
    /\ UNCHANGED faults

MCStartSuccessorWorkflowTask ==
    /\ B!StartSuccessorWorkflowTask
    /\ UNCHANGED faults

MCCreateRespondWorkflowTaskCompletedResponse ==
    /\ B!CreateRespondWorkflowTaskCompletedResponse
    /\ UNCHANGED faults

MCRespondWorkflowTaskCompletedReturn ==
    /\ B!RespondWorkflowTaskCompletedReturn
    /\ UNCHANGED faults

MCRespondWorkflowTaskCompletedLateError ==
    /\ faults.lateError < FaultLimits.lateError
    /\ B!RespondWorkflowTaskCompletedLateError
    /\ faults' = [faults EXCEPT !.lateError = @+1]

MCContextClearBegin ==
    /\ B!ContextClearBegin
    /\ UNCHANGED faults

MCRegistryClearAbort(o) ==
    /\ B!RegistryClearAbort(o)
    /\ UNCHANGED faults

MCRegistryClearAbortSecond ==
    /\ B!RegistryClearAbortSecond
    /\ UNCHANGED faults

MCContextClearDone ==
    /\ B!ContextClearDone
    /\ UNCHANGED faults

MCBufferCancel ==
    /\ B!BufferCancel
    /\ UNCHANGED faults

MCBufferCancelDone ==
    /\ B!BufferCancelDone
    /\ UNCHANGED faults

MCEvictWorkflowContext ==
    /\ faults.clear < FaultLimits.clear
    /\ B!EvictWorkflowContext
    /\ faults' = [faults EXCEPT !.clear = @+1]

MCLoseShardOwnership ==
    /\ faults.ownership < FaultLimits.ownership
    /\ B!LoseShardOwnership
    /\ faults' = [faults EXCEPT !.ownership = @+1]

MCAcquireShard(h) ==
    /\ B!AcquireShard(h)
    /\ UNCHANGED faults

MCLoadMutableState ==
    /\ B!LoadMutableState
    /\ UNCHANGED faults

MCClearStickyTaskQueue ==
    /\ B!ClearStickyTaskQueue
    /\ UNCHANGED faults

MCEvictHostEvent(h,i) ==
    /\ B!EvictHostEvent(h,i)
    /\ UNCHANGED faults

MCRestartHistoryHost(h) ==
    /\ faults.restart < FaultLimits.restart
    /\ B!RestartHistoryHost(h)
    /\ faults' = [faults EXCEPT !.restart = @+1]

MCScheduleToStartTimerEligible(i) ==
    /\ B!ScheduleToStartTimerEligible(i)
    /\ UNCHANGED faults

MCStartToCloseTimerEligible(i) ==
    /\ faults.timeout < FaultLimits.timeout
    /\ B!StartToCloseTimerEligible(i)
    /\ faults' = [faults EXCEPT !.timeout = @+1]

MCMemoryScheduledQueueSubmit(i) ==
    /\ B!MemoryScheduledQueueSubmit(i)
    /\ UNCHANGED faults

MCExecuteWorkflowTaskTimeoutTaskStale(i) ==
    /\ B!ExecuteWorkflowTaskTimeoutTaskStale(i)
    /\ UNCHANGED faults

MCExecuteWorkflowTaskTimeoutTask(i) ==
    /\ B!ExecuteWorkflowTaskTimeoutTask(i)
    /\ UNCHANGED faults

MCForceTerminateWorkflow ==
    /\ faults.limit < FaultLimits.limit
    /\ B!ForceTerminateWorkflow
    /\ faults' = [faults EXCEPT !.limit = @+1]

MCForceTerminateAbort(o) ==
    /\ B!ForceTerminateAbort(o)
    /\ UNCHANGED faults

MCForceTerminateClear ==
    /\ B!ForceTerminateClear
    /\ UNCHANGED faults

MCForceTerminatePersist ==
    /\ B!ForceTerminatePersist
    /\ UNCHANGED faults

MCRestoreHistoryLimit ==
    /\ B!RestoreHistoryLimit
    /\ UNCHANGED faults

MCTerminateWorkflowExecution ==
    /\ faults.close < FaultLimits.close
    /\ B!TerminateWorkflowExecution
    /\ faults' = [faults EXCEPT !.close = @+1]

MCTimeoutWorkflowExecution ==
    /\ faults.close < FaultLimits.close
    /\ B!TimeoutWorkflowExecution
    /\ faults' = [faults EXCEPT !.close = @+1]

MCExternalCloseReturn ==
    /\ B!ExternalCloseReturn
    /\ UNCHANGED faults

MCWaitLifecycleStageOutcome(c) ==
    /\ B!WaitLifecycleStageOutcome(c)
    /\ UNCHANGED faults

MCWaitLifecycleStageAccepted(c) ==
    /\ B!WaitLifecycleStageAccepted(c)
    /\ UNCHANGED faults

MCWaitLifecycleStageOutcomeRecheck(c) ==
    /\ B!WaitLifecycleStageOutcomeRecheck(c)
    /\ UNCHANGED faults

MCWaitLifecycleStageSoftTimeout(c) ==
    /\ B!WaitLifecycleStageSoftTimeout(c)
    /\ UNCHANGED faults

MCCreateUpdateResponse(c) ==
    /\ B!CreateUpdateResponse(c)
    /\ UNCHANGED faults

MCReceiveUpdateResponse(c) ==
    /\ B!ReceiveUpdateResponse(c)
    /\ UNCHANGED faults

MCLoseUpdateResponse(c) ==
    /\ faults.responseLoss < FaultLimits.responseLoss
    /\ B!LoseUpdateResponse(c)
    /\ faults' = [faults EXCEPT !.responseLoss = @+1]

MCRetryUpdateWorkflowExecution(c) ==
    /\ B!RetryUpdateWorkflowExecution(c)
    /\ UNCHANGED faults

MCExecutionTransactionBegin ==
    /\ B!ExecutionTransactionBegin
    /\ UNCHANGED faults

MCCrashHistoryProcess ==
    /\ faults.crash < FaultLimits.crash
    /\ B!CrashHistoryProcess
    /\ faults' = [faults EXCEPT !.crash = @+1]

MCDuplicateWorkerCompletion(i) ==
    /\ faults.duplicate < FaultLimits.duplicate
    /\ B!DuplicateWorkerCompletion(i)
    /\ faults' = [faults EXCEPT !.duplicate = @+1]

MCLoseWorkerCompletion(i) ==
    /\ faults.workerLoss < FaultLimits.workerLoss
    /\ B!LoseWorkerCompletion(i)
    /\ faults' = [faults EXCEPT !.workerLoss = @+1]

MCNext ==
    \/ \E c \in Clients, u \in Updates, stage \in {"ACCEPTED","COMPLETED"}: MCUpdateWorkflowExecution(c,u,stage)
    \/ \E c \in Clients: MCUpdaterApplyRequestNew(c) \/ MCUpdaterApplyRequestExisting(c) \/ MCAttachCallbacks(c)
          \/ MCGetUpdateOutcome(c) \/ MCRegistryFindMissing(c) \/ MCWaitLifecycleStageOutcome(c)
          \/ MCWaitLifecycleStageAccepted(c) \/ MCWaitLifecycleStageOutcomeRecheck(c)
          \/ MCWaitLifecycleStageSoftTimeout(c) \/ MCCreateUpdateResponse(c) \/ MCReceiveUpdateResponse(c)
          \/ MCLoseUpdateResponse(c) \/ MCRetryUpdateWorkflowExecution(c)
    \/ \E i \in 1..Len(s.dispatch): MCAddWorkflowTaskToMatching(i) \/ MCStickyWorkerUnavailable(i)
          \/ (\E delivered \in BOOLEAN: MCAddWorkflowTaskToMatchingFailed(i,delivered))
    \/ \E i \in 1..Len(s.matching): MCRecordWorkflowTaskStarted(i) \/ MCRecordWorkflowTaskStartedNotFound(i)
    \/ \E i \in 1..Len(s.workers):
          \/ (\E u \in Updates: MCWorkerAcceptance(i,u) \/ MCWorkerRejection(i,u)
                 \/ (\E k \in WorkerKinds, v \in Values: MCWorkerResponse(i,u,k,v)))
          \/ MCWorkerSendCompletion(i) \/ MCWorkerIgnoreUpdates(i) \/ MCWorkerCloseWorkflow(i)
          \/ MCRespondWorkflowTaskCompleted(i) \/ MCRespondWorkflowTaskCompletedNotFound(i)
          \/ MCDuplicateWorkerCompletion(i) \/ MCLoseWorkerCompletion(i) \/ MCRecordWorkflowTaskStartedReturn(i)
    \/ \E o \in 1..Len(s.objects): MCRejectUnprocessed(o) \/ MCAbortAccepted(o)
          \/ MCRegistryAbortAfterClose(o) \/ MCRegistryClearAbort(o) \/ MCForceTerminateAbort(o)
    \/ \E i \in 1..Len(s.timers): MCScheduleToStartTimerEligible(i) \/ MCStartToCloseTimerEligible(i)
          \/ MCMemoryScheduledQueueSubmit(i) \/ MCExecuteWorkflowTaskTimeoutTask(i) \/ MCExecuteWorkflowTaskTimeoutTaskStale(i)
    \/ \E h \in Hosts: MCAcquireShard(h) \/ MCRestartHistoryHost(h) \/ (\E i \in 1..Len(s.cache[h]): MCEvictHostEvent(h,i))
    \/ MCAddWorkflowTaskScheduledEvent \/ MCScheduleNormalWorkflowTask \/ MCPushWorkflowTask
    \/ MCCreateRecordWorkflowTaskStartedResponse \/ MCAddWorkflowTaskCompletedEvent \/ MCTryResurrect
    \/ MCOnAcceptanceMsg \/ MCOnResponseMsg \/ MCOnRejectionMsg \/ MCHandleMessageInvalid \/ MCHandleCommandsDone
    \/ MCPrepareWorkflowMutation \/ MCConvertSpeculativeWorkflowTaskToNormal \/ MCUpdateWorkflowExecutionWithNew
    \/ MCAppendHistoryNodes \/ MCExecutionTransactionBegin \/ MCExecutionTransactionCommit \/ MCExecutionTransactionFenced
    \/ MCExecutionTransactionNoncommit \/ MCExecutionTransactionTimeout \/ MCAppendHistoryTimeout \/ MCHandleWriteResult
    \/ MCBufferApplyFirst \/ MCBufferApplySecond \/ MCBufferApplyDone \/ MCAddSuccessorWorkflowTask \/ MCStartSuccessorWorkflowTask
    \/ MCCreateRespondWorkflowTaskCompletedResponse \/ MCRespondWorkflowTaskCompletedReturn \/ MCRespondWorkflowTaskCompletedLateError
    \/ MCContextClearBegin \/ MCRegistryClearAbortSecond \/ MCContextClearDone \/ MCBufferCancel \/ MCBufferCancelDone
    \/ MCEvictWorkflowContext \/ MCLoseShardOwnership \/ MCLoadMutableState \/ MCClearStickyTaskQueue \/ MCCrashHistoryProcess
    \/ MCTerminateWorkflowExecution \/ MCTimeoutWorkflowExecution \/ MCExternalCloseReturn
    \/ MCForceTerminateWorkflow \/ MCForceTerminateClear \/ MCForceTerminatePersist \/ MCRestoreHistoryLimit
MCSpec == MCInit /\ [][MCNext]_mcvars
MCSymmetry == Permutations(Updates) \cup Permutations(Values) \cup Permutations(Clients)
(* InitialHost distinguishes a host. Do not permute Hosts. Do not enable
   symmetry for temporal checking. Counter-free view is inspection only:
   it is intentionally not configured as TLC VIEW, since budgets affect enabledness. *)
MCView == s
MCConstraint ==
    /\ s.db.next <= MaxNextEvent /\ s.ctx.next <= MaxNextEvent
    /\ s.ctx.generation <= MaxGeneration /\ s.db.rv <= MaxRecordVersion
    /\ Len(s.objects) <= MaxObjects /\ Len(s.timers) <= MaxTimers
    /\ Len(s.workers) <= MaxWorkerMessages
    /\ Len(s.matching)+Len(s.dispatch) <= MaxMessageBuffer
MCTypeOK == TypeOK /\ DOMAIN faults = DOMAIN FaultLimits /\
    (\A k \in DOMAIN faults: faults[k] \in 0..FaultLimits[k])

(* Fairness assumptions are action-specific. Eventually processing eligible
   timers, persistence completion, available Matching/worker service, finite
   fault injection, and continuing interested client retries are required.
   No fairness is imposed on fault injection, closure, cache loss or limits.
   Workers may accept without completing in this slice; acceptance suffices
   for admission progress. A durable completion is polled until received.
   Progress cfgs omit MCConstraint and symmetry: finite search frontiers
   must not manufacture (or suppress) a liveness counterexample. *)
ServiceFairness ==
    /\ WF_mcvars((\E c \in Clients: MCUpdaterApplyRequestNew(c)))
    /\ WF_mcvars(MCAddWorkflowTaskScheduledEvent)
    /\ WF_mcvars((\E c \in Clients: MCUpdaterApplyRequestExisting(c)))
    /\ WF_mcvars((\E c \in Clients: MCGetUpdateOutcome(c)))
    /\ WF_mcvars((\E c \in Clients: MCRegistryFindMissing(c)))
    /\ WF_mcvars((\E i \in 1..Len(s.dispatch): MCAddWorkflowTaskToMatching(i)))
    /\ WF_mcvars(MCPushWorkflowTask)
    /\ WF_mcvars((\E i \in 1..Len(s.matching): MCRecordWorkflowTaskStarted(i)))
    /\ WF_mcvars(MCCreateRecordWorkflowTaskStartedResponse)
    /\ WF_mcvars((\E i \in 1..Len(s.workers): MCRecordWorkflowTaskStartedReturn(i)))
    /\ WF_mcvars((\E i \in 1..Len(s.matching): MCRecordWorkflowTaskStartedNotFound(i)))
    /\ WF_mcvars((\E i \in 1..Len(s.workers): MCRespondWorkflowTaskCompleted(i)))
    /\ WF_mcvars((\E i \in 1..Len(s.workers): MCRespondWorkflowTaskCompletedNotFound(i)))
    /\ WF_mcvars(MCAddWorkflowTaskCompletedEvent)
    /\ WF_mcvars(MCTryResurrect)
    /\ WF_mcvars(MCOnAcceptanceMsg)
    /\ WF_mcvars(MCOnResponseMsg)
    /\ WF_mcvars(MCOnRejectionMsg)
    /\ WF_mcvars(MCHandleMessageInvalid)
    /\ WF_mcvars(MCHandleCommandsDone)
    /\ WF_mcvars((\E o \in 1..Len(s.objects): MCRejectUnprocessed(o)))
    /\ WF_mcvars((\E o \in 1..Len(s.objects): MCAbortAccepted(o)))
    /\ WF_mcvars(MCPrepareWorkflowMutation)
    /\ WF_mcvars(MCConvertSpeculativeWorkflowTaskToNormal)
    /\ WF_mcvars(MCUpdateWorkflowExecutionWithNew)
    /\ WF_mcvars(MCAppendHistoryNodes)
    /\ WF_mcvars(MCExecutionTransactionCommit)
    /\ WF_mcvars(MCExecutionTransactionFenced)
    /\ WF_mcvars(MCHandleWriteResult)
    /\ WF_mcvars(MCBufferApplyFirst)
    /\ WF_mcvars(MCBufferApplySecond)
    /\ WF_mcvars(MCBufferApplyDone)
    /\ WF_mcvars((\E o \in 1..Len(s.objects): MCRegistryAbortAfterClose(o)))
    /\ WF_mcvars(MCAddSuccessorWorkflowTask)
    /\ WF_mcvars(MCStartSuccessorWorkflowTask)
    /\ WF_mcvars(MCCreateRespondWorkflowTaskCompletedResponse)
    /\ WF_mcvars(MCRespondWorkflowTaskCompletedReturn)
    /\ WF_mcvars(MCContextClearBegin)
    /\ WF_mcvars((\E o \in 1..Len(s.objects): MCRegistryClearAbort(o)))
    /\ WF_mcvars(MCRegistryClearAbortSecond)
    /\ WF_mcvars(MCContextClearDone)
    /\ WF_mcvars(MCBufferCancel)
    /\ WF_mcvars(MCBufferCancelDone)
    /\ WF_mcvars((\E h \in Hosts: MCAcquireShard(h)))
    /\ WF_mcvars(MCLoadMutableState)
    /\ WF_mcvars(MCClearStickyTaskQueue)
    /\ WF_mcvars((\E i \in 1..Len(s.timers): MCScheduleToStartTimerEligible(i)))
    /\ WF_mcvars((\E i \in 1..Len(s.timers): MCMemoryScheduledQueueSubmit(i)))
    /\ WF_mcvars((\E i \in 1..Len(s.timers): MCExecuteWorkflowTaskTimeoutTaskStale(i)))
    /\ WF_mcvars((\E i \in 1..Len(s.timers): MCExecuteWorkflowTaskTimeoutTask(i)))
    /\ WF_mcvars((\E o \in 1..Len(s.objects): MCForceTerminateAbort(o)))
    /\ WF_mcvars(MCForceTerminateClear)
    /\ WF_mcvars(MCForceTerminatePersist)
    /\ WF_mcvars(MCExternalCloseReturn)
    /\ WF_mcvars((\E c \in Clients: MCWaitLifecycleStageOutcome(c)))
    /\ WF_mcvars((\E c \in Clients: MCWaitLifecycleStageAccepted(c)))
    /\ WF_mcvars((\E c \in Clients: MCWaitLifecycleStageOutcomeRecheck(c)))
    /\ WF_mcvars((\E c \in Clients: MCWaitLifecycleStageSoftTimeout(c)))
    /\ WF_mcvars((\E c \in Clients: MCCreateUpdateResponse(c)))
    /\ WF_mcvars((\E c \in Clients: MCReceiveUpdateResponse(c)))
    /\ WF_mcvars((\E c \in Clients: MCRetryUpdateWorkflowExecution(c)))
    /\ WF_mcvars(MCExecutionTransactionBegin)
WorkerFairness ==
    /\ SF_mcvars(\E i \in 1..Len(s.workers), u \in Updates: MCWorkerAcceptance(i,u) \/ MCWorkerRejection(i,u))
    /\ SF_mcvars(\E i \in 1..Len(s.workers): MCWorkerSendCompletion(i))
ClientFairness ==
    \A c \in Clients:
        /\ WF_mcvars(MCUpdaterApplyRequestNew(c) \/ MCUpdaterApplyRequestExisting(c) \/ MCGetUpdateOutcome(c) \/ MCRegistryFindMissing(c))
        /\ WF_mcvars(MCWaitLifecycleStageOutcome(c))
        /\ WF_mcvars(MCWaitLifecycleStageAccepted(c))
        /\ WF_mcvars(MCWaitLifecycleStageOutcomeRecheck(c))
        /\ WF_mcvars(MCWaitLifecycleStageSoftTimeout(c))
        /\ WF_mcvars(MCCreateUpdateResponse(c))
        /\ WF_mcvars(MCReceiveUpdateResponse(c))
        /\ WF_mcvars(MCRetryUpdateWorkflowExecution(c))
MCProgressSpec == MCSpec /\ ServiceFairness /\ WorkerFairness /\ ClientFairness
MCLimits == [appendTimeout |-> 1, callback |-> 0, clear |-> 1, close |-> 1, crash |-> 1, duplicate |-> 1, ignore |-> 1, lateError |-> 1, limit |-> 0, matchingFailure |-> 1, noncommit |-> 1, normal |-> 1, ownership |-> 2, request |-> 2, responseLoss |-> 1, restart |-> 1, timeout |-> 1, uncertain |-> 1, workerLoss |-> 1]
MC_hunt_scenario_1Limits == [appendTimeout |-> 0, callback |-> 0, clear |-> 1, close |-> 0, crash |-> 1, duplicate |-> 0, ignore |-> 0, lateError |-> 1, limit |-> 0, matchingFailure |-> 0, noncommit |-> 1, normal |-> 1, ownership |-> 2, request |-> 3, responseLoss |-> 1, restart |-> 0, timeout |-> 0, uncertain |-> 1, workerLoss |-> 0]
MC_hunt_scenario_2Limits == [appendTimeout |-> 0, callback |-> 1, clear |-> 2, close |-> 0, crash |-> 0, duplicate |-> 1, ignore |-> 0, lateError |-> 0, limit |-> 0, matchingFailure |-> 1, noncommit |-> 0, normal |-> 0, ownership |-> 0, request |-> 2, responseLoss |-> 0, restart |-> 0, timeout |-> 2, uncertain |-> 0, workerLoss |-> 1]
MC_hunt_scenario_3Limits == [appendTimeout |-> 0, callback |-> 0, clear |-> 0, close |-> 1, crash |-> 0, duplicate |-> 0, ignore |-> 0, lateError |-> 1, limit |-> 0, matchingFailure |-> 0, noncommit |-> 0, normal |-> 1, ownership |-> 0, request |-> 2, responseLoss |-> 1, restart |-> 0, timeout |-> 0, uncertain |-> 1, workerLoss |-> 0]
MC_hunt_scenario_4Limits == [appendTimeout |-> 0, callback |-> 1, clear |-> 1, close |-> 0, crash |-> 0, duplicate |-> 1, ignore |-> 2, lateError |-> 0, limit |-> 0, matchingFailure |-> 2, noncommit |-> 0, normal |-> 0, ownership |-> 0, request |-> 2, responseLoss |-> 1, restart |-> 0, timeout |-> 1, uncertain |-> 0, workerLoss |-> 0]
MC_hunt_MC_4_cacheLimits == [appendTimeout |-> 0, callback |-> 0, clear |-> 0, close |-> 0, crash |-> 0, duplicate |-> 0, ignore |-> 0, lateError |-> 0, limit |-> 0, matchingFailure |-> 0, noncommit |-> 1, normal |-> 0, ownership |-> 2, request |-> 3, responseLoss |-> 0, restart |-> 0, timeout |-> 0, uncertain |-> 0, workerLoss |-> 0]
MC_hunt_CR_5_limitLimits == [appendTimeout |-> 0, callback |-> 0, clear |-> 0, close |-> 0, crash |-> 0, duplicate |-> 0, ignore |-> 0, lateError |-> 0, limit |-> 1, matchingFailure |-> 0, noncommit |-> 1, normal |-> 2, ownership |-> 0, request |-> 2, responseLoss |-> 0, restart |-> 0, timeout |-> 0, uncertain |-> 0, workerLoss |-> 0]
MC_hunt_scenario_2_progressLimits == [appendTimeout |-> 0, callback |-> 1, clear |-> 2, close |-> 0, crash |-> 0, duplicate |-> 1, ignore |-> 0, lateError |-> 0, limit |-> 0, matchingFailure |-> 1, noncommit |-> 0, normal |-> 0, ownership |-> 0, request |-> 2, responseLoss |-> 0, restart |-> 0, timeout |-> 2, uncertain |-> 0, workerLoss |-> 1]
MC_hunt_scenario_4_progressLimits == [appendTimeout |-> 0, callback |-> 1, clear |-> 1, close |-> 0, crash |-> 0, duplicate |-> 1, ignore |-> 2, lateError |-> 0, limit |-> 0, matchingFailure |-> 2, noncommit |-> 0, normal |-> 0, ownership |-> 0, request |-> 2, responseLoss |-> 1, restart |-> 0, timeout |-> 1, uncertain |-> 0, workerLoss |-> 0]
=============================================================================
