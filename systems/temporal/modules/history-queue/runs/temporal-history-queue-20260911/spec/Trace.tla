------------------------------ MODULE Trace ------------------------------
EXTENDS base, Json, IOUtils
VARIABLE l
tracevars == <<s,l>>
JsonFile == IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON ELSE "../traces/trace.ndjson"
TraceLog == ndJsonDeserialize(JsonFile)
\* No tag filtering: an unmodeled/missing event must fail, not disappear.
Evt == TraceLog[l]
DecodeScope(j) == [j EXCEPT !.pred = SS(@)]
DecodeSlice(j) == [j EXCEPT !.pred = SS(@), !.iters = SS(@), !.tracked = SS(@)]
DecodeQS(j) == [j EXCEPT !.readers = [r \in Readers |->
  [i \in 1..Len(j.readers[r+1]) |-> DecodeScope(j.readers[r+1][i])]]]
DecodeDB(j) == [j EXCEPT !.rows = SS(@), !.workflow = SS(@), !.published = SS(@),
  !.matching = SS(@), !.started = SS(@), !.obsolete = SS(@), !.terminal = SS(@),
  !.dlq = SS(@), !.completed = SS(@), !.deleted = SS(@), !.acked = SS(@),
  !.protected = SS(@), !.queue = DecodeQS(@)]
DecodeQ(j) == [j EXCEPT
  !.lists = [r \in Readers |-> [i \in 1..Len(j.lists[r+1]) |-> DecodeSlice(j.lists[r+1][i])]],
  !.cursor = [r \in Readers |-> j.cursor[r+1]],
  !.detached = [r \in Readers |-> DecodeSlice(j.detached[r+1])],
  !.captured = DecodeQS(@), !.memory = DecodeQS(@), !.moveGroups = SS(@),
  !.moved = [i \in 1..Len(j.moved) |-> DecodeSlice(j.moved[i])], !.cancelTodo = SS(@)]
DecodeState(j) == [j EXCEPT !.db = DecodeDB(@),
  !.own = [o \in Owners |-> [j.own[o] EXCEPT !.renewData = DecodeQS(@)]],
  !.q = [o \in Owners |-> DecodeQ(j.q[o])],
  !.snaps = [n \in Jids |-> [j.snaps[n] EXCEPT !.data = DecodeQS(@)]]]
\* Encoding is for diagnostic fixtures only; implementation observations must
\* come from instrumentation/readback, never from these model expressions.
EncodeQS(qs) == [qs EXCEPT !.readers = <<qs.readers[0],qs.readers[1]>>]
EncodeDB(db) == [db EXCEPT !.queue = EncodeQS(@)]
EncodeQ(q) == [q EXCEPT !.lists = <<q.lists[0],q.lists[1]>>,
  !.cursor = <<q.cursor[0],q.cursor[1]>>, !.detached = <<q.detached[0],q.detached[1]>>,
  !.captured = EncodeQS(@), !.memory = EncodeQS(@)]
EncodeState(st) == [st EXCEPT !.db = EncodeDB(@),
  !.own = [o \in Owners |-> [st.own[o] EXCEPT !.renewData = EncodeQS(@)]],
  !.q = [o \in Owners |-> EncodeQ(st.q[o])],
  !.snaps = [n \in Jids |-> [st.snaps[n] EXCEPT !.data = EncodeQS(@)]]]
ConstantsSnapshot == [task_count |-> TaskCount, owner_count |-> OwnerCount,
  groups |-> Groups, slice_slots |-> SliceSlots, exec_slots |-> ExecSlots,
  snapshot_slots |-> SnapshotSlots, batch_size |-> BatchSize, max_epoch |-> MaxEpoch,
  move_threshold |-> MoveThreshold, predicate_limit |-> PredicateLimit,
  shrink_keys |-> ShrinkKeys, unexpected_limit |-> UnexpectedLimit, dlq_enabled |-> DLQEnabled]
DecodeConstants(j) == [j EXCEPT !.groups = SS(@)]
Envelope(e) == /\ e.tag = "trace" /\ e.seq \in Nat
                /\ e.schema = 1 /\ e.provenance \in {"implementation","synthetic-spec-test"}
\* Mandatory full snapshot equality: no optional-field checks and no TRUE stub.
ValidatePostState(e) == /\ Envelope(e) /\ e.seq = l /\ s' = DecodeState(e.post)
TraceInit ==
  /\ Assert(Len(TraceLog) >= 2, "trace requires Init and Endpoint")
  /\ Assert(TraceLog[Len(TraceLog)].event = "Endpoint", "missing complete Endpoint")
  /\ TraceLog[1].event = "Init"
  /\ Envelope(TraceLog[1]) /\ TraceLog[1].seq = 1
  /\ TraceLog[1].revision = "0c010ce5fe8c0180aa7573c72fe8fc87c6df7025"
  /\ TraceLog[1].backend = "sqlite-wal"
  /\ DecodeConstants(TraceLog[1].constants) = ConstantsSnapshot
  /\ Init /\ s = DecodeState(TraceLog[1].post) /\ l = 2
\* Endpoint is a control record, not a fabricated implementation transition.
\* Its persisted projection must come from independent readback after quiescence.
DurableProjection(st) == [range |-> st.db.range, owner |-> st.db.owner,
  rows |-> st.db.rows, workflow |-> st.db.workflow, matching |-> st.db.matching,
  started |-> st.db.started, obsolete |-> st.db.obsolete, dlq |-> st.db.dlq,
  completed |-> st.db.completed, queue |-> st.db.queue]
DecodeReadback(j) == [j EXCEPT !.rows = SS(@), !.workflow = SS(@), !.matching = SS(@),
  !.started = SS(@), !.obsolete = SS(@), !.dlq = SS(@), !.completed = SS(@), !.queue = DecodeQS(@)]
TraceEndpoint ==
  /\ Evt.event = "Endpoint" /\ l = Len(TraceLog)
  /\ Evt.complete = TRUE /\ Evt.independent_readback = TRUE
  /\ DurableProjection(s) = DecodeReadback(Evt.readback)
  /\ UNCHANGED s /\ ValidatePostState(Evt) /\ l' = l+1

\* H/task_key_manager.go:45-53; H/task_request_tracker.go:36-67; S1
TraceSetAndTrackTaskKeys ==
  /\ Evt.event = "SetAndTrackTaskKeys"
  /\ SetAndTrackTaskKeys(Evt.args.o,Evt.args.t,Evt.args.g,Evt.args.k)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* SQL/execution.go:338-348; S1
TraceAppendHistoryNodes ==
  /\ Evt.event = "AppendHistoryNodes"
  /\ AppendHistoryNodes(Evt.args.t)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* SQL/execution.go:351-357,434-443; SQL/shard.go:152-174; S1/S4
TraceUpdateWorkflowExecutionCommit ==
  /\ Evt.event = "UpdateWorkflowExecutionCommit"
  /\ UpdateWorkflowExecutionCommit(Evt.args.t)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* SQL/shard.go:158-174; S1/S4
TraceUpdateWorkflowExecutionFenced ==
  /\ Evt.event = "UpdateWorkflowExecutionFenced"
  /\ UpdateWorkflowExecutionFenced(Evt.args.t)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* SQL/execution.go:350-357,426-440; SQL/common.go:52-80; S1
TraceUpdateWorkflowExecutionFail ==
  /\ Evt.event = "UpdateWorkflowExecutionFail"
  /\ UpdateWorkflowExecutionFail(Evt.args.t)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* H/task_request_tracker.go:69-89; H/context_impl.go:1506-1538; S1
TraceTaskRequestCompletion ==
  /\ Evt.event = "TaskRequestCompletion"
  /\ TaskRequestCompletion(Evt.args.t)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* H/task_request_tracker.go:73-85; H/context_impl.go:1540-1548; S1
TraceTaskRequestTimeout ==
  /\ Evt.event = "TaskRequestTimeout"
  /\ TaskRequestTimeout(Evt.args.t)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* Q/queue_immediate.go:124-175; lossy notification interface; S1
TraceDropNotification ==
  /\ Evt.event = "DropNotification"
  /\ DropNotification(Evt.args.o)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* H/context_impl.go:2030-2082,1164-1186; S1/S4
TraceAcquireShardBegin ==
  /\ Evt.event = "AcquireShardBegin"
  /\ AcquireShardBegin(Evt.args.o)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* H/context_impl.go:1173-1186; SQL/shard.go:82-112; S1/S4
TraceRenewRangeLockedCommit ==
  /\ Evt.event = "RenewRangeLockedCommit"
  /\ RenewRangeLockedCommit(Evt.args.o)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* SQL/shard.go:132-148; H/context_impl.go:1187-1195; S4
TraceRenewRangeLockedFenced ==
  /\ Evt.event = "RenewRangeLockedFenced"
  /\ RenewRangeLockedFenced(Evt.args.o)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* H/context_impl.go:1198-1207,2084-2109; Q/queue_base.go:178-221; S1/S4
TraceAcquireShardComplete ==
  /\ Evt.event = "AcquireShardComplete"
  /\ AcquireShardComplete(Evt.args.o)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* Q/queue_base.go:245-249; Q/reader.go:161-177; Q/rescheduler.go:105-117; S4
TraceStopReaderGroup ==
  /\ Evt.event = "StopReaderGroup"
  /\ StopReaderGroup(Evt.args.o)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* Q/queue_base.go:262-292; H/task_key_manager.go:88-118; S1/S2
TraceProcessNewRange ==
  /\ Evt.event = "ProcessNewRange"
  /\ ProcessNewRange(Evt.args.o,Evt.args.id)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* Q/reader.go:438-486; Q/slice.go:365-408; Q/iterator.go:53-64; S2/S4
TraceSelectTasks ==
  /\ Evt.event = "SelectTasks"
  /\ SelectTasks(Evt.args.o,Evt.args.r,Evt.args.es)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* Q/reader.go:372-382,507-511; Q/queue_immediate.go:81; S2
TraceNotifyReader ==
  /\ Evt.event = "NotifyReader"
  /\ NotifyReader(Evt.args.o,Evt.args.r)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* Q/queue_immediate.go:155-156; Q/queue_base.go:295-299; S2/S3
TraceCheckpointBegin ==
  /\ Evt.event = "CheckpointBegin"
  /\ CheckpointBegin(Evt.args.o)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* Q/reader.go:350-369; Q/slice.go:307-362; Q/tracker.go:85-105; S2/S3
TraceShrinkSlices ==
  /\ Evt.event = "ShrinkSlices"
  /\ ShrinkSlices(Evt.args.o,Evt.args.r)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* Q/action_move_group.go:60-83; S2
TraceMoveGroupCollect ==
  /\ Evt.event = "MoveGroupCollect"
  /\ MoveGroupCollect(Evt.args.o)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* Q/action_move_group.go:85-98; Q/reader.go:201-228; Q/slice.go:139-156; S2
TraceMoveGroupSplit ==
  /\ Evt.event = "MoveGroupSplit"
  /\ MoveGroupSplit(Evt.args.o)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* Q/action_move_group.go:100-102; Q/reader.go:230-271; Q/slice.go:165-257; S2
TraceMoveGroupMerge ==
  /\ Evt.event = "MoveGroupMerge"
  /\ MoveGroupMerge(Evt.args.o)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* Q/queue_base.go:316-330; Q/reader.go:180-189; S3
TraceCheckpointScopes ==
  /\ Evt.event = "CheckpointScopes"
  /\ CheckpointScopes(Evt.args.o,Evt.args.r)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* Q/queue_base.go:340-358,364-370; S3/S4
TraceRangeCompleteTasksBegin ==
  /\ Evt.event = "RangeCompleteTasksBegin"
  /\ RangeCompleteTasksBegin(Evt.args.o)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* SQL/execution_tasks.go:361-372; SQL/sqlplugin/sqlite/execution.go:110,625-634; S3/S4
TraceRangeCompleteTasksCommit ==
  /\ Evt.event = "RangeCompleteTasksCommit"
  /\ RangeCompleteTasksCommit(Evt.args.o)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* SQL/execution_tasks.go:365-370; Q/queue_base.go:351-354; S3
TraceRangeCompleteTasksFail ==
  /\ Evt.event = "RangeCompleteTasksFail"
  /\ RangeCompleteTasksFail(Evt.args.o)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* Q/queue_base.go:351-360; S3
TraceRangeCompleteTasksReply ==
  /\ Evt.event = "RangeCompleteTasksReply"
  /\ RangeCompleteTasksReply(Evt.args.o)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* Q/queue_base.go:351-357; common/persistence/faultinjection/fault.go:42-47; S3
TraceRangeCompleteTasksLostReply ==
  /\ Evt.event = "RangeCompleteTasksLostReply"
  /\ RangeCompleteTasksLostReply(Evt.args.o)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* Q/queue_base.go:397-411; H/context_impl.go:1232-1249; S3
TraceSetQueueStateBatched ==
  /\ Evt.event = "SetQueueStateBatched"
  /\ SetQueueStateBatched(Evt.args.o)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* Q/queue_base.go:408-411; H/context_impl.go:1232-1281; S3
TraceSetQueueStateSnapshot ==
  /\ Evt.event = "SetQueueStateSnapshot"
  /\ SetQueueStateSnapshot(Evt.args.o,Evt.args.j)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* H/context_impl.go:1232-1235; S3/S4
TraceSetQueueStateClosed ==
  /\ Evt.event = "SetQueueStateClosed"
  /\ SetQueueStateClosed(Evt.args.o)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* H/context_impl.go:388-404,1228-1281; S3
TraceUpdateShardInfoSnapshot ==
  /\ Evt.event = "UpdateShardInfoSnapshot"
  /\ UpdateShardInfoSnapshot(Evt.args.o,Evt.args.j)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* H/context_impl.go:1283-1291; SQL/shard.go:82-112; S3/S4
TraceUpdateShardCommit ==
  /\ Evt.event = "UpdateShardCommit"
  /\ UpdateShardCommit(Evt.args.j)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* SQL/shard.go:132-148; H/context_impl.go:1291-1298; S4
TraceUpdateShardFenced ==
  /\ Evt.event = "UpdateShardFenced"
  /\ UpdateShardFenced(Evt.args.j)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* H/context_impl.go:1283-1298; SQL/common.go:52-80; S3
TraceUpdateShardFail ==
  /\ Evt.event = "UpdateShardFail"
  /\ UpdateShardFail(Evt.args.j)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* H/context_impl.go:1291-1301,1506-1548; S3/S4
TraceUpdateShardReply ==
  /\ Evt.event = "UpdateShardReply"
  /\ UpdateShardReply(Evt.args.j)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* H/context_impl.go:1291-1298,1540-1548; S3
TraceUpdateShardLostReply ==
  /\ Evt.event = "UpdateShardLostReply"
  /\ UpdateShardLostReply(Evt.args.j)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* Q/queue_base.go:262-292; Q/reader.go:230-271; S1/S2
TraceProcessNewRangeMerge ==
  /\ Evt.event = "ProcessNewRangeMerge"
  /\ ProcessNewRangeMerge(Evt.args.o)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* Q/reader.go:201-228; Q/slice.go:101-136; S2
TraceSplitSlicesByRange ==
  /\ Evt.event = "SplitSlicesByRange"
  /\ SplitSlicesByRange(Evt.args.o,Evt.args.r,Evt.args.id,Evt.args.cut,Evt.args.fresh)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* Q/reader.go:320-348; Q/slice.go:277-304; S2
TraceCompactSlices ==
  /\ Evt.event = "CompactSlices"
  /\ CompactSlices(Evt.args.o,Evt.args.r,Evt.args.i)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* Q/reader.go:306-318; Q/slice.go:425-433; S2/S4
TraceClearSlicesBegin ==
  /\ Evt.event = "ClearSlicesBegin"
  /\ ClearSlicesBegin(Evt.args.o,Evt.args.r,Evt.args.id)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* Q/tracker.go:108-111; Q/executable.go:733-740; S2/S4
TraceClearCancel ==
  /\ Evt.event = "ClearCancel"
  /\ ClearCancel(Evt.args.o,Evt.args.e)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* Q/tracker.go:113-114; Q/reader.go:317,489-505; S2
TraceClearSlicesComplete ==
  /\ Evt.event = "ClearSlicesComplete"
  /\ ClearSlicesComplete(Evt.args.o)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* Q/executable.go:273-298,385-402; S4/S5
TraceExecute ==
  /\ Evt.event = "Execute"
  /\ Execute(Evt.args.e)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* service/history/transfer_queue_active_task_executor.go:250-286,302-347; S5
TraceProcessTransferTaskEligible ==
  /\ Evt.event = "ProcessTransferTaskEligible"
  /\ ProcessTransferTaskEligible(Evt.args.e)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* service/history/transfer_queue_active_task_executor.go:250-274,306-316; S5
TraceProcessTransferTaskObsolete ==
  /\ Evt.event = "ProcessTransferTaskObsolete"
  /\ ProcessTransferTaskObsolete(Evt.args.e)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* Q/executable.go:511-558,623-625; S5
TraceExecuteRetryableError ==
  /\ Evt.event = "ExecuteRetryableError"
  /\ ExecuteRetryableError(Evt.args.e)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* Q/executable.go:627-681; S5
TraceExecuteUnexpectedError ==
  /\ Evt.event = "ExecuteUnexpectedError"
  /\ ExecuteUnexpectedError(Evt.args.e)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* Q/executable.go:561-578,646-665; S5
TraceExecuteTerminalError ==
  /\ Evt.event = "ExecuteTerminalError"
  /\ ExecuteTerminalError(Evt.args.e)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* M/task_queue_partition_manager.go:555-700; M/backlog_manager.go:164-179; M/task_writer.go:141; S5
TraceMatchingSpoolCommit ==
  /\ Evt.event = "MatchingSpoolCommit"
  /\ MatchingSpoolCommit(Evt.args.e)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* M/matching_engine.go:810-864,1037-1108; M/matching_engine.go:3527,3606; S4/S5
TraceRecordTaskStarted ==
  /\ Evt.event = "RecordTaskStarted"
  /\ RecordTaskStarted(Evt.args.e)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* M/matching_engine.go:810-818,1037-1045; M/task.go:373-397; S5
TraceMatchingTerminalDiscard ==
  /\ Evt.event = "MatchingTerminalDiscard"
  /\ MatchingTerminalDiscard(Evt.args.e)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* M/task.go:373-397; Q/executable.go:584-586; S5
TraceMatchingReply ==
  /\ Evt.event = "MatchingReply"
  /\ MatchingReply(Evt.args.e)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* service/history/transfer_queue_active_task_executor.go:339-347,373; S4/S5 RPC interface
TraceMatchingLostReply ==
  /\ Evt.event = "MatchingLostReply"
  /\ MatchingLostReply(Evt.args.e)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* Q/executable.go:385-389,420-439; Q/dlq_writer.go:63-103; SQL/queue_v2.go:45-104; S5
TraceEnqueueTaskCommit ==
  /\ Evt.event = "EnqueueTaskCommit"
  /\ EnqueueTaskCommit(Evt.args.e)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* Q/dlq_writer.go:93-103; Q/executable.go:426-439; S5
TraceEnqueueTaskReply ==
  /\ Evt.event = "EnqueueTaskReply"
  /\ EnqueueTaskReply(Evt.args.e)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* SQL/queue_v2.go:96-104; Q/executable.go:434-439; S5
TraceEnqueueTaskLostReply ==
  /\ Evt.event = "EnqueueTaskLostReply"
  /\ EnqueueTaskLostReply(Evt.args.e)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* Q/executable.go:584-610; S5
TraceHandleErrAck ==
  /\ Evt.event = "HandleErrAck"
  /\ HandleErrAck(Evt.args.e)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* Q/executable.go:612-625; S5
TraceHandleErrRetry ==
  /\ Evt.event = "HandleErrRetry"
  /\ HandleErrRetry(Evt.args.e)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* Q/executable.go:646-665; S5
TraceHandleErrTerminal ==
  /\ Evt.event = "HandleErrTerminal"
  /\ HandleErrTerminal(Evt.args.e)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* Q/executable.go:627-629,668-681; S5
TraceHandleErrUnexpected ==
  /\ Evt.event = "HandleErrUnexpected"
  /\ HandleErrUnexpected(Evt.args.e)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* Q/executable.go:742-750; S2/S4/S5
TraceAck ==
  /\ Evt.event = "Ack"
  /\ Ack(Evt.args.e)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* Q/executable.go:768-802; S2/S5
TraceNack ==
  /\ Evt.event = "Nack"
  /\ Nack(Evt.args.e)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* Q/rescheduler.go:208-240; Q/executable.go:794-802; S2/S5
TraceReschedule ==
  /\ Evt.event = "Reschedule"
  /\ Reschedule(Evt.args.e)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* service/history/transfer_queue_active_task_executor.go:250-274,306-316; S5 interface
TraceWorkflowNoLongerNeedsTask ==
  /\ Evt.event = "WorkflowNoLongerNeedsTask"
  /\ WorkflowNoLongerNeedsTask(Evt.args.t)
  /\ ValidatePostState(Evt) /\ l' = l+1

\* service/history/api/respondactivitytaskcompleted/api.go:50-133;
\* service/history/api/respondworkflowtaskcompleted/api.go:675-680; S5
TraceWorkerComplete ==
  /\ Evt.event = "WorkerComplete"
  /\ WorkerComplete(Evt.args.t)
  /\ ValidatePostState(Evt) /\ l' = l+1

TraceStep == TraceEndpoint
  \/ TraceSetAndTrackTaskKeys
  \/ TraceAppendHistoryNodes
  \/ TraceUpdateWorkflowExecutionCommit
  \/ TraceUpdateWorkflowExecutionFenced
  \/ TraceUpdateWorkflowExecutionFail
  \/ TraceTaskRequestCompletion
  \/ TraceTaskRequestTimeout
  \/ TraceDropNotification
  \/ TraceAcquireShardBegin
  \/ TraceRenewRangeLockedCommit
  \/ TraceRenewRangeLockedFenced
  \/ TraceAcquireShardComplete
  \/ TraceStopReaderGroup
  \/ TraceProcessNewRange
  \/ TraceSelectTasks
  \/ TraceNotifyReader
  \/ TraceCheckpointBegin
  \/ TraceShrinkSlices
  \/ TraceMoveGroupCollect
  \/ TraceMoveGroupSplit
  \/ TraceMoveGroupMerge
  \/ TraceCheckpointScopes
  \/ TraceRangeCompleteTasksBegin
  \/ TraceRangeCompleteTasksCommit
  \/ TraceRangeCompleteTasksFail
  \/ TraceRangeCompleteTasksReply
  \/ TraceRangeCompleteTasksLostReply
  \/ TraceSetQueueStateBatched
  \/ TraceSetQueueStateSnapshot
  \/ TraceSetQueueStateClosed
  \/ TraceUpdateShardInfoSnapshot
  \/ TraceUpdateShardCommit
  \/ TraceUpdateShardFenced
  \/ TraceUpdateShardFail
  \/ TraceUpdateShardReply
  \/ TraceUpdateShardLostReply
  \/ TraceProcessNewRangeMerge
  \/ TraceSplitSlicesByRange
  \/ TraceCompactSlices
  \/ TraceClearSlicesBegin
  \/ TraceClearCancel
  \/ TraceClearSlicesComplete
  \/ TraceExecute
  \/ TraceProcessTransferTaskEligible
  \/ TraceProcessTransferTaskObsolete
  \/ TraceExecuteRetryableError
  \/ TraceExecuteUnexpectedError
  \/ TraceExecuteTerminalError
  \/ TraceMatchingSpoolCommit
  \/ TraceRecordTaskStarted
  \/ TraceMatchingTerminalDiscard
  \/ TraceMatchingReply
  \/ TraceMatchingLostReply
  \/ TraceEnqueueTaskCommit
  \/ TraceEnqueueTaskReply
  \/ TraceEnqueueTaskLostReply
  \/ TraceHandleErrAck
  \/ TraceHandleErrRetry
  \/ TraceHandleErrTerminal
  \/ TraceHandleErrUnexpected
  \/ TraceAck
  \/ TraceNack
  \/ TraceReschedule
  \/ TraceWorkflowNoLongerNeedsTask
  \/ TraceWorkerComplete

TraceNext == /\ l <= Len(TraceLog) /\ TraceStep
TraceSpec == TraceInit /\ [][TraceNext]_tracevars /\ WF_tracevars(TraceNext)
TraceMatched == <>(l > Len(TraceLog))
=============================================================================
