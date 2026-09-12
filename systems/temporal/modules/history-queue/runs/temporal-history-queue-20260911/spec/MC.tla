------------------------------ MODULE MC ------------------------------
EXTENDS base
Base == INSTANCE base
CONSTANTS RequestLimit, WriteFailLimit, PubTimeoutLimit, NoticeLossLimit, TakeoverLimit, StopLimit, DeleteFailLimit, DeleteLossLimit, ShardFailLimit, ShardLossLimit, RetryLimit, UnexpectedFaultLimit, TerminalErrorLimit, TerminalDropLimit, MatchingLossLimit, DlqLossLimit, BufferLimit
VARIABLE faults
mcvars == <<s, faults>>
MCInit == Init /\ faults = [request |-> 0, writeFail |-> 0, pubTimeout |-> 0, noticeLoss |-> 0, takeover |-> 0, stop |-> 0, deleteFail |-> 0, deleteLoss |-> 0, shardFail |-> 0, shardLoss |-> 0, retry |-> 0, unexpected |-> 0, terminalError |-> 0, terminalDrop |-> 0, matchingLoss |-> 0, dlqLoss |-> 0]

\* Scenario-derived injection: H/task_key_manager.go:45-53; H/task_request_tracker.go:36-67; S1
MCSetAndTrackTaskKeys(o,t,g,k) ==
  /\ faults.request < RequestLimit
  /\ Base!SetAndTrackTaskKeys(o,t,g,k)
  /\ faults' = [faults EXCEPT !.request = @+1]

\* Scenario-derived injection: SQL/execution.go:350-357,426-440; SQL/common.go:52-80; S1
MCUpdateWorkflowExecutionFail(t) ==
  /\ faults.writeFail < WriteFailLimit
  /\ Base!UpdateWorkflowExecutionFail(t)
  /\ faults' = [faults EXCEPT !.writeFail = @+1]

\* Scenario-derived injection: H/task_request_tracker.go:73-85; H/context_impl.go:1540-1548; S1
MCTaskRequestTimeout(t) ==
  /\ faults.pubTimeout < PubTimeoutLimit
  /\ Base!TaskRequestTimeout(t)
  /\ faults' = [faults EXCEPT !.pubTimeout = @+1]

\* Scenario-derived injection: Q/queue_immediate.go:124-175; lossy notification interface; S1
MCDropNotification(o) ==
  /\ faults.noticeLoss < NoticeLossLimit
  /\ Base!DropNotification(o)
  /\ faults' = [faults EXCEPT !.noticeLoss = @+1]

\* Scenario-derived injection: H/context_impl.go:2030-2082,1164-1186; S1/S4
MCAcquireShardBegin(o) ==
  /\ (s.own[o].mode = "lost" \/ faults.takeover < TakeoverLimit)
  /\ Base!AcquireShardBegin(o)
  /\ faults' = [faults EXCEPT !.takeover = IF s.own[o].mode = "absent" THEN @+1 ELSE @]

\* Scenario-derived injection: Q/queue_base.go:245-249; Q/reader.go:161-177; Q/rescheduler.go:105-117; S4
MCStopReaderGroup(o) ==
  /\ faults.stop < StopLimit
  /\ Base!StopReaderGroup(o)
  /\ faults' = [faults EXCEPT !.stop = @+1]

\* Scenario-derived injection: SQL/execution_tasks.go:365-370; Q/queue_base.go:351-354; S3
MCRangeCompleteTasksFail(o) ==
  /\ faults.deleteFail < DeleteFailLimit
  /\ Base!RangeCompleteTasksFail(o)
  /\ faults' = [faults EXCEPT !.deleteFail = @+1]

\* Scenario-derived injection: Q/queue_base.go:351-357; common/persistence/faultinjection/fault.go:42-47; S3
MCRangeCompleteTasksLostReply(o) ==
  /\ faults.deleteLoss < DeleteLossLimit
  /\ Base!RangeCompleteTasksLostReply(o)
  /\ faults' = [faults EXCEPT !.deleteLoss = @+1]

\* Scenario-derived injection: H/context_impl.go:1283-1298; SQL/common.go:52-80; S3
MCUpdateShardFail(j) ==
  /\ faults.shardFail < ShardFailLimit
  /\ Base!UpdateShardFail(j)
  /\ faults' = [faults EXCEPT !.shardFail = @+1]

\* Scenario-derived injection: H/context_impl.go:1291-1298,1540-1548; S3
MCUpdateShardLostReply(j) ==
  /\ faults.shardLoss < ShardLossLimit
  /\ Base!UpdateShardLostReply(j)
  /\ faults' = [faults EXCEPT !.shardLoss = @+1]

\* Scenario-derived injection: Q/executable.go:511-558,623-625; S5
MCExecuteRetryableError(e) ==
  /\ faults.retry < RetryLimit
  /\ Base!ExecuteRetryableError(e)
  /\ faults' = [faults EXCEPT !.retry = @+1]

\* Scenario-derived injection: Q/executable.go:627-681; S5
MCExecuteUnexpectedError(e) ==
  /\ faults.unexpected < UnexpectedFaultLimit
  /\ Base!ExecuteUnexpectedError(e)
  /\ faults' = [faults EXCEPT !.unexpected = @+1]

\* Scenario-derived injection: Q/executable.go:561-578,646-665; S5
MCExecuteTerminalError(e) ==
  /\ faults.terminalError < TerminalErrorLimit
  /\ Base!ExecuteTerminalError(e)
  /\ faults' = [faults EXCEPT !.terminalError = @+1]

\* Scenario-derived injection: M/matching_engine.go:810-818,1037-1045; M/task.go:373-397; S5
MCMatchingTerminalDiscard(e) ==
  /\ faults.terminalDrop < TerminalDropLimit
  /\ Base!MatchingTerminalDiscard(e)
  /\ faults' = [faults EXCEPT !.terminalDrop = @+1]

\* Scenario-derived injection: service/history/transfer_queue_active_task_executor.go:339-347,373; S4/S5 RPC interface
MCMatchingLostReply(e) ==
  /\ faults.matchingLoss < MatchingLossLimit
  /\ Base!MatchingLostReply(e)
  /\ faults' = [faults EXCEPT !.matchingLoss = @+1]

\* Scenario-derived injection: SQL/queue_v2.go:96-104; Q/executable.go:434-439; S5
MCEnqueueTaskLostReply(e) ==
  /\ faults.dlqLoss < DlqLossLimit
  /\ Base!EnqueueTaskLostReply(e)
  /\ faults' = [faults EXCEPT !.dlqLoss = @+1]

MCNext ==
  \/ \E o \in Owners, t \in Tasks, g \in Groups, k \in {"Workflow","Activity"} : MCSetAndTrackTaskKeys(o,t,g,k)
  \/ /\ (\E t \in Tasks : AppendHistoryNodes(t))
     /\ UNCHANGED faults
  \/ /\ (\E t \in Tasks : UpdateWorkflowExecutionCommit(t))
     /\ UNCHANGED faults
  \/ /\ (\E t \in Tasks : UpdateWorkflowExecutionFenced(t))
     /\ UNCHANGED faults
  \/ \E t \in Tasks : MCUpdateWorkflowExecutionFail(t)
  \/ /\ (\E t \in Tasks : TaskRequestCompletion(t))
     /\ UNCHANGED faults
  \/ \E t \in Tasks : MCTaskRequestTimeout(t)
  \/ \E o \in Owners : MCDropNotification(o)
  \/ \E o \in Owners : MCAcquireShardBegin(o)
  \/ /\ (\E o \in Owners : RenewRangeLockedCommit(o))
     /\ UNCHANGED faults
  \/ /\ (\E o \in Owners : RenewRangeLockedFenced(o))
     /\ UNCHANGED faults
  \/ /\ (\E o \in Owners : AcquireShardComplete(o))
     /\ UNCHANGED faults
  \/ \E o \in Owners : MCStopReaderGroup(o)
  \/ /\ (\E o \in Owners, id \in Sids : ProcessNewRange(o,id))
     /\ UNCHANGED faults
  \/ /\ (\E o \in Owners, r \in Readers, es \in ExecSequences : SelectTasks(o,r,es))
     /\ UNCHANGED faults
  \/ /\ (\E o \in Owners, r \in Readers : NotifyReader(o,r))
     /\ UNCHANGED faults
  \/ /\ (\E o \in Owners : CheckpointBegin(o))
     /\ UNCHANGED faults
  \/ /\ (\E o \in Owners, r \in Readers : ShrinkSlices(o,r))
     /\ UNCHANGED faults
  \/ /\ (\E o \in Owners : MoveGroupCollect(o))
     /\ UNCHANGED faults
  \/ /\ (\E o \in Owners : MoveGroupSplit(o))
     /\ UNCHANGED faults
  \/ /\ (\E o \in Owners : MoveGroupMerge(o))
     /\ UNCHANGED faults
  \/ /\ (\E o \in Owners, r \in Readers : CheckpointScopes(o,r))
     /\ UNCHANGED faults
  \/ /\ (\E o \in Owners : RangeCompleteTasksBegin(o))
     /\ UNCHANGED faults
  \/ /\ (\E o \in Owners : RangeCompleteTasksCommit(o))
     /\ UNCHANGED faults
  \/ \E o \in Owners : MCRangeCompleteTasksFail(o)
  \/ /\ (\E o \in Owners : RangeCompleteTasksReply(o))
     /\ UNCHANGED faults
  \/ \E o \in Owners : MCRangeCompleteTasksLostReply(o)
  \/ /\ (\E o \in Owners : SetQueueStateBatched(o))
     /\ UNCHANGED faults
  \/ /\ (\E o \in Owners, j \in Jids : SetQueueStateSnapshot(o,j))
     /\ UNCHANGED faults
  \/ /\ (\E o \in Owners : SetQueueStateClosed(o))
     /\ UNCHANGED faults
  \/ /\ (\E o \in Owners, j \in Jids : UpdateShardInfoSnapshot(o,j))
     /\ UNCHANGED faults
  \/ /\ (\E j \in Jids : UpdateShardCommit(j))
     /\ UNCHANGED faults
  \/ /\ (\E j \in Jids : UpdateShardFenced(j))
     /\ UNCHANGED faults
  \/ \E j \in Jids : MCUpdateShardFail(j)
  \/ /\ (\E j \in Jids : UpdateShardReply(j))
     /\ UNCHANGED faults
  \/ \E j \in Jids : MCUpdateShardLostReply(j)
  \/ /\ (\E o \in Owners : ProcessNewRangeMerge(o))
     /\ UNCHANGED faults
  \/ /\ (\E o \in Owners, r \in Readers, id \in Sids, cut \in Keys, fresh \in Sids : SplitSlicesByRange(o,r,id,cut,fresh))
     /\ UNCHANGED faults
  \/ /\ (\E o \in Owners, r \in Readers, i \in 1..SliceSlots : CompactSlices(o,r,i))
     /\ UNCHANGED faults
  \/ /\ (\E o \in Owners, r \in Readers, id \in Sids : ClearSlicesBegin(o,r,id))
     /\ UNCHANGED faults
  \/ /\ (\E o \in Owners, e \in Eids : ClearCancel(o,e))
     /\ UNCHANGED faults
  \/ /\ (\E o \in Owners : ClearSlicesComplete(o))
     /\ UNCHANGED faults
  \/ /\ (\E e \in Eids : Execute(e))
     /\ UNCHANGED faults
  \/ /\ (\E e \in Eids : ProcessTransferTaskEligible(e))
     /\ UNCHANGED faults
  \/ /\ (\E e \in Eids : ProcessTransferTaskObsolete(e))
     /\ UNCHANGED faults
  \/ \E e \in Eids : MCExecuteRetryableError(e)
  \/ \E e \in Eids : MCExecuteUnexpectedError(e)
  \/ \E e \in Eids : MCExecuteTerminalError(e)
  \/ /\ (\E e \in Eids : MatchingSpoolCommit(e))
     /\ UNCHANGED faults
  \/ /\ (\E e \in Eids : RecordTaskStarted(e))
     /\ UNCHANGED faults
  \/ \E e \in Eids : MCMatchingTerminalDiscard(e)
  \/ /\ (\E e \in Eids : MatchingReply(e))
     /\ UNCHANGED faults
  \/ \E e \in Eids : MCMatchingLostReply(e)
  \/ /\ (\E e \in Eids : EnqueueTaskCommit(e))
     /\ UNCHANGED faults
  \/ /\ (\E e \in Eids : EnqueueTaskReply(e))
     /\ UNCHANGED faults
  \/ \E e \in Eids : MCEnqueueTaskLostReply(e)
  \/ /\ (\E e \in Eids : HandleErrAck(e))
     /\ UNCHANGED faults
  \/ /\ (\E e \in Eids : HandleErrRetry(e))
     /\ UNCHANGED faults
  \/ /\ (\E e \in Eids : HandleErrTerminal(e))
     /\ UNCHANGED faults
  \/ /\ (\E e \in Eids : HandleErrUnexpected(e))
     /\ UNCHANGED faults
  \/ /\ (\E e \in Eids : Ack(e))
     /\ UNCHANGED faults
  \/ /\ (\E e \in Eids : Nack(e))
     /\ UNCHANGED faults
  \/ /\ (\E e \in Eids : Reschedule(e))
     /\ UNCHANGED faults
  \/ /\ (\E t \in Tasks : WorkflowNoLongerNeedsTask(t))
     /\ UNCHANGED faults
  \/ /\ (\E t \in Tasks : WorkerComplete(t))
     /\ UNCHANGED faults

MCSpec == MCInit /\ [][MCNext]_mcvars
Symmetry == Permutations(Groups)
\* Debug-only projection; NOT configured as VIEW because fault budgets affect
\* future enabled actions. Dropping them from fingerprints is not justified.
ModelView == s
MessageBuffer == Cardinality({t \in Tasks : s.pub[t].reply = "none" /\ s.pub[t].phase /= "unused"})
  + Cardinality({j \in Jids : s.snaps[j].phase /= "free"})
  + Cardinality({e \in Eids : s.ex[e].pc \in {"matching","matchingReply","dlq","dlqReply"}})
BufferConstraint == MessageBuffer <= BufferLimit
MCTypeOK == TypeOK /\ faults.request \in 0..RequestLimit /\ faults.writeFail \in 0..WriteFailLimit /\ faults.pubTimeout \in 0..PubTimeoutLimit /\ faults.noticeLoss \in 0..NoticeLossLimit /\ faults.takeover \in 0..TakeoverLimit /\ faults.stop \in 0..StopLimit /\ faults.deleteFail \in 0..DeleteFailLimit /\ faults.deleteLoss \in 0..DeleteLossLimit /\ faults.shardFail \in 0..ShardFailLimit /\ faults.shardLoss \in 0..ShardLossLimit /\ faults.retry \in 0..RetryLimit /\ faults.unexpected \in 0..UnexpectedFaultLimit /\ faults.terminalError \in 0..TerminalErrorLimit /\ faults.terminalDrop \in 0..TerminalDropLimit /\ faults.matchingLoss \in 0..MatchingLossLimit /\ faults.dlqLoss \in 0..DlqLossLimit
\* No symmetry for temporal runs. Fair service is per reader / wrapper / store
\* slot, not global Next. Stable ownership excludes a horizon-ending lost shard.
EventuallyHealthy == <>[](s.own[s.db.owner].mode = "active" /\
  s.own[s.db.owner].epoch = s.db.range)
ReaderServiceStep(o,r) == \E es \in ExecSequences : SelectTasks(o,r,es)
PollServiceStep(o) == (\E id \in Sids : ProcessNewRange(o,id)) \/ ProcessNewRangeMerge(o)
CheckpointServiceStep(o) == CheckpointBegin(o) \/
  (\E r \in Readers : ShrinkSlices(o,r) \/ CheckpointScopes(o,r)) \/
  MoveGroupCollect(o) \/ MoveGroupSplit(o) \/ MoveGroupMerge(o) \/
  RangeCompleteTasksBegin(o) \/ RangeCompleteTasksCommit(o) \/
  RangeCompleteTasksReply(o) \/ SetQueueStateBatched(o) \/
  (\E j \in Jids : SetQueueStateSnapshot(o,j)) \/ SetQueueStateClosed(o) \/
  (\E e \in Eids : ClearCancel(o,e)) \/ ClearSlicesComplete(o)
ExecServiceStep(e) == Execute(e) \/ ProcessTransferTaskEligible(e) \/
  ProcessTransferTaskObsolete(e) \/ MatchingSpoolCommit(e) \/ RecordTaskStarted(e) \/
  MatchingReply(e) \/ EnqueueTaskCommit(e) \/ EnqueueTaskReply(e) \/
  HandleErrAck(e) \/ HandleErrRetry(e) \/ HandleErrTerminal(e) \/
  HandleErrUnexpected(e) \/ Ack(e) \/ Nack(e) \/ Reschedule(e)
StoreServiceStep(j) == UpdateShardCommit(j) \/ UpdateShardFenced(j) \/ UpdateShardReply(j)
PublicationServiceStep(t) == AppendHistoryNodes(t) \/ UpdateWorkflowExecutionCommit(t) \/
  UpdateWorkflowExecutionFenced(t) \/ TaskRequestCompletion(t)
\* Fairness actions assign every member of mcvars, just as MCNext does.
ReaderService(o,r) == ReaderServiceStep(o,r) /\ UNCHANGED faults
PollService(o) == PollServiceStep(o) /\ UNCHANGED faults
CheckpointService(o) == CheckpointServiceStep(o) /\ UNCHANGED faults
ExecService(e) == ExecServiceStep(e) /\ UNCHANGED faults
StoreService(j) == StoreServiceStep(j) /\ UNCHANGED faults
PublicationService(t) == PublicationServiceStep(t) /\ UNCHANGED faults
FairServices ==
  /\ \A o \in Owners : SF_mcvars(PollService(o)) /\ SF_mcvars(CheckpointService(o))
  /\ \A o \in Owners : \A r \in Readers : SF_mcvars(ReaderService(o,r))
  /\ \A e \in Eids : SF_mcvars(ExecService(e))
  /\ \A j \in Jids : WF_mcvars(StoreService(j))
  /\ \A t \in Tasks : WF_mcvars(PublicationService(t))
MCFairSpec == MCSpec /\ FairServices
CheckedDispatchProgress == EventuallyHealthy => EligibleDispatchProgress
CheckedEventualCleanup == EventuallyHealthy => EventualCleanup
=============================================================================
