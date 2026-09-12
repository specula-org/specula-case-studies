------------------------------ MODULE Trace -------------------------------
EXTENDS base, Json, IOUtils

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"
RawTrace == ndJsonDeserialize(JsonFile)
TraceLog == SelectSeq(RawTrace, LAMBDA e : IF "tag" \in DOMAIN e
                                           THEN e.tag = "trace" ELSE FALSE)
TraceConfig == TraceLog[1].config
TraceRuns == SeqSet(TraceConfig.runs)
TraceOps == SeqSet(TraceConfig.ops)
TraceResetIDs == SeqSet(TraceConfig.resetIDs)
TraceStartIDs == SeqSet(TraceConfig.startIDs)
TraceUpdateIDs == SeqSet(TraceConfig.updateIDs)
TracePayloads == SeqSet(TraceConfig.payloads)
TraceBackend == TraceConfig.backend
TraceIOConcurrency == TraceConfig.ioConcurrency
TraceHistoryLimit == TraceConfig.historyLimit
TraceStartMapPresent == TraceConfig.startMapPresent
TraceScannerAfterRequestDeadline == TraceConfig.scannerAfterRequestDeadline

\* JSON arrays represent both sequences and sets. Only declared set-valued
\* fields are converted; order is preserved for histories, frontiers and events.
DecodeRun(s) == [s EXCEPT !.requestIds = SeqSet(@)]
DecodeDB(s) == [s EXCEPT
    !.runs = [r \in Runs |-> DecodeRun(s.runs[r])],
    !.branches = SeqSet(@), !.nodes = SeqSet(@)]
DecodeOp(s) == [s EXCEPT !.exclude = SeqSet(@), !.updateIds = SeqSet(@)]
DecodeOps(s) == [p \in Ops |-> DecodeOp(s[p])]
DecodeRT(s) == [s EXCEPT !.io = SeqSet(@)]
DecodeAudit(s) == [s EXCEPT !.acks = SeqSet(@), !.receipts = SeqSet(@),
    !.commits = SeqSet(@), !.deleted = SeqSet(@), !.wanted = SeqSet(@),
    !.terminal = SeqSet(@)]
DecodeDeletion(s) == [r \in Runs |-> [s[r] EXCEPT !.plan = SeqSet(@)]]

VARIABLE l
tracevars == <<vars, l>>
logline == TraceLog[l]
IsEvent(name) == l <= Len(TraceLog) /\ logline.event = name
\* Strong post-state checks: mandatory fields, no conditional presence checks.
\* instrumentation-spec.md section 1 defines every captured field in these records.
ValidatePostState(s) ==
    /\ db' = DecodeDB(s.db)
    /\ op' = DecodeOps(s.op)
    /\ pending' = s.pending
    /\ rt' = DecodeRT(s.rt)
    /\ audit' = DecodeAudit(s.audit)
    /\ deletion' = DecodeDeletion(s.deletion)
    /\ used' = SeqSet(s.used)
ValidateInitialState(s) ==
    /\ db = DecodeDB(s.db)
    /\ op = DecodeOps(s.op)
    /\ pending = s.pending
    /\ rt = DecodeRT(s.rt)
    /\ audit = DecodeAudit(s.audit)
    /\ deletion = DecodeDeletion(s.deletion)
    /\ used = SeqSet(s.used)
TraceInit ==
    /\ Len(TraceLog) >= 1
    /\ TraceLog[1].event = "Bootstrap"
    /\ TraceConfig.revision = "0c010ce5fe8c0180aa7573c72fe8fc87c6df7025"
    /\ Init
    /\ ValidateInitialState(TraceLog[1].state)
    /\ l = 2

\* service/history/api/startworkflow/api.go:195-253; Scenario 3
TraceStartWorkflowExecution ==
    /\ IsEvent("StartWorkflowExecution")
    /\ StartWorkflowExecution(logline.args.p, logline.args.r, logline.args.id)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/api/resetworkflow/api.go:43-76; Scenarios 1-5
TraceResetWorkflowExecution ==
    /\ IsEvent("ResetWorkflowExecution")
    /\ ResetWorkflowExecution(logline.args.p, logline.args.q, logline.args.b, logline.args.cut, SeqSet(logline.args.ex))
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/api/resetworkflow/api.go:58-76; workflow/cache/cache.go:385-388
TraceGetWorkflowLease_Base ==
    /\ IsEvent("GetWorkflowLease_Base")
    /\ GetWorkflowLease_Base(logline.args.p)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/api/resetworkflow/api.go:86-122; workflow/cache/cache.go:465-490
TraceGetCurrentWorkflowRunID ==
    /\ IsEvent("GetCurrentWorkflowRunID")
    /\ GetCurrentWorkflowRunID(logline.args.p)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/api/resetworkflow/api.go:101-126
TraceGetWorkflowLease_Current ==
    /\ IsEvent("GetWorkflowLease_Current")
    /\ GetWorkflowLease_Current(logline.args.p)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/api/resetworkflow/api.go:124-136; Scenario 1
TraceInvoke_Deduplicate ==
    /\ IsEvent("Invoke_Deduplicate")
    /\ Invoke_Deduplicate(logline.args.p)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/api/resetworkflow/api.go:136-148; Scenario 1
TraceInvoke_NewRunID ==
    /\ IsEvent("Invoke_NewRunID")
    /\ Invoke_NewRunID(logline.args.p, logline.args.r)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/ndc/workflow_resetter.go:132-228,230-247
TraceResetWorkflow_UpdateResetRunID ==
    /\ IsEvent("ResetWorkflow_UpdateResetRunID")
    /\ ResetWorkflow_UpdateResetRunID(logline.args.p)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/ndc/workflow_resetter.go:518-545; common/persistence/history_manager.go:54-120
TraceForkHistoryBranch ==
    /\ IsEvent("ForkHistoryBranch")
    /\ ForkHistoryBranch(logline.args.p)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/ndc/workflow_resetter.go:545-565; state_rebuilder.go:402-410; workflow/mutable_state_impl.go:3106-3123
TraceRebuild ==
    /\ IsEvent("Rebuild")
    /\ Rebuild(logline.args.p)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/ndc/workflow_resetter.go:139-142,749-768,865-882; Scenario 4
TraceReadHistoryBranch ==
    /\ IsEvent("ReadHistoryBranch")
    /\ ReadHistoryBranch(logline.args.p)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/ndc/workflow_resetter.go:950-1021; workflow/mutable_state_impl.go:5743-5748
TraceReapplyEvents ==
    /\ IsEvent("ReapplyEvents")
    /\ ReapplyEvents(logline.args.p)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/ndc/workflow_resetter.go:904-910
TraceReapplyEventsFromBranch_NextRun ==
    /\ IsEvent("ReapplyEventsFromBranch_NextRun")
    /\ ReapplyEventsFromBranch_NextRun(logline.args.p)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/ndc/workflow_resetter.go:771-828; Scenario 4
TraceGetNextEventIDBranchToken ==
    /\ IsEvent("GetNextEventIDBranchToken")
    /\ GetNextEventIDBranchToken(logline.args.p)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/ndc/workflow_resetter.go:258-280,376-425
TraceScheduleWorkflowTask ==
    /\ IsEvent("ScheduleWorkflowTask")
    /\ ScheduleWorkflowTask(logline.args.p)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/ndc/workflow_resetter.go:399-412; service/history/shard/context_impl.go:552-594,610-656
TraceUpdateWorkflowExecution_BypassCurrent ==
    /\ IsEvent("UpdateWorkflowExecution_BypassCurrent")
    /\ UpdateWorkflowExecution_BypassCurrent(logline.args.p)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/ndc/workflow_resetter.go:413-424; service/history/shard/context_impl.go:552-594,610-656
TraceCreateWorkflowExecution_BrandNew ==
    /\ IsEvent("CreateWorkflowExecution_BrandNew")
    /\ CreateWorkflowExecution_BrandNew(logline.args.p)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/ndc/workflow_resetter.go:430-459; service/history/shard/context_impl.go:552-594,610-656
TraceUpdateWorkflowExecution_WithNew ==
    /\ IsEvent("UpdateWorkflowExecution_WithNew")
    /\ UpdateWorkflowExecution_WithNew(logline.args.p)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/ndc/workflow_resetter.go:463-503; service/history/shard/context_impl.go:552-594,610-656
TraceConflictResolveWorkflowExecution ==
    /\ IsEvent("ConflictResolveWorkflowExecution")
    /\ ConflictResolveWorkflowExecution(logline.args.p)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/ndc/workflow_resetter.go:413-424; service/history/shard/context_impl.go:552-594,610-656
TraceCreateWorkflowExecution_Start ==
    /\ IsEvent("CreateWorkflowExecution_Start")
    /\ CreateWorkflowExecution_Start(logline.args.p)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* common/persistence/sql/execution.go:338-343,450-455; cassandra/execution_store.go:114-118,132-136; Scenario 2
TraceAppendHistoryNodes_Current ==
    /\ IsEvent("AppendHistoryNodes_Current")
    /\ AppendHistoryNodes_Current(logline.args.r)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* common/persistence/sql/execution.go:64-78,344-357,456-473; cassandra/execution_store.go:101-107,119-125,137-148; Scenario 2
TraceAppendHistoryNodes ==
    /\ IsEvent("AppendHistoryNodes")
    /\ AppendHistoryNodes(logline.args.r)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/shard/context_impl.go:1518-1520; Scenario 2 history append uncertain, metadata unattempted
TracePersistenceAppendTimeout ==
    /\ IsEvent("PersistenceAppendTimeout")
    /\ PersistenceAppendTimeout(logline.args.r)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* common/persistence/cassandra/mutable_state_store.go:619-630,885-918
TraceAssertNotCurrentExecution ==
    /\ IsEvent("AssertNotCurrentExecution")
    /\ AssertNotCurrentExecution(logline.args.r)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* common/persistence/sql/execution.go:39-78,375-443,505-575; cassandra/mutable_state_store.go:453-492,689-740
TraceCommitWorkflowExecution ==
    /\ IsEvent("CommitWorkflowExecution")
    /\ CommitWorkflowExecution(logline.args.r)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* common/persistence/sql/execution.go:106-124,426-440; sql/execution_util.go:640-661; cassandra/mutable_state_store.go:474-489
TraceRejectWorkflowExecution ==
    /\ IsEvent("RejectWorkflowExecution")
    /\ RejectWorkflowExecution(logline.args.r)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/shard/context_impl.go:1522-1532; Scenario 2 fault, ResourceExhausted before metadata
TracePersistenceDefiniteRejection ==
    /\ IsEvent("PersistenceDefiniteRejection")
    /\ PersistenceDefiniteRejection(logline.args.r)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/shard/context_impl.go:1540-1548; Scenario 2 delayed/committed unknown result
TracePersistenceUncertainReturn ==
    /\ IsEvent("PersistenceUncertainReturn")
    /\ PersistenceUncertainReturn(logline.args.r)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/workflow/transaction_impl.go:82-93,201-220; shard/context_impl.go:1506-1548
TracePersistenceReturn ==
    /\ IsEvent("PersistenceReturn")
    /\ PersistenceReturn(logline.args.r)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/api/resetworkflow/api.go:131-134,213-215; service/history/api/startworkflow/api.go:230-236
TraceInvoke_ReturnSuccess ==
    /\ IsEvent("Invoke_ReturnSuccess")
    /\ Invoke_ReturnSuccess(logline.args.p)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/api/resetworkflow/api.go:71,121; workflow/cache/cache.go:390-409
TraceReleaseWorkflowLease_Success ==
    /\ IsEvent("ReleaseWorkflowLease_Success")
    /\ ReleaseWorkflowLease_Success(logline.args.p)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/api/resetworkflow/api.go:213-215; Scenario 1 RPC client receipt boundary
TraceReceiveResetResponse ==
    /\ IsEvent("ReceiveResetResponse")
    /\ ReceiveResetResponse(logline.args.p)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/api/resetworkflow/api.go:213-215; Scenario 1 RPC transport fault after success
TraceLoseResetResponse ==
    /\ IsEvent("LoseResetResponse")
    /\ LoseResetResponse(logline.args.p)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/api/resetworkflow/api.go:43,124-136; Scenario 1 explicit identical client replay
TraceReplayResetRequest ==
    /\ IsEvent("ReplayResetRequest")
    /\ ReplayResetRequest(logline.args.p)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/api/resetworkflow/api.go:71,121; workflow/cache/cache.go:385-389; handler.go:2291-2298
TraceReleaseWorkflowLease_Error ==
    /\ IsEvent("ReleaseWorkflowLease_Error")
    /\ ReleaseWorkflowLease_Error(logline.args.p)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* common/rpc/interceptor/retry.go:36-44; service/history/handler.go:2291-2298; Scenarios 1-3
TraceRetryResetWorkflowExecution ==
    /\ IsEvent("RetryResetWorkflowExecution")
    /\ RetryResetWorkflowExecution(logline.args.p)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/shard/context_impl.go:1534-1548,2030-2047; Scenario 2 process/cache loss
TraceCrashHistoryService ==
    /\ IsEvent("CrashHistoryService")
    /\ CrashHistoryService
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/shard/context_impl.go:1164-1207,2074-2097; Scenario 2 RangeID fence
TraceAcquireShard ==
    /\ IsEvent("AcquireShard")
    /\ AcquireShard
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* client/history/client_gen.go:1049-1055; client/history/client.go:33-34,290-291; service/history/shard/context_impl.go:2414-2427; Scenario 5
TraceExpireResetRequest ==
    /\ IsEvent("ExpireResetRequest")
    /\ ExpireResetRequest(logline.args.p)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/ndc/workflow_resetter.go:796-819,875-882; Scenario 4 read error must not truncate
TraceReadTransientFailure ==
    /\ IsEvent("ReadTransientFailure")
    /\ ReadTransientFailure(logline.args.p)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/workflow/mutable_state_impl.go:3648-3664; workflow/workflow_task_state_machine.go:453-548; Scenarios 2/4 valid reset boundary
TraceAddWorkflowTaskStartedEvent ==
    /\ IsEvent("AddWorkflowTaskStartedEvent")
    /\ AddWorkflowTaskStartedEvent(logline.args.r)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/workflow/mutable_state_impl.go:5770-5850; Scenario 4 per-run Update namespace
TraceAddWorkflowExecutionUpdateAcceptedEvent ==
    /\ IsEvent("AddWorkflowExecutionUpdateAcceptedEvent")
    /\ AddWorkflowExecutionUpdateAcceptedEvent(logline.args.r, logline.args.id, logline.args.payload)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/workflow/mutable_state_impl.go:5852-5906; Scenario 4 completed-Update control
TraceAddWorkflowExecutionUpdateCompletedEvent ==
    /\ IsEvent("AddWorkflowExecutionUpdateCompletedEvent")
    /\ AddWorkflowExecutionUpdateCompletedEvent(logline.args.r, logline.args.id)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/api/signalworkflow/api.go:58-92; workflow/mutable_state_impl.go:6274-6310; Scenario 4
TraceAddWorkflowExecutionSignaled ==
    /\ IsEvent("AddWorkflowExecutionSignaled")
    /\ AddWorkflowExecutionSignaled(logline.args.r, logline.args.id, logline.args.payload)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/workflow/mutable_state_impl.go:6312-6386; common/persistence/sql/execution.go:392-441; Scenario 4 supported CAN
TraceContinueAsNew ==
    /\ IsEvent("ContinueAsNew")
    /\ ContinueAsNew(logline.args.r, logline.args.s, logline.args.id)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/workflow/mutable_state_impl.go:4950-5009; Scenario 2 healthy worker availability
TraceCompleteWorkflowExecution ==
    /\ IsEvent("CompleteWorkflowExecution")
    /\ CompleteWorkflowExecution(logline.args.r)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/api/deleteworkflow/api.go:25-97; Scenario 5 public acknowledgement before cleanup
TraceDeleteWorkflowExecution ==
    /\ IsEvent("DeleteWorkflowExecution")
    /\ DeleteWorkflowExecution(logline.args.r)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/transfer_queue_task_executor_base.go:235-288; shard/context_impl.go:922-937
TraceDeleteExecutionTask ==
    /\ IsEvent("DeleteExecutionTask")
    /\ DeleteExecutionTask(logline.args.r)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/shard/context_impl.go:972-985; Scenario 5 I/O held through stages 1-3
TraceDeleteWorkflowExecution_AcquireIO ==
    /\ IsEvent("DeleteWorkflowExecution_AcquireIO")
    /\ DeleteWorkflowExecution_AcquireIO(logline.args.r)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/shard/context_impl.go:1040-1061; sql/execution.go:670-687; cassandra/mutable_state_store.go:939-955
TraceDeleteCurrentWorkflowExecution ==
    /\ IsEvent("DeleteCurrentWorkflowExecution")
    /\ DeleteCurrentWorkflowExecution(logline.args.r)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/history/shard/context_impl.go:1063-1083
TraceDeleteWorkflowMutableState ==
    /\ IsEvent("DeleteWorkflowMutableState")
    /\ DeleteWorkflowMutableState(logline.args.r)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* common/persistence/history_manager.go:150-208; Scenario 5 reference snapshot separate from deletion
TraceGetHistoryTreeContainingBranch ==
    /\ IsEvent("GetHistoryTreeContainingBranch")
    /\ GetHistoryTreeContainingBranch(logline.args.r)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* common/persistence/sql/history_store.go:347-376
TraceDeleteHistoryBranch_SQL ==
    /\ IsEvent("DeleteHistoryBranch_SQL")
    /\ DeleteHistoryBranch_SQL(logline.args.r)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* common/persistence/cassandra/history_store.go:273-281; logged non-CAS batch row visibility
TraceDeleteHistoryBranch_CassandraRow ==
    /\ IsEvent("DeleteHistoryBranch_CassandraRow")
    /\ DeleteHistoryBranch_CassandraRow(logline.args.r)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* common/persistence/cassandra/history_store.go:276-298; eventually applied logged batch ranges
TraceDeleteHistoryBranch_CassandraRanges ==
    /\ IsEvent("DeleteHistoryBranch_CassandraRanges")
    /\ DeleteHistoryBranch_CassandraRanges(logline.args.r)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/worker/scanner/history/scavenger.go:202-211; common/dynamicconfig/constants.go:3549-3553; client/history/client.go:33-34,290-291
TraceHistoryScannerAge ==
    /\ IsEvent("HistoryScannerAge")
    /\ HistoryScannerAge(logline.args.r)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

\* service/worker/scanner/history/scavenger.go:252-286; Scenario 5 NotFound only, not temporary error
TraceHistoryScavengerVerify ==
    /\ IsEvent("HistoryScavengerVerify")
    /\ HistoryScavengerVerify(logline.args.r)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

TracePersistFirstWorkflowTaskSchedule ==
    /\ IsEvent("PersistFirstWorkflowTaskSchedule")
    /\ PersistFirstWorkflowTaskSchedule(logline.args.r)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

TraceBeginAcquireShard ==
    /\ IsEvent("BeginAcquireShard")
    /\ BeginAcquireShard
    /\ ValidatePostState(logline.state)
    /\ l' = l+1
TraceRenewShardRange ==
    /\ IsEvent("RenewShardRange")
    /\ RenewShardRange
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

TraceIssueCurrentHistory ==
    /\ IsEvent("IssueCurrentHistory")
    /\ IssueCurrentHistory(logline.args.r)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

TraceIssueCandidateHistory ==
    /\ IsEvent("IssueCandidateHistory")
    /\ IssueCandidateHistory(logline.args.r)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

TraceIssueCurrentRead ==
    /\ IsEvent("IssueCurrentRead")
    /\ IssueCurrentRead(logline.args.r)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

TraceIssueMetadata ==
    /\ IsEvent("IssueMetadata")
    /\ IssueMetadata(logline.args.r)
    /\ ValidatePostState(logline.state)
    /\ l' = l+1

Advance ==
    \/ TraceIssueCurrentHistory
    \/ TraceIssueCandidateHistory
    \/ TraceIssueCurrentRead
    \/ TraceIssueMetadata

    \/ TraceBeginAcquireShard
    \/ TraceRenewShardRange
    \/ TracePersistFirstWorkflowTaskSchedule
    \/ TraceStartWorkflowExecution
    \/ TraceResetWorkflowExecution
    \/ TraceGetWorkflowLease_Base
    \/ TraceGetCurrentWorkflowRunID
    \/ TraceGetWorkflowLease_Current
    \/ TraceInvoke_Deduplicate
    \/ TraceInvoke_NewRunID
    \/ TraceResetWorkflow_UpdateResetRunID
    \/ TraceForkHistoryBranch
    \/ TraceRebuild
    \/ TraceReadHistoryBranch
    \/ TraceReapplyEvents
    \/ TraceReapplyEventsFromBranch_NextRun
    \/ TraceGetNextEventIDBranchToken
    \/ TraceScheduleWorkflowTask
    \/ TraceUpdateWorkflowExecution_BypassCurrent
    \/ TraceCreateWorkflowExecution_BrandNew
    \/ TraceUpdateWorkflowExecution_WithNew
    \/ TraceConflictResolveWorkflowExecution
    \/ TraceCreateWorkflowExecution_Start
    \/ TraceAppendHistoryNodes_Current
    \/ TraceAppendHistoryNodes
    \/ TracePersistenceAppendTimeout
    \/ TraceAssertNotCurrentExecution
    \/ TraceCommitWorkflowExecution
    \/ TraceRejectWorkflowExecution
    \/ TracePersistenceDefiniteRejection
    \/ TracePersistenceUncertainReturn
    \/ TracePersistenceReturn
    \/ TraceInvoke_ReturnSuccess
    \/ TraceReleaseWorkflowLease_Success
    \/ TraceReceiveResetResponse
    \/ TraceLoseResetResponse
    \/ TraceReplayResetRequest
    \/ TraceReleaseWorkflowLease_Error
    \/ TraceRetryResetWorkflowExecution
    \/ TraceCrashHistoryService
    \/ TraceAcquireShard
    \/ TraceExpireResetRequest
    \/ TraceReadTransientFailure
    \/ TraceAddWorkflowTaskStartedEvent
    \/ TraceAddWorkflowExecutionUpdateAcceptedEvent
    \/ TraceAddWorkflowExecutionUpdateCompletedEvent
    \/ TraceAddWorkflowExecutionSignaled
    \/ TraceContinueAsNew
    \/ TraceCompleteWorkflowExecution
    \/ TraceDeleteWorkflowExecution
    \/ TraceDeleteExecutionTask
    \/ TraceDeleteWorkflowExecution_AcquireIO
    \/ TraceDeleteCurrentWorkflowExecution
    \/ TraceDeleteWorkflowMutableState
    \/ TraceGetHistoryTreeContainingBranch
    \/ TraceDeleteHistoryBranch_SQL
    \/ TraceDeleteHistoryBranch_CassandraRow
    \/ TraceDeleteHistoryBranch_CassandraRanges
    \/ TraceHistoryScannerAge
    \/ TraceHistoryScavengerVerify

\* No silent actions: every represented semantic boundary has its own event.
TraceNext ==
    \/ /\ l <= Len(TraceLog)
       /\ Advance
    \/ /\ l > Len(TraceLog)
       /\ UNCHANGED tracevars
TraceSpec == TraceInit /\ [][TraceNext]_tracevars /\ WF_tracevars(Advance)
TraceMatched == <>(l > Len(TraceLog))
=============================================================================
