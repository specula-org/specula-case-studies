# Applied instrumentation points

All locations refer to the current applied source checkout.

| Source | Line | Hook |
|---|---:|---|
| `common/persistence/sql/execution.go` | 351 | `hqtrace.Publication("AppendHistoryNodes", hqtrace.M{"history_batches": len(request.UpdateWorkflowNewEvents)})` |
| `common/persistence/sql/execution.go` | 361 | `hqtrace.Publication("UpdateWorkflowExecutionCommit", hqtrace.M{"request_range": request.RangeID, "checked_range": hqtrace.Extra["checked_range"]})` |
| `common/persistence/sql/execution.go` | 367 | `hqtrace.Publication(name, hqtrace.M{"error": hqtrace.Error(err), "request_range": request.RangeID})` |
| `common/persistence/sql/execution_tasks.go` | 371 | `hqtrace.Current("RangeCompleteTasksFail", hqtrace.M{"error": hqtrace.Error(err)})` |
| `common/persistence/sql/execution_tasks.go` | 374 | `hqtrace.Current("RangeCompleteTasksCommit", hqtrace.M{"lo": request.InclusiveMinTaskKey.TaskID, "hi": request.ExclusiveMaxTaskKey.TaskID})` |
| `common/persistence/sql/shard.go` | 128 | `hqtrace.Current(name, hqtrace.M{"request_range": request.PreviousRangeID, "checked_range": hqtrace.Extra["checked_range"], "new_range": request.RangeID, "blob": request.ShardInfo, "error": hqtrace.Error(err)})` |
| `common/persistence/sql/shard.go` | 130 | `hqtrace.Emit(name, hqtrace.M{"j": 1}, hqtrace.M{"request_range": request.PreviousRangeID, "checked_range": hqtrace.Extra["checked_range"], "new_range": request.RangeID, "blob": request.ShardInfo, "error": hqtrace.Error(err)})` |
| `common/persistence/sql/task_v1.go` | 100 | `hqtrace.Execution("MatchingSpoolCommit", hqtrace.M{"store": "sqlTaskManagerV1.CreateTasks", "rows": tasksRows, "request_range": request.RangeID})` |
| `service/history/hq_scenarios_test.go` | 282 | `hqtrace.Emit("Init", nil, nil)` |
| `service/history/hq_scenarios_test.go` | 411 | `hqtrace.Emit("Endpoint", nil, hqtrace.M{"complete": true, "independent_readback": true, "outstanding_calls": 0})` |
| `service/history/hq_scenarios_test.go` | 532 | `hqtrace.Emit("Endpoint", nil, hqtrace.M{"complete": true, "independent_readback": true, "outstanding_calls": 0})` |
| `service/history/queues/action_move_group.go` | 82 | `hqtrace.Current("MoveGroupCollect", hqtrace.M{"groups": groupsToMove, "counts": fmt.Sprint(pendingTaskPerGroup)})` |
| `service/history/queues/action_move_group.go` | 106 | `hqtrace.Current("MoveGroupSplit", hqtrace.M{"moved": hqSlices(slicesToMove), "lineage": lineage})` |
| `service/history/queues/action_move_group.go` | 109 | `hqtrace.Current("MoveGroupMerge", nil)` |
| `service/history/queues/executable.go` | 277 | `hqtrace.Execution("ExecuteRetryableError", hqtrace.M{"error": hqtrace.Error(retErr)})` |
| `service/history/queues/executable.go` | 305 | `hqtrace.Execution("Execute", hqtrace.M{"terminal": e.terminalFailureCause != nil})` |
| `service/history/queues/executable.go` | 601 | `hqtrace.Execution(name, hqtrace.M{"error": hqtrace.Error(err), "returned": hqtrace.Error(retErr)})` |
| `service/history/queues/executable.go` | 763 | `defer hqtrace.Execution("Ack", nil)` |
| `service/history/queues/executable.go` | 788 | `defer hqtrace.Execution("Nack", nil)` |
| `service/history/queues/queue_base.go` | 251 | `hqtrace.Current("StopReaderGroup", nil)` |
| `service/history/queues/queue_base.go` | 269 | `hqtrace.Current(eventName, nil)` |
| `service/history/queues/queue_base.go` | 306 | `hqtrace.Current("CheckpointBegin", nil)` |
| `service/history/queues/queue_base.go` | 310 | `hqtrace.Emit("ShrinkSlices", hqtrace.M{"o": hqtrace.Owner, "r": id}, nil)` |
| `service/history/queues/queue_base.go` | 334 | `hqtrace.Emit("CheckpointScopes", hqtrace.M{"o": hqtrace.Owner, "r": readerID}, hqtrace.M{"scopes": hqScopes(scopes)})` |
| `service/history/queues/queue_base.go` | 364 | `hqtrace.Current("RangeCompleteTasksBegin", hqtrace.M{"delete": doDelete, "high": newExclusiveDeletionHighWatermark.TaskID})` |
| `service/history/queues/queue_base.go` | 374 | `hqtrace.Current(name, hqtrace.M{"error": hqtrace.Error(err)})` |
| `service/history/queues/queue_base.go` | 380 | `hqtrace.Current("RangeCompleteTasksReply", nil)` |
| `service/history/queues/queue_probe.go` | 182 | `hqtrace.Current("DropNotification", nil)` |
| `service/history/queues/reader.go` | 230 | `hqtrace.Emit("SplitSlicesByRange", hqtrace.M{"o": hqtrace.Owner, "r": r.readerID, "cut": detail["cut"]}, detail)` |
| `service/history/queues/reader.go` | 322 | `hqtrace.Current("ClearSlicesComplete", nil)` |
| `service/history/queues/reader.go` | 354 | `hqtrace.Emit("CompactSlices", hqtrace.M{"o": hqtrace.Owner, "r": r.readerID, "i": 1}, hqtrace.M{"old": old, "new": hqtrace.Ptr(r.slices.Front().Value)})` |
| `service/history/queues/reader.go` | 390 | `hqtrace.Emit("NotifyReader", hqtrace.M{"o": hqtrace.Owner, "r": r.readerID}, nil)` |
| `service/history/queues/reader.go` | 483 | `hqtrace.Emit("SelectTasks", hqtrace.M{"o": hqtrace.Owner, "r": r.readerID, "es": es}, hqtrace.M{"slice": hqtrace.Ptr(loadSlice), "selected_slice": hqSlice(loadSlice)})` |
| `service/history/queues/rescheduler.go` | 240 | `hqtrace.Emit("Reschedule", hqtrace.M{"e": hqtrace.Ptr(executable)}, nil)` |
| `service/history/queues/slice.go` | 434 | `hqtrace.Emit("ClearSlicesBegin", hqtrace.M{"o": hqtrace.Owner, "r": hqtrace.Extra["clear_reader"], "id": hqtrace.Ptr(s)}, nil)` |
| `service/history/queues/tracker.go` | 112 | `hqtrace.Emit("ClearCancel", hqtrace.M{"o": hqtrace.Owner, "e": hqtrace.Ptr(executable)}, nil)` |
| `service/history/shard/context_impl.go` | 650 | `hqtrace.Emit("SetAndTrackTaskKeys", hqtrace.M{"o": hqtrace.Owner, "t": hqtrace.Task}, hqtrace.M{"tasks": request.UpdateWorkflowMutation.Tasks[tasks.CategoryTransfer], "range": request.RangeID})` |
| `service/history/shard/context_impl.go` | 660 | `hqtrace.Publication(name, hqtrace.M{"error": hqtrace.Error(err)})` |
| `service/history/shard/context_impl.go` | 1189 | `hqtrace.Current("AcquireShardBegin", hqtrace.M{"expected": previousRangeID, "snapshot": s.shardInfo, "fresh": !s.engineFuture.Ready()})` |
| `service/history/shard/context_impl.go` | 1256 | `hqtrace.Current("SetQueueStateBatched", hqtrace.M{"too_early": tooEarly, "too_few": tooFewTasksCompleted})` |
| `service/history/shard/context_impl.go` | 1290 | `hqtrace.Emit("SetQueueStateSnapshot", hqtrace.M{"o": hqtrace.Owner, "j": 1}, hqtrace.M{"snapshot": updatedShardInfo})` |
| `service/history/shard/context_impl.go` | 1302 | `defer func() { hqtrace.Emit("UpdateShardReply", hqtrace.M{"j": 1}, hqtrace.M{"error": hqtrace.Error(err)}) }()` |
| `service/history/shard/context_impl.go` | 2122 | `hqtrace.Current("AcquireShardComplete", hqtrace.M{"engine_ready": s.engineFuture.Ready()})` |
| `service/history/transfer_queue_active_task_executor.go` | 287 | `hqtrace.Execution("ProcessTransferTaskEligible", hqtrace.M{"task": task})` |
| `service/history/transfer_queue_active_task_executor.go` | 341 | `hqtrace.Execution("ProcessTransferTaskEligible", hqtrace.M{"task": transferTask})` |
| `service/history/transfer_queue_task_executor_base.go` | 123 | `hqtrace.Execution("MatchingReply", nil)` |
| `service/history/transfer_queue_task_executor_base.go` | 126 | `hqtrace.Execution("MatchingLostReply", hqtrace.M{"error": hqtrace.Error(err)})` |
| `service/history/transfer_queue_task_executor_base.go` | 185 | `hqtrace.Execution("MatchingReply", nil)` |
| `service/history/transfer_queue_task_executor_base.go` | 188 | `hqtrace.Execution("MatchingLostReply", hqtrace.M{"error": hqtrace.Error(err)})` |
