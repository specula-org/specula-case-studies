------------------------------- MODULE Trace -------------------------------
EXTENDS base, Json, IOUtils
B == INSTANCE base
VARIABLE l
tracevars == <<s,l>>

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"
TraceInput == ndJsonDeserialize(JsonFile)
TraceHeaders == SelectSeq(TraceInput,LAMBDA e: e.tag = "temporal-update.meta")
TraceMeta == Head(TraceHeaders)
TraceLog == SelectSeq(TraceInput,LAMBDA e: e.tag = "temporal-update")
TraceUpdates == SeqSet(TraceMeta.constants.updates)
TraceValues == SeqSet(TraceMeta.constants.values)
TraceClients == SeqSet(TraceMeta.constants.clients)
TraceHosts == SeqSet(TraceMeta.constants.hosts)
TraceInitialHost == TraceMeta.constants.initialHost
TraceNamespaceID == TraceMeta.constants.namespaceID
TraceWorkflowID == TraceMeta.constants.workflowID
TraceRunID == TraceMeta.constants.runID
TraceEventVersion == TraceMeta.constants.eventVersion
TraceHostCacheEnabled == TraceMeta.constants.hostCacheEnabled

(* JSON arrays encode both ordered sequences and unordered finite sets.
   These are ALL set-valued fields; everything else is compared verbatim.
   Keyed maps use the exact string IDs declared in the metadata header.
   No captured field is optional and no post-state field is silently ignored. *)
DecodeState(p) ==
    [p EXCEPT !.clearTodo = SeqSet(@), !.rejectTodo = SeqSet(@),
         !.everRequested = SeqSet(@), !.observed = SeqSet(@),
         !.applied = SeqSet(@), !.timeoutApplications = SeqSet(@),
         !.workers = [i \in 1..Len(p.workers) |->
             [p.workers[i] EXCEPT !.delivered = SeqSet(@), !.accepted = SeqSet(@)]]]
TraceInit ==
    /\ Len(TraceHeaders) = 1
    /\ TraceMeta.schema = 1
    /\ TraceMeta.sourceRevision = "0c010ce5fe8c0180aa7573c72fe8fc87c6df7025"
    /\ Len(TraceLog) > 0
    /\ B!Init
    /\ s = DecodeState(TraceMeta.initialState)
    /\ l = 1
logline == TraceLog[l]
IsEvent(name) == logline.event = name
ValidatePostState ==
    /\ DOMAIN logline = {"tag","event","ordinal","params","post"}
    /\ DOMAIN logline.post = DOMAIN s
    /\ s' = DecodeState(logline.post)
    /\ logline.ordinal = l
Advance == l' = l+1

(* One wrapper per base action, without skipping its guards or updates.
   See instrumentation-spec.md for source location, boundary and all fields. *)

TraceUpdateWorkflowExecution ==
    /\ IsEvent("UpdateWorkflowExecution")
    /\ DOMAIN logline.params = {"c","u","stage"}
    /\ B!UpdateWorkflowExecution(logline.params.c,logline.params.u,logline.params.stage)
    /\ ValidatePostState
    /\ Advance

TraceUpdaterApplyRequestNew ==
    /\ IsEvent("UpdaterApplyRequestNew")
    /\ DOMAIN logline.params = {"c"}
    /\ B!UpdaterApplyRequestNew(logline.params.c)
    /\ ValidatePostState
    /\ Advance

TraceAddWorkflowTaskScheduledEvent ==
    /\ IsEvent("AddWorkflowTaskScheduledEvent")
    /\ DOMAIN logline.params = {}
    /\ B!AddWorkflowTaskScheduledEvent
    /\ ValidatePostState
    /\ Advance

TraceUpdaterApplyRequestExisting ==
    /\ IsEvent("UpdaterApplyRequestExisting")
    /\ DOMAIN logline.params = {"c"}
    /\ B!UpdaterApplyRequestExisting(logline.params.c)
    /\ ValidatePostState
    /\ Advance

TraceAttachCallbacks ==
    /\ IsEvent("AttachCallbacks")
    /\ DOMAIN logline.params = {"c"}
    /\ B!AttachCallbacks(logline.params.c)
    /\ ValidatePostState
    /\ Advance

TraceGetUpdateOutcome ==
    /\ IsEvent("GetUpdateOutcome")
    /\ DOMAIN logline.params = {"c"}
    /\ B!GetUpdateOutcome(logline.params.c)
    /\ ValidatePostState
    /\ Advance

TraceRegistryFindMissing ==
    /\ IsEvent("RegistryFindMissing")
    /\ DOMAIN logline.params = {"c"}
    /\ B!RegistryFindMissing(logline.params.c)
    /\ ValidatePostState
    /\ Advance

TraceScheduleNormalWorkflowTask ==
    /\ IsEvent("ScheduleNormalWorkflowTask")
    /\ DOMAIN logline.params = {}
    /\ B!ScheduleNormalWorkflowTask
    /\ ValidatePostState
    /\ Advance

TraceAddWorkflowTaskToMatching ==
    /\ IsEvent("AddWorkflowTaskToMatching")
    /\ DOMAIN logline.params = {"i"}
    /\ B!AddWorkflowTaskToMatching(logline.params.i)
    /\ ValidatePostState
    /\ Advance

TraceAddWorkflowTaskToMatchingFailed ==
    /\ IsEvent("AddWorkflowTaskToMatchingFailed")
    /\ DOMAIN logline.params = {"i","delivered"}
    /\ B!AddWorkflowTaskToMatchingFailed(logline.params.i,logline.params.delivered)
    /\ ValidatePostState
    /\ Advance

TraceStickyWorkerUnavailable ==
    /\ IsEvent("StickyWorkerUnavailable")
    /\ DOMAIN logline.params = {"i"}
    /\ B!StickyWorkerUnavailable(logline.params.i)
    /\ ValidatePostState
    /\ Advance

TracePushWorkflowTask ==
    /\ IsEvent("PushWorkflowTask")
    /\ DOMAIN logline.params = {}
    /\ B!PushWorkflowTask
    /\ ValidatePostState
    /\ Advance

TraceRecordWorkflowTaskStarted ==
    /\ IsEvent("RecordWorkflowTaskStarted")
    /\ DOMAIN logline.params = {"i"}
    /\ B!RecordWorkflowTaskStarted(logline.params.i)
    /\ ValidatePostState
    /\ Advance

TraceCreateRecordWorkflowTaskStartedResponse ==
    /\ IsEvent("CreateRecordWorkflowTaskStartedResponse")
    /\ DOMAIN logline.params = {}
    /\ B!CreateRecordWorkflowTaskStartedResponse
    /\ ValidatePostState
    /\ Advance

TraceRecordWorkflowTaskStartedReturn ==
    /\ IsEvent("RecordWorkflowTaskStartedReturn")
    /\ DOMAIN logline.params = {"i"}
    /\ B!RecordWorkflowTaskStartedReturn(logline.params.i)
    /\ ValidatePostState
    /\ Advance

TraceRecordWorkflowTaskStartedNotFound ==
    /\ IsEvent("RecordWorkflowTaskStartedNotFound")
    /\ DOMAIN logline.params = {"i"}
    /\ B!RecordWorkflowTaskStartedNotFound(logline.params.i)
    /\ ValidatePostState
    /\ Advance

TraceWorkerAcceptance ==
    /\ IsEvent("WorkerAcceptance")
    /\ DOMAIN logline.params = {"i","u"}
    /\ B!WorkerAcceptance(logline.params.i,logline.params.u)
    /\ ValidatePostState
    /\ Advance

TraceWorkerResponse ==
    /\ IsEvent("WorkerResponse")
    /\ DOMAIN logline.params = {"i","u","k","v"}
    /\ B!WorkerResponse(logline.params.i,logline.params.u,logline.params.k,logline.params.v)
    /\ ValidatePostState
    /\ Advance

TraceWorkerRejection ==
    /\ IsEvent("WorkerRejection")
    /\ DOMAIN logline.params = {"i","u"}
    /\ B!WorkerRejection(logline.params.i,logline.params.u)
    /\ ValidatePostState
    /\ Advance

TraceWorkerSendCompletion ==
    /\ IsEvent("WorkerSendCompletion")
    /\ DOMAIN logline.params = {"i"}
    /\ B!WorkerSendCompletion(logline.params.i)
    /\ ValidatePostState
    /\ Advance

TraceWorkerIgnoreUpdates ==
    /\ IsEvent("WorkerIgnoreUpdates")
    /\ DOMAIN logline.params = {"i"}
    /\ B!WorkerIgnoreUpdates(logline.params.i)
    /\ ValidatePostState
    /\ Advance

TraceWorkerCloseWorkflow ==
    /\ IsEvent("WorkerCloseWorkflow")
    /\ DOMAIN logline.params = {"i"}
    /\ B!WorkerCloseWorkflow(logline.params.i)
    /\ ValidatePostState
    /\ Advance

TraceRespondWorkflowTaskCompleted ==
    /\ IsEvent("RespondWorkflowTaskCompleted")
    /\ DOMAIN logline.params = {"i"}
    /\ B!RespondWorkflowTaskCompleted(logline.params.i)
    /\ ValidatePostState
    /\ Advance

TraceRespondWorkflowTaskCompletedNotFound ==
    /\ IsEvent("RespondWorkflowTaskCompletedNotFound")
    /\ DOMAIN logline.params = {"i"}
    /\ B!RespondWorkflowTaskCompletedNotFound(logline.params.i)
    /\ ValidatePostState
    /\ Advance

TraceAddWorkflowTaskCompletedEvent ==
    /\ IsEvent("AddWorkflowTaskCompletedEvent")
    /\ DOMAIN logline.params = {}
    /\ B!AddWorkflowTaskCompletedEvent
    /\ ValidatePostState
    /\ Advance

TraceTryResurrect ==
    /\ IsEvent("TryResurrect")
    /\ DOMAIN logline.params = {}
    /\ B!TryResurrect
    /\ ValidatePostState
    /\ Advance

TraceOnAcceptanceMsg ==
    /\ IsEvent("OnAcceptanceMsg")
    /\ DOMAIN logline.params = {}
    /\ B!OnAcceptanceMsg
    /\ ValidatePostState
    /\ Advance

TraceOnResponseMsg ==
    /\ IsEvent("OnResponseMsg")
    /\ DOMAIN logline.params = {}
    /\ B!OnResponseMsg
    /\ ValidatePostState
    /\ Advance

TraceOnRejectionMsg ==
    /\ IsEvent("OnRejectionMsg")
    /\ DOMAIN logline.params = {}
    /\ B!OnRejectionMsg
    /\ ValidatePostState
    /\ Advance

TraceHandleMessageInvalid ==
    /\ IsEvent("HandleMessageInvalid")
    /\ DOMAIN logline.params = {}
    /\ B!HandleMessageInvalid
    /\ ValidatePostState
    /\ Advance

TraceHandleCommandsDone ==
    /\ IsEvent("HandleCommandsDone")
    /\ DOMAIN logline.params = {}
    /\ B!HandleCommandsDone
    /\ ValidatePostState
    /\ Advance

TraceRejectUnprocessed ==
    /\ IsEvent("RejectUnprocessed")
    /\ DOMAIN logline.params = {"o"}
    /\ B!RejectUnprocessed(logline.params.o)
    /\ ValidatePostState
    /\ Advance

TraceAbortAccepted ==
    /\ IsEvent("AbortAccepted")
    /\ DOMAIN logline.params = {"o"}
    /\ B!AbortAccepted(logline.params.o)
    /\ ValidatePostState
    /\ Advance

TracePrepareWorkflowMutation ==
    /\ IsEvent("PrepareWorkflowMutation")
    /\ DOMAIN logline.params = {}
    /\ B!PrepareWorkflowMutation
    /\ ValidatePostState
    /\ Advance

TraceConvertSpeculativeWorkflowTaskToNormal ==
    /\ IsEvent("ConvertSpeculativeWorkflowTaskToNormal")
    /\ DOMAIN logline.params = {}
    /\ B!ConvertSpeculativeWorkflowTaskToNormal
    /\ ValidatePostState
    /\ Advance

TraceUpdateWorkflowExecutionWithNew ==
    /\ IsEvent("UpdateWorkflowExecutionWithNew")
    /\ DOMAIN logline.params = {}
    /\ B!UpdateWorkflowExecutionWithNew
    /\ ValidatePostState
    /\ Advance

TraceAppendHistoryNodes ==
    /\ IsEvent("AppendHistoryNodes")
    /\ DOMAIN logline.params = {}
    /\ B!AppendHistoryNodes
    /\ ValidatePostState
    /\ Advance

TraceExecutionTransactionCommit ==
    /\ IsEvent("ExecutionTransactionCommit")
    /\ DOMAIN logline.params = {}
    /\ B!ExecutionTransactionCommit
    /\ ValidatePostState
    /\ Advance

TraceExecutionTransactionFenced ==
    /\ IsEvent("ExecutionTransactionFenced")
    /\ DOMAIN logline.params = {}
    /\ B!ExecutionTransactionFenced
    /\ ValidatePostState
    /\ Advance

TraceExecutionTransactionNoncommit ==
    /\ IsEvent("ExecutionTransactionNoncommit")
    /\ DOMAIN logline.params = {}
    /\ B!ExecutionTransactionNoncommit
    /\ ValidatePostState
    /\ Advance

TraceExecutionTransactionTimeout ==
    /\ IsEvent("ExecutionTransactionTimeout")
    /\ DOMAIN logline.params = {}
    /\ B!ExecutionTransactionTimeout
    /\ ValidatePostState
    /\ Advance

TraceAppendHistoryTimeout ==
    /\ IsEvent("AppendHistoryTimeout")
    /\ DOMAIN logline.params = {}
    /\ B!AppendHistoryTimeout
    /\ ValidatePostState
    /\ Advance

TraceHandleWriteResult ==
    /\ IsEvent("HandleWriteResult")
    /\ DOMAIN logline.params = {}
    /\ B!HandleWriteResult
    /\ ValidatePostState
    /\ Advance

TraceBufferApplyFirst ==
    /\ IsEvent("BufferApplyFirst")
    /\ DOMAIN logline.params = {}
    /\ B!BufferApplyFirst
    /\ ValidatePostState
    /\ Advance

TraceBufferApplySecond ==
    /\ IsEvent("BufferApplySecond")
    /\ DOMAIN logline.params = {}
    /\ B!BufferApplySecond
    /\ ValidatePostState
    /\ Advance

TraceBufferApplyDone ==
    /\ IsEvent("BufferApplyDone")
    /\ DOMAIN logline.params = {}
    /\ B!BufferApplyDone
    /\ ValidatePostState
    /\ Advance

TraceRegistryAbortAfterClose ==
    /\ IsEvent("RegistryAbortAfterClose")
    /\ DOMAIN logline.params = {"o"}
    /\ B!RegistryAbortAfterClose(logline.params.o)
    /\ ValidatePostState
    /\ Advance

TraceAddSuccessorWorkflowTask ==
    /\ IsEvent("AddSuccessorWorkflowTask")
    /\ DOMAIN logline.params = {}
    /\ B!AddSuccessorWorkflowTask
    /\ ValidatePostState
    /\ Advance

TraceStartSuccessorWorkflowTask ==
    /\ IsEvent("StartSuccessorWorkflowTask")
    /\ DOMAIN logline.params = {}
    /\ B!StartSuccessorWorkflowTask
    /\ ValidatePostState
    /\ Advance

TraceCreateRespondWorkflowTaskCompletedResponse ==
    /\ IsEvent("CreateRespondWorkflowTaskCompletedResponse")
    /\ DOMAIN logline.params = {}
    /\ B!CreateRespondWorkflowTaskCompletedResponse
    /\ ValidatePostState
    /\ Advance

TraceRespondWorkflowTaskCompletedReturn ==
    /\ IsEvent("RespondWorkflowTaskCompletedReturn")
    /\ DOMAIN logline.params = {}
    /\ B!RespondWorkflowTaskCompletedReturn
    /\ ValidatePostState
    /\ Advance

TraceRespondWorkflowTaskCompletedLateError ==
    /\ IsEvent("RespondWorkflowTaskCompletedLateError")
    /\ DOMAIN logline.params = {}
    /\ B!RespondWorkflowTaskCompletedLateError
    /\ ValidatePostState
    /\ Advance

TraceContextClearBegin ==
    /\ IsEvent("ContextClearBegin")
    /\ DOMAIN logline.params = {}
    /\ B!ContextClearBegin
    /\ ValidatePostState
    /\ Advance

TraceRegistryClearAbort ==
    /\ IsEvent("RegistryClearAbort")
    /\ DOMAIN logline.params = {"o"}
    /\ B!RegistryClearAbort(logline.params.o)
    /\ ValidatePostState
    /\ Advance

TraceRegistryClearAbortSecond ==
    /\ IsEvent("RegistryClearAbortSecond")
    /\ DOMAIN logline.params = {}
    /\ B!RegistryClearAbortSecond
    /\ ValidatePostState
    /\ Advance

TraceContextClearDone ==
    /\ IsEvent("ContextClearDone")
    /\ DOMAIN logline.params = {}
    /\ B!ContextClearDone
    /\ ValidatePostState
    /\ Advance

TraceBufferCancel ==
    /\ IsEvent("BufferCancel")
    /\ DOMAIN logline.params = {}
    /\ B!BufferCancel
    /\ ValidatePostState
    /\ Advance

TraceBufferCancelDone ==
    /\ IsEvent("BufferCancelDone")
    /\ DOMAIN logline.params = {}
    /\ B!BufferCancelDone
    /\ ValidatePostState
    /\ Advance

TraceEvictWorkflowContext ==
    /\ IsEvent("EvictWorkflowContext")
    /\ DOMAIN logline.params = {}
    /\ B!EvictWorkflowContext
    /\ ValidatePostState
    /\ Advance

TraceLoseShardOwnership ==
    /\ IsEvent("LoseShardOwnership")
    /\ DOMAIN logline.params = {}
    /\ B!LoseShardOwnership
    /\ ValidatePostState
    /\ Advance

TraceAcquireShard ==
    /\ IsEvent("AcquireShard")
    /\ DOMAIN logline.params = {"h"}
    /\ B!AcquireShard(logline.params.h)
    /\ ValidatePostState
    /\ Advance

TraceLoadMutableState ==
    /\ IsEvent("LoadMutableState")
    /\ DOMAIN logline.params = {}
    /\ B!LoadMutableState
    /\ ValidatePostState
    /\ Advance

TraceClearStickyTaskQueue ==
    /\ IsEvent("ClearStickyTaskQueue")
    /\ DOMAIN logline.params = {}
    /\ B!ClearStickyTaskQueue
    /\ ValidatePostState
    /\ Advance

TraceEvictHostEvent ==
    /\ IsEvent("EvictHostEvent")
    /\ DOMAIN logline.params = {"h","i"}
    /\ B!EvictHostEvent(logline.params.h,logline.params.i)
    /\ ValidatePostState
    /\ Advance

TraceRestartHistoryHost ==
    /\ IsEvent("RestartHistoryHost")
    /\ DOMAIN logline.params = {"h"}
    /\ B!RestartHistoryHost(logline.params.h)
    /\ ValidatePostState
    /\ Advance

TraceScheduleToStartTimerEligible ==
    /\ IsEvent("ScheduleToStartTimerEligible")
    /\ DOMAIN logline.params = {"i"}
    /\ B!ScheduleToStartTimerEligible(logline.params.i)
    /\ ValidatePostState
    /\ Advance

TraceStartToCloseTimerEligible ==
    /\ IsEvent("StartToCloseTimerEligible")
    /\ DOMAIN logline.params = {"i"}
    /\ B!StartToCloseTimerEligible(logline.params.i)
    /\ ValidatePostState
    /\ Advance

TraceMemoryScheduledQueueSubmit ==
    /\ IsEvent("MemoryScheduledQueueSubmit")
    /\ DOMAIN logline.params = {"i"}
    /\ B!MemoryScheduledQueueSubmit(logline.params.i)
    /\ ValidatePostState
    /\ Advance

TraceExecuteWorkflowTaskTimeoutTaskStale ==
    /\ IsEvent("ExecuteWorkflowTaskTimeoutTaskStale")
    /\ DOMAIN logline.params = {"i"}
    /\ B!ExecuteWorkflowTaskTimeoutTaskStale(logline.params.i)
    /\ ValidatePostState
    /\ Advance

TraceExecuteWorkflowTaskTimeoutTask ==
    /\ IsEvent("ExecuteWorkflowTaskTimeoutTask")
    /\ DOMAIN logline.params = {"i"}
    /\ B!ExecuteWorkflowTaskTimeoutTask(logline.params.i)
    /\ ValidatePostState
    /\ Advance

TraceForceTerminateWorkflow ==
    /\ IsEvent("ForceTerminateWorkflow")
    /\ DOMAIN logline.params = {}
    /\ B!ForceTerminateWorkflow
    /\ ValidatePostState
    /\ Advance

TraceForceTerminateAbort ==
    /\ IsEvent("ForceTerminateAbort")
    /\ DOMAIN logline.params = {"o"}
    /\ B!ForceTerminateAbort(logline.params.o)
    /\ ValidatePostState
    /\ Advance

TraceForceTerminateClear ==
    /\ IsEvent("ForceTerminateClear")
    /\ DOMAIN logline.params = {}
    /\ B!ForceTerminateClear
    /\ ValidatePostState
    /\ Advance

TraceForceTerminatePersist ==
    /\ IsEvent("ForceTerminatePersist")
    /\ DOMAIN logline.params = {}
    /\ B!ForceTerminatePersist
    /\ ValidatePostState
    /\ Advance

TraceRestoreHistoryLimit ==
    /\ IsEvent("RestoreHistoryLimit")
    /\ DOMAIN logline.params = {}
    /\ B!RestoreHistoryLimit
    /\ ValidatePostState
    /\ Advance

TraceTerminateWorkflowExecution ==
    /\ IsEvent("TerminateWorkflowExecution")
    /\ DOMAIN logline.params = {}
    /\ B!TerminateWorkflowExecution
    /\ ValidatePostState
    /\ Advance

TraceTimeoutWorkflowExecution ==
    /\ IsEvent("TimeoutWorkflowExecution")
    /\ DOMAIN logline.params = {}
    /\ B!TimeoutWorkflowExecution
    /\ ValidatePostState
    /\ Advance

TraceExternalCloseReturn ==
    /\ IsEvent("ExternalCloseReturn")
    /\ DOMAIN logline.params = {}
    /\ B!ExternalCloseReturn
    /\ ValidatePostState
    /\ Advance

TraceWaitLifecycleStageOutcome ==
    /\ IsEvent("WaitLifecycleStageOutcome")
    /\ DOMAIN logline.params = {"c"}
    /\ B!WaitLifecycleStageOutcome(logline.params.c)
    /\ ValidatePostState
    /\ Advance

TraceWaitLifecycleStageAccepted ==
    /\ IsEvent("WaitLifecycleStageAccepted")
    /\ DOMAIN logline.params = {"c"}
    /\ B!WaitLifecycleStageAccepted(logline.params.c)
    /\ ValidatePostState
    /\ Advance

TraceWaitLifecycleStageOutcomeRecheck ==
    /\ IsEvent("WaitLifecycleStageOutcomeRecheck")
    /\ DOMAIN logline.params = {"c"}
    /\ B!WaitLifecycleStageOutcomeRecheck(logline.params.c)
    /\ ValidatePostState
    /\ Advance

TraceWaitLifecycleStageSoftTimeout ==
    /\ IsEvent("WaitLifecycleStageSoftTimeout")
    /\ DOMAIN logline.params = {"c"}
    /\ B!WaitLifecycleStageSoftTimeout(logline.params.c)
    /\ ValidatePostState
    /\ Advance

TraceCreateUpdateResponse ==
    /\ IsEvent("CreateUpdateResponse")
    /\ DOMAIN logline.params = {"c"}
    /\ B!CreateUpdateResponse(logline.params.c)
    /\ ValidatePostState
    /\ Advance

TraceReceiveUpdateResponse ==
    /\ IsEvent("ReceiveUpdateResponse")
    /\ DOMAIN logline.params = {"c"}
    /\ B!ReceiveUpdateResponse(logline.params.c)
    /\ ValidatePostState
    /\ Advance

TraceLoseUpdateResponse ==
    /\ IsEvent("LoseUpdateResponse")
    /\ DOMAIN logline.params = {"c"}
    /\ B!LoseUpdateResponse(logline.params.c)
    /\ ValidatePostState
    /\ Advance

TraceRetryUpdateWorkflowExecution ==
    /\ IsEvent("RetryUpdateWorkflowExecution")
    /\ DOMAIN logline.params = {"c"}
    /\ B!RetryUpdateWorkflowExecution(logline.params.c)
    /\ ValidatePostState
    /\ Advance

TraceExecutionTransactionBegin ==
    /\ IsEvent("ExecutionTransactionBegin")
    /\ DOMAIN logline.params = {}
    /\ B!ExecutionTransactionBegin
    /\ ValidatePostState
    /\ Advance

TraceCrashHistoryProcess ==
    /\ IsEvent("CrashHistoryProcess")
    /\ DOMAIN logline.params = {}
    /\ B!CrashHistoryProcess
    /\ ValidatePostState
    /\ Advance

TraceDuplicateWorkerCompletion ==
    /\ IsEvent("DuplicateWorkerCompletion")
    /\ DOMAIN logline.params = {"i"}
    /\ B!DuplicateWorkerCompletion(logline.params.i)
    /\ ValidatePostState
    /\ Advance

TraceLoseWorkerCompletion ==
    /\ IsEvent("LoseWorkerCompletion")
    /\ DOMAIN logline.params = {"i"}
    /\ B!LoseWorkerCompletion(logline.params.i)
    /\ ValidatePostState
    /\ Advance

TraceNext ==
    \/ /\ l <= Len(TraceLog)
       /\ (TraceUpdateWorkflowExecution
            \/ TraceUpdaterApplyRequestNew
            \/ TraceAddWorkflowTaskScheduledEvent
            \/ TraceUpdaterApplyRequestExisting
            \/ TraceAttachCallbacks
            \/ TraceGetUpdateOutcome
            \/ TraceRegistryFindMissing
            \/ TraceScheduleNormalWorkflowTask
            \/ TraceAddWorkflowTaskToMatching
            \/ TraceAddWorkflowTaskToMatchingFailed
            \/ TraceStickyWorkerUnavailable
            \/ TracePushWorkflowTask
            \/ TraceRecordWorkflowTaskStarted
            \/ TraceCreateRecordWorkflowTaskStartedResponse
            \/ TraceRecordWorkflowTaskStartedReturn
            \/ TraceRecordWorkflowTaskStartedNotFound
            \/ TraceWorkerAcceptance
            \/ TraceWorkerResponse
            \/ TraceWorkerRejection
            \/ TraceWorkerSendCompletion
            \/ TraceWorkerIgnoreUpdates
            \/ TraceWorkerCloseWorkflow
            \/ TraceRespondWorkflowTaskCompleted
            \/ TraceRespondWorkflowTaskCompletedNotFound
            \/ TraceAddWorkflowTaskCompletedEvent
            \/ TraceTryResurrect
            \/ TraceOnAcceptanceMsg
            \/ TraceOnResponseMsg
            \/ TraceOnRejectionMsg
            \/ TraceHandleMessageInvalid
            \/ TraceHandleCommandsDone
            \/ TraceRejectUnprocessed
            \/ TraceAbortAccepted
            \/ TracePrepareWorkflowMutation
            \/ TraceConvertSpeculativeWorkflowTaskToNormal
            \/ TraceUpdateWorkflowExecutionWithNew
            \/ TraceAppendHistoryNodes
            \/ TraceExecutionTransactionCommit
            \/ TraceExecutionTransactionFenced
            \/ TraceExecutionTransactionNoncommit
            \/ TraceExecutionTransactionTimeout
            \/ TraceAppendHistoryTimeout
            \/ TraceHandleWriteResult
            \/ TraceBufferApplyFirst
            \/ TraceBufferApplySecond
            \/ TraceBufferApplyDone
            \/ TraceRegistryAbortAfterClose
            \/ TraceAddSuccessorWorkflowTask
            \/ TraceStartSuccessorWorkflowTask
            \/ TraceCreateRespondWorkflowTaskCompletedResponse
            \/ TraceRespondWorkflowTaskCompletedReturn
            \/ TraceRespondWorkflowTaskCompletedLateError
            \/ TraceContextClearBegin
            \/ TraceRegistryClearAbort
            \/ TraceRegistryClearAbortSecond
            \/ TraceContextClearDone
            \/ TraceBufferCancel
            \/ TraceBufferCancelDone
            \/ TraceEvictWorkflowContext
            \/ TraceLoseShardOwnership
            \/ TraceAcquireShard
            \/ TraceLoadMutableState
            \/ TraceClearStickyTaskQueue
            \/ TraceEvictHostEvent
            \/ TraceRestartHistoryHost
            \/ TraceScheduleToStartTimerEligible
            \/ TraceStartToCloseTimerEligible
            \/ TraceMemoryScheduledQueueSubmit
            \/ TraceExecuteWorkflowTaskTimeoutTaskStale
            \/ TraceExecuteWorkflowTaskTimeoutTask
            \/ TraceForceTerminateWorkflow
            \/ TraceForceTerminateAbort
            \/ TraceForceTerminateClear
            \/ TraceForceTerminatePersist
            \/ TraceRestoreHistoryLimit
            \/ TraceTerminateWorkflowExecution
            \/ TraceTimeoutWorkflowExecution
            \/ TraceExternalCloseReturn
            \/ TraceWaitLifecycleStageOutcome
            \/ TraceWaitLifecycleStageAccepted
            \/ TraceWaitLifecycleStageOutcomeRecheck
            \/ TraceWaitLifecycleStageSoftTimeout
            \/ TraceCreateUpdateResponse
            \/ TraceReceiveUpdateResponse
            \/ TraceLoseUpdateResponse
            \/ TraceRetryUpdateWorkflowExecution
            \/ TraceExecutionTransactionBegin
            \/ TraceCrashHistoryProcess
            \/ TraceDuplicateWorkerCompletion
            \/ TraceLoseWorkerCompletion)
    \/ /\ l > Len(TraceLog)
       /\ UNCHANGED tracevars

(* No silent transitions: instrumentation exposes every modeled boundary.
   WF excludes infinite stuttering before an enabled recorded event. An
   unmatched event still violates TraceMatched, even with deadlock off. *)
TraceSpec == TraceInit /\ [][TraceNext]_tracevars /\ WF_tracevars(TraceNext)
TraceMatched == <>(l > Len(TraceLog))
TraceCursorOK == l \in 1..(Len(TraceLog)+1)
=============================================================================
