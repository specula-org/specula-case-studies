------------------------------- MODULE MC ---------------------------------
EXTENDS base
Original == INSTANCE base
CONSTANTS Scenario, MaxPending,
AgeLimit, AppendLimit, CanLimit, CrashLimit, DeleteLimit, ReadLimit, RejectLimit, ReplayLimit, ResetLimit, ResponseLimit, SignalLimit, StartLimit, TimeoutLimit, UncertainLimit, UpdateLimit
VARIABLE faultCounts
mcvars == <<vars, faultCounts>>
FaultLimits == [age |-> AgeLimit, append |-> AppendLimit, can |-> CanLimit, crash |-> CrashLimit, delete |-> DeleteLimit, read |-> ReadLimit, reject |-> RejectLimit, replay |-> ReplayLimit, reset |-> ResetLimit, response |-> ResponseLimit, signal |-> SignalLimit, start |-> StartLimit, timeout |-> TimeoutLimit, uncertain |-> UncertainLimit, update |-> UpdateLimit]
MCInit == Init /\ faultCounts = [k \in DOMAIN FaultLimits |-> 0]

\* Only external inputs and injected faults consume counters. Backend replies,
\* reapplication steps, cleanup work, recovery, UUID allocation and server retry
\* all remain unbounded reactive actions. Scenario guards restrict input schedules.
InputStart(p) ==
    CASE Scenario = "convergence" -> TRUE
      [] Scenario = "race" -> faultCounts.start = 0 \/
             (\E t \in Ops : op[t].kind = "reset" /\ op[t].seen = None /\
                  op[t].pc \in {"prepare","fork","rebuild","submit-base","write-wait","submit-create"})
      [] OTHER -> faultCounts.start = 0
InputReset(b) ==
    CASE Scenario = "missing" -> db.current = None /\ faultCounts.delete > 0
      [] Scenario = "race" -> faultCounts.can >= 2 /\ faultCounts.delete > 0
      [] Scenario = "reapply" -> faultCounts.can > 0
      [] OTHER -> TRUE
InputDelete(r) ==
    IF Scenario \in {"missing","race"} THEN db.current = r /\ faultCounts.can > 0
    ELSE TRUE

MCStartWorkflowExecution(p, r, id) ==
    /\ InputStart(p)
    /\ faultCounts.start < StartLimit
    /\ Original!StartWorkflowExecution(p, r, id)
    /\ faultCounts' = [faultCounts EXCEPT !.start = @+1]

MCResetWorkflowExecution(p, q, b, cut, ex) ==
    /\ q \notin audit.wanted /\ InputReset(b)
    /\ faultCounts.reset < ResetLimit
    /\ Original!ResetWorkflowExecution(p, q, b, cut, ex)
    /\ faultCounts' = [faultCounts EXCEPT !.reset = @+1]

MCGetWorkflowLease_Base(p) ==
    /\ Original!GetWorkflowLease_Base(p)
    /\ UNCHANGED faultCounts

MCGetCurrentWorkflowRunID(p) ==
    /\ Original!GetCurrentWorkflowRunID(p)
    /\ UNCHANGED faultCounts

MCGetWorkflowLease_Current(p) ==
    /\ Original!GetWorkflowLease_Current(p)
    /\ UNCHANGED faultCounts

MCInvoke_Deduplicate(p) ==
    /\ Original!Invoke_Deduplicate(p)
    /\ UNCHANGED faultCounts

MCInvoke_NewRunID(p, r) ==
    /\ Original!Invoke_NewRunID(p, r)
    /\ UNCHANGED faultCounts

MCResetWorkflow_UpdateResetRunID(p) ==
    /\ Original!ResetWorkflow_UpdateResetRunID(p)
    /\ UNCHANGED faultCounts

MCForkHistoryBranch(p) ==
    /\ Original!ForkHistoryBranch(p)
    /\ UNCHANGED faultCounts

MCRebuild(p) ==
    /\ Original!Rebuild(p)
    /\ UNCHANGED faultCounts

MCReadHistoryBranch(p) ==
    /\ Original!ReadHistoryBranch(p)
    /\ UNCHANGED faultCounts

MCReapplyEvents(p) ==
    /\ Original!ReapplyEvents(p)
    /\ UNCHANGED faultCounts

MCReapplyEventsFromBranch_NextRun(p) ==
    /\ Original!ReapplyEventsFromBranch_NextRun(p)
    /\ UNCHANGED faultCounts

MCGetNextEventIDBranchToken(p) ==
    /\ Original!GetNextEventIDBranchToken(p)
    /\ UNCHANGED faultCounts

MCScheduleWorkflowTask(p) ==
    /\ Original!ScheduleWorkflowTask(p)
    /\ UNCHANGED faultCounts

MCUpdateWorkflowExecution_BypassCurrent(p) ==
    /\ Original!UpdateWorkflowExecution_BypassCurrent(p)
    /\ UNCHANGED faultCounts

MCCreateWorkflowExecution_BrandNew(p) ==
    /\ Original!CreateWorkflowExecution_BrandNew(p)
    /\ UNCHANGED faultCounts

MCUpdateWorkflowExecution_WithNew(p) ==
    /\ Original!UpdateWorkflowExecution_WithNew(p)
    /\ UNCHANGED faultCounts

MCConflictResolveWorkflowExecution(p) ==
    /\ Original!ConflictResolveWorkflowExecution(p)
    /\ UNCHANGED faultCounts

MCCreateWorkflowExecution_Start(p) ==
    /\ Original!CreateWorkflowExecution_Start(p)
    /\ UNCHANGED faultCounts

MCAppendHistoryNodes_Current(r) ==
    /\ Original!AppendHistoryNodes_Current(r)
    /\ UNCHANGED faultCounts

MCAppendHistoryNodes(r) ==
    /\ Original!AppendHistoryNodes(r)
    /\ UNCHANGED faultCounts

MCPersistenceAppendTimeout(r) ==
    /\ faultCounts.append < AppendLimit
    /\ Original!PersistenceAppendTimeout(r)
    /\ faultCounts' = [faultCounts EXCEPT !.append = @+1]

MCAssertNotCurrentExecution(r) ==
    /\ Original!AssertNotCurrentExecution(r)
    /\ UNCHANGED faultCounts

MCCommitWorkflowExecution(r) ==
    /\ Original!CommitWorkflowExecution(r)
    /\ UNCHANGED faultCounts

MCRejectWorkflowExecution(r) ==
    /\ Original!RejectWorkflowExecution(r)
    /\ UNCHANGED faultCounts

MCPersistenceDefiniteRejection(r) ==
    /\ faultCounts.reject < RejectLimit
    /\ Original!PersistenceDefiniteRejection(r)
    /\ faultCounts' = [faultCounts EXCEPT !.reject = @+1]

MCPersistenceUncertainReturn(r) ==
    /\ rt.state /= "acquired" \/ db.range /= pending[r].epoch \/ faultCounts.uncertain < UncertainLimit
    /\ Original!PersistenceUncertainReturn(r)
    /\ faultCounts' = IF rt.state = "acquired" /\ db.range = pending[r].epoch
                      THEN [faultCounts EXCEPT !.uncertain = @+1] ELSE faultCounts

MCPersistenceReturn(r) ==
    /\ Original!PersistenceReturn(r)
    /\ UNCHANGED faultCounts

MCInvoke_ReturnSuccess(p) ==
    /\ Original!Invoke_ReturnSuccess(p)
    /\ UNCHANGED faultCounts

MCReleaseWorkflowLease_Success(p) ==
    /\ Original!ReleaseWorkflowLease_Success(p)
    /\ UNCHANGED faultCounts

MCReceiveResetResponse(p) ==
    /\ Original!ReceiveResetResponse(p)
    /\ UNCHANGED faultCounts

MCLoseResetResponse(p) ==
    /\ faultCounts.response < ResponseLimit
    /\ Original!LoseResetResponse(p)
    /\ faultCounts' = [faultCounts EXCEPT !.response = @+1]

MCReplayResetRequest(p) ==
    /\ op[p].req \in ResetIDs
    /\ faultCounts.replay < ReplayLimit
    /\ Original!ReplayResetRequest(p)
    /\ faultCounts' = [faultCounts EXCEPT !.replay = @+1]

MCReleaseWorkflowLease_Error(p) ==
    /\ Original!ReleaseWorkflowLease_Error(p)
    /\ UNCHANGED faultCounts

MCRetryResetWorkflowExecution(p) ==
    /\ Original!RetryResetWorkflowExecution(p)
    /\ UNCHANGED faultCounts

MCCrashHistoryService ==
    /\ faultCounts.crash < CrashLimit
    /\ Original!CrashHistoryService
    /\ faultCounts' = [faultCounts EXCEPT !.crash = @+1]

MCAcquireShard ==
    /\ Original!AcquireShard
    /\ UNCHANGED faultCounts

MCExpireResetRequest(p) ==
    /\ faultCounts.timeout < TimeoutLimit
    /\ Original!ExpireResetRequest(p)
    /\ faultCounts' = [faultCounts EXCEPT !.timeout = @+1]

MCReadTransientFailure(p) ==
    /\ faultCounts.read < ReadLimit
    /\ Original!ReadTransientFailure(p)
    /\ faultCounts' = [faultCounts EXCEPT !.read = @+1]

MCAddWorkflowTaskStartedEvent(r) ==
    /\ Original!AddWorkflowTaskStartedEvent(r)
    /\ UNCHANGED faultCounts

MCAddWorkflowExecutionUpdateAcceptedEvent(r, id, payload) ==
    /\ faultCounts.update < UpdateLimit
    /\ Original!AddWorkflowExecutionUpdateAcceptedEvent(r, id, payload)
    /\ faultCounts' = [faultCounts EXCEPT !.update = @+1]

MCAddWorkflowExecutionUpdateCompletedEvent(r, id) ==
    /\ Original!AddWorkflowExecutionUpdateCompletedEvent(r, id)
    /\ UNCHANGED faultCounts

MCAddWorkflowExecutionSignaled(r, id, payload) ==
    /\ faultCounts.signal < SignalLimit
    /\ Original!AddWorkflowExecutionSignaled(r, id, payload)
    /\ faultCounts' = [faultCounts EXCEPT !.signal = @+1]

MCContinueAsNew(r, s, id) ==
    /\ faultCounts.can < CanLimit
    /\ Original!ContinueAsNew(r, s, id)
    /\ faultCounts' = [faultCounts EXCEPT !.can = @+1]

MCCompleteWorkflowExecution(r) ==
    /\ Original!CompleteWorkflowExecution(r)
    /\ UNCHANGED faultCounts

MCDeleteWorkflowExecution(r) ==
    /\ InputDelete(r)
    /\ faultCounts.delete < DeleteLimit
    /\ Original!DeleteWorkflowExecution(r)
    /\ faultCounts' = [faultCounts EXCEPT !.delete = @+1]

MCDeleteExecutionTask(r) ==
    /\ Original!DeleteExecutionTask(r)
    /\ UNCHANGED faultCounts

MCDeleteWorkflowExecution_AcquireIO(r) ==
    /\ Original!DeleteWorkflowExecution_AcquireIO(r)
    /\ UNCHANGED faultCounts

MCDeleteCurrentWorkflowExecution(r) ==
    /\ Original!DeleteCurrentWorkflowExecution(r)
    /\ UNCHANGED faultCounts

MCDeleteWorkflowMutableState(r) ==
    /\ Original!DeleteWorkflowMutableState(r)
    /\ UNCHANGED faultCounts

MCGetHistoryTreeContainingBranch(r) ==
    /\ Original!GetHistoryTreeContainingBranch(r)
    /\ UNCHANGED faultCounts

MCDeleteHistoryBranch_SQL(r) ==
    /\ Original!DeleteHistoryBranch_SQL(r)
    /\ UNCHANGED faultCounts

MCDeleteHistoryBranch_CassandraRow(r) ==
    /\ Original!DeleteHistoryBranch_CassandraRow(r)
    /\ UNCHANGED faultCounts

MCDeleteHistoryBranch_CassandraRanges(r) ==
    /\ Original!DeleteHistoryBranch_CassandraRanges(r)
    /\ UNCHANGED faultCounts

MCHistoryScannerAge(r) ==
    /\ faultCounts.age < AgeLimit
    /\ Original!HistoryScannerAge(r)
    /\ faultCounts' = [faultCounts EXCEPT !.age = @+1]

MCHistoryScavengerVerify(r) ==
    /\ Original!HistoryScavengerVerify(r)
    /\ UNCHANGED faultCounts

MCPersistFirstWorkflowTaskSchedule(r) ==
    /\ Original!PersistFirstWorkflowTaskSchedule(r)
    /\ UNCHANGED faultCounts

MCBeginAcquireShard ==
    /\ rt.state = "stopped" \/ faultCounts.uncertain < UncertainLimit
    /\ Original!BeginAcquireShard
    /\ faultCounts' = IF rt.state = "stopped" THEN faultCounts
                      ELSE [faultCounts EXCEPT !.uncertain = @+1]
MCRenewShardRange ==
    /\ Original!RenewShardRange
    /\ UNCHANGED faultCounts

MCIssueCurrentHistory(r) ==
    /\ Original!IssueCurrentHistory(r)
    /\ UNCHANGED faultCounts

MCIssueCandidateHistory(r) ==
    /\ Original!IssueCandidateHistory(r)
    /\ UNCHANGED faultCounts

MCIssueCurrentRead(r) ==
    /\ Original!IssueCurrentRead(r)
    /\ UNCHANGED faultCounts

MCIssueMetadata(r) ==
    /\ Original!IssueMetadata(r)
    /\ UNCHANGED faultCounts

MCNext ==
    \/ \E r \in Runs : MCIssueCurrentHistory(r)
    \/ \E r \in Runs : MCIssueCandidateHistory(r)
    \/ \E r \in Runs : MCIssueCurrentRead(r)
    \/ \E r \in Runs : MCIssueMetadata(r)

    \/ MCBeginAcquireShard
    \/ MCRenewShardRange
    \/ \E r \in Runs : MCPersistFirstWorkflowTaskSchedule(r)
    \/ \E p \in Ops, r \in Runs, id \in StartIDs : MCStartWorkflowExecution(p, r, id)
    \/ \E p \in Ops, q \in ResetIDs, b \in Runs, cut \in 2..HistoryLimit, ex \in SUBSET {"Signal","Update"} : MCResetWorkflowExecution(p, q, b, cut, ex)
    \/ \E p \in Ops : MCGetWorkflowLease_Base(p)
    \/ \E p \in Ops : MCGetCurrentWorkflowRunID(p)
    \/ \E p \in Ops : MCGetWorkflowLease_Current(p)
    \/ \E p \in Ops : MCInvoke_Deduplicate(p)
    \/ \E p \in Ops, r \in Runs : MCInvoke_NewRunID(p, r)
    \/ \E p \in Ops : MCResetWorkflow_UpdateResetRunID(p)
    \/ \E p \in Ops : MCForkHistoryBranch(p)
    \/ \E p \in Ops : MCRebuild(p)
    \/ \E p \in Ops : MCReadHistoryBranch(p)
    \/ \E p \in Ops : MCReapplyEvents(p)
    \/ \E p \in Ops : MCReapplyEventsFromBranch_NextRun(p)
    \/ \E p \in Ops : MCGetNextEventIDBranchToken(p)
    \/ \E p \in Ops : MCScheduleWorkflowTask(p)
    \/ \E p \in Ops : MCUpdateWorkflowExecution_BypassCurrent(p)
    \/ \E p \in Ops : MCCreateWorkflowExecution_BrandNew(p)
    \/ \E p \in Ops : MCUpdateWorkflowExecution_WithNew(p)
    \/ \E p \in Ops : MCConflictResolveWorkflowExecution(p)
    \/ \E p \in Ops : MCCreateWorkflowExecution_Start(p)
    \/ \E r \in Runs : MCAppendHistoryNodes_Current(r)
    \/ \E r \in Runs : MCAppendHistoryNodes(r)
    \/ \E r \in Runs : MCPersistenceAppendTimeout(r)
    \/ \E r \in Runs : MCAssertNotCurrentExecution(r)
    \/ \E r \in Runs : MCCommitWorkflowExecution(r)
    \/ \E r \in Runs : MCRejectWorkflowExecution(r)
    \/ \E r \in Runs : MCPersistenceDefiniteRejection(r)
    \/ \E r \in Runs : MCPersistenceUncertainReturn(r)
    \/ \E r \in Runs : MCPersistenceReturn(r)
    \/ \E p \in Ops : MCInvoke_ReturnSuccess(p)
    \/ \E p \in Ops : MCReleaseWorkflowLease_Success(p)
    \/ \E p \in Ops : MCReceiveResetResponse(p)
    \/ \E p \in Ops : MCLoseResetResponse(p)
    \/ \E p \in Ops : MCReplayResetRequest(p)
    \/ \E p \in Ops : MCReleaseWorkflowLease_Error(p)
    \/ \E p \in Ops : MCRetryResetWorkflowExecution(p)
    \/ MCCrashHistoryService
    \/ MCAcquireShard
    \/ \E p \in Ops : MCExpireResetRequest(p)
    \/ \E p \in Ops : MCReadTransientFailure(p)
    \/ \E r \in Runs : MCAddWorkflowTaskStartedEvent(r)
    \/ \E r \in Runs, id \in UpdateIDs, payload \in Payloads : MCAddWorkflowExecutionUpdateAcceptedEvent(r, id, payload)
    \/ \E r \in Runs, id \in UpdateIDs : MCAddWorkflowExecutionUpdateCompletedEvent(r, id)
    \/ \E r \in Runs, id \in UpdateIDs, payload \in Payloads : MCAddWorkflowExecutionSignaled(r, id, payload)
    \/ \E r \in Runs, s \in Runs, id \in StartIDs : MCContinueAsNew(r, s, id)
    \/ \E r \in Runs : MCCompleteWorkflowExecution(r)
    \/ \E r \in Runs : MCDeleteWorkflowExecution(r)
    \/ \E r \in Runs : MCDeleteExecutionTask(r)
    \/ \E r \in Runs : MCDeleteWorkflowExecution_AcquireIO(r)
    \/ \E r \in Runs : MCDeleteCurrentWorkflowExecution(r)
    \/ \E r \in Runs : MCDeleteWorkflowMutableState(r)
    \/ \E r \in Runs : MCGetHistoryTreeContainingBranch(r)
    \/ \E r \in Runs : MCDeleteHistoryBranch_SQL(r)
    \/ \E r \in Runs : MCDeleteHistoryBranch_CassandraRow(r)
    \/ \E r \in Runs : MCDeleteHistoryBranch_CassandraRanges(r)
    \/ \E r \in Runs : MCHistoryScannerAge(r)
    \/ \E r \in Runs : MCHistoryScavengerVerify(r)

ReactiveNext ==
    \/ \E p \in Ops : MCGetWorkflowLease_Base(p)
    \/ \E p \in Ops : MCGetCurrentWorkflowRunID(p)
    \/ \E p \in Ops : MCGetWorkflowLease_Current(p)
    \/ \E p \in Ops : MCInvoke_Deduplicate(p)
    \/ \E p \in Ops, r \in Runs : MCInvoke_NewRunID(p, r)
    \/ \E p \in Ops : MCResetWorkflow_UpdateResetRunID(p)
    \/ \E p \in Ops : MCForkHistoryBranch(p)
    \/ \E p \in Ops : MCRebuild(p)
    \/ \E p \in Ops : MCReadHistoryBranch(p)
    \/ \E p \in Ops : MCReapplyEvents(p)
    \/ \E p \in Ops : MCReapplyEventsFromBranch_NextRun(p)
    \/ \E p \in Ops : MCGetNextEventIDBranchToken(p)
    \/ \E p \in Ops : MCScheduleWorkflowTask(p)
    \/ \E p \in Ops : MCUpdateWorkflowExecution_BypassCurrent(p)
    \/ \E p \in Ops : MCCreateWorkflowExecution_BrandNew(p)
    \/ \E p \in Ops : MCUpdateWorkflowExecution_WithNew(p)
    \/ \E p \in Ops : MCConflictResolveWorkflowExecution(p)
    \/ \E p \in Ops : MCCreateWorkflowExecution_Start(p)
    \/ \E r \in Runs : MCAppendHistoryNodes_Current(r)
    \/ \E r \in Runs : MCAppendHistoryNodes(r)
    \/ \E r \in Runs : MCAssertNotCurrentExecution(r)
    \/ \E r \in Runs : MCCommitWorkflowExecution(r)
    \/ \E r \in Runs : MCRejectWorkflowExecution(r)
    \/ \E r \in Runs : MCPersistenceReturn(r)
    \/ \E p \in Ops : MCInvoke_ReturnSuccess(p)
    \/ \E p \in Ops : MCReleaseWorkflowLease_Success(p)
    \/ \E p \in Ops : MCReceiveResetResponse(p)
    \/ \E p \in Ops : MCReleaseWorkflowLease_Error(p)
    \/ \E p \in Ops : MCRetryResetWorkflowExecution(p)
    \/ MCAcquireShard
    \/ \E r \in Runs : MCAddWorkflowTaskStartedEvent(r)
    \/ \E r \in Runs, id \in UpdateIDs : MCAddWorkflowExecutionUpdateCompletedEvent(r, id)
    \/ \E r \in Runs : MCCompleteWorkflowExecution(r)
    \/ \E r \in Runs : MCDeleteExecutionTask(r)
    \/ \E r \in Runs : MCDeleteWorkflowExecution_AcquireIO(r)
    \/ \E r \in Runs : MCDeleteCurrentWorkflowExecution(r)
    \/ \E r \in Runs : MCDeleteWorkflowMutableState(r)
    \/ \E r \in Runs : MCGetHistoryTreeContainingBranch(r)
    \/ \E r \in Runs : MCDeleteHistoryBranch_SQL(r)
    \/ \E r \in Runs : MCDeleteHistoryBranch_CassandraRow(r)
    \/ \E r \in Runs : MCDeleteHistoryBranch_CassandraRanges(r)
    \/ \E r \in Runs : MCHistoryScavengerVerify(r)

MCSpec == MCInit /\ [][MCNext]_mcvars
MCTypeOK == TypeOK /\ \A k \in DOMAIN FaultLimits : faultCounts[k] \in 0..FaultLimits[k]
PendingBuffer == Cardinality({r \in Runs : pending[r].state \in {"submitted","current-issued","current-appended","candidate-issued","precheck","precheck-issued","ready","metadata-issued"}}) <= MaxPending
MCConstraint == HistoryBound /\ PendingBuffer
\* Never put counters into a VIEW used for state fingerprinting: those counters
\* determine enabled behavior. This diagnostic view is intentionally not configured.
MCView == vars
Symmetry == Permutations(Runs) \cup Permutations(Ops)
\* Liveness uses action-instance fairness, not the weak fairness of one giant OR.
RecoveryFairness ==
    /\ WF_mcvars(MCBeginAcquireShard)
    /\ WF_mcvars(MCRenewShardRange)
    /\ WF_mcvars(MCAcquireShard)
    /\ \A p \in Ops :
          /\ WF_mcvars(MCRetryResetWorkflowExecution(p))
          /\ WF_mcvars(MCGetWorkflowLease_Base(p))
          /\ WF_mcvars(MCGetCurrentWorkflowRunID(p))
          /\ WF_mcvars(MCGetWorkflowLease_Current(p))
          /\ WF_mcvars(MCInvoke_Deduplicate(p))
          /\ WF_mcvars(\E r \in Runs : MCInvoke_NewRunID(p,r))
          /\ WF_mcvars(MCResetWorkflow_UpdateResetRunID(p))
          /\ WF_mcvars(MCForkHistoryBranch(p))
          /\ WF_mcvars(MCRebuild(p))
          /\ WF_mcvars(MCReadHistoryBranch(p))
          /\ WF_mcvars(MCReapplyEvents(p))
          /\ WF_mcvars(MCReapplyEventsFromBranch_NextRun(p))
          /\ WF_mcvars(MCGetNextEventIDBranchToken(p))
          /\ WF_mcvars(MCScheduleWorkflowTask(p))
          /\ WF_mcvars(MCUpdateWorkflowExecution_BypassCurrent(p))
          /\ WF_mcvars(MCCreateWorkflowExecution_BrandNew(p))
          /\ WF_mcvars(MCUpdateWorkflowExecution_WithNew(p))
          /\ WF_mcvars(MCConflictResolveWorkflowExecution(p))
          /\ WF_mcvars(MCCreateWorkflowExecution_Start(p))
          /\ WF_mcvars(MCInvoke_ReturnSuccess(p))
          /\ WF_mcvars(MCReleaseWorkflowLease_Success(p))
          /\ WF_mcvars(MCReceiveResetResponse(p))
          /\ WF_mcvars(MCReleaseWorkflowLease_Error(p))
    /\ \A r \in Runs :
          /\ WF_mcvars(MCIssueCurrentHistory(r))
          /\ WF_mcvars(MCIssueCandidateHistory(r))
          /\ WF_mcvars(MCIssueCurrentRead(r))
          /\ WF_mcvars(MCIssueMetadata(r))
          /\ WF_mcvars(MCAppendHistoryNodes_Current(r))
          /\ WF_mcvars(MCAppendHistoryNodes(r))
          /\ WF_mcvars(MCAssertNotCurrentExecution(r))
          /\ WF_mcvars(MCCommitWorkflowExecution(r))
          /\ WF_mcvars(MCRejectWorkflowExecution(r))
          /\ WF_mcvars(MCPersistenceReturn(r))
          /\ WF_mcvars(MCDeleteExecutionTask(r))
          /\ WF_mcvars(MCDeleteWorkflowExecution_AcquireIO(r))
          /\ WF_mcvars(MCDeleteCurrentWorkflowExecution(r))
          /\ WF_mcvars(MCDeleteWorkflowMutableState(r))
          /\ WF_mcvars(MCGetHistoryTreeContainingBranch(r))
          /\ WF_mcvars(MCDeleteHistoryBranch_SQL(r))
          /\ WF_mcvars(MCDeleteHistoryBranch_CassandraRow(r))
          /\ WF_mcvars(MCDeleteHistoryBranch_CassandraRanges(r))
          /\ WF_mcvars(MCPersistFirstWorkflowTaskSchedule(r))
          /\ WF_mcvars(MCAddWorkflowTaskStartedEvent(r))
          /\ WF_mcvars(MCCompleteWorkflowExecution(r))
RecoverySpec == MCSpec /\ RecoveryFairness
\* An unfulfilled valid request with exhausted symbols is an incomplete bound,
\* never a recovery success. Liveness cfg enables this invariant as a tripwire.
FreshRunCapacity == ~RunIDExhausted
=============================================================================
