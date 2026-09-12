------------------------------ MODULE Witness ------------------------------
EXTENDS Trace
CONSTANT FixtureKind
VARIABLE pc, events, done
wvars == <<s,pc,events,done,l>>
Steps == CASE
  FixtureKind = "cursor" -> <<
    [event |-> "SetAndTrackTaskKeys", args |-> [o |-> 1, t |-> 1, g |-> "g1", k |-> "Workflow"]],
    [event |-> "AppendHistoryNodes", args |-> [t |-> 1]],
    [event |-> "UpdateWorkflowExecutionCommit", args |-> [t |-> 1]],
    [event |-> "TaskRequestCompletion", args |-> [t |-> 1]],
    [event |-> "SetAndTrackTaskKeys", args |-> [o |-> 1, t |-> 2, g |-> "g2", k |-> "Activity"]],
    [event |-> "AppendHistoryNodes", args |-> [t |-> 2]],
    [event |-> "UpdateWorkflowExecutionCommit", args |-> [t |-> 2]],
    [event |-> "TaskRequestCompletion", args |-> [t |-> 2]],
    [event |-> "SetAndTrackTaskKeys", args |-> [o |-> 1, t |-> 3, g |-> "g1", k |-> "Activity"]],
    [event |-> "AppendHistoryNodes", args |-> [t |-> 3]],
    [event |-> "UpdateWorkflowExecutionCommit", args |-> [t |-> 3]],
    [event |-> "TaskRequestCompletion", args |-> [t |-> 3]],
    [event |-> "ProcessNewRange", args |-> [o |-> 1, id |-> 1]],
    [event |-> "SplitSlicesByRange", args |-> [o |-> 1, r |-> 0, id |-> 1, cut |-> 6, fresh |-> 2]],
    [event |-> "SplitSlicesByRange", args |-> [o |-> 1, r |-> 0, id |-> 2, cut |-> 7, fresh |-> 3]],
    [event |-> "SelectTasks", args |-> [o |-> 1, r |-> 0, es |-> <<1>>]],
    [event |-> "SelectTasks", args |-> [o |-> 1, r |-> 0, es |-> <<>>]],
    [event |-> "SelectTasks", args |-> [o |-> 1, r |-> 0, es |-> <<2>>]],
    [event |-> "Execute", args |-> [e |-> 2]],
    [event |-> "ProcessTransferTaskEligible", args |-> [e |-> 2]],
    [event |-> "MatchingSpoolCommit", args |-> [e |-> 2]],
    [event |-> "MatchingReply", args |-> [e |-> 2]],
    [event |-> "HandleErrAck", args |-> [e |-> 2]],
    [event |-> "Ack", args |-> [e |-> 2]],
    [event |-> "CheckpointBegin", args |-> [o |-> 1]],
    [event |-> "ShrinkSlices", args |-> [o |-> 1, r |-> 0]],
    [event |-> "ShrinkSlices", args |-> [o |-> 1, r |-> 1]],
    [event |-> "MoveGroupCollect", args |-> [o |-> 1]],
    [event |-> "MoveGroupSplit", args |-> [o |-> 1]],
    [event |-> "MoveGroupMerge", args |-> [o |-> 1]],
    [event |-> "CheckpointScopes", args |-> [o |-> 1, r |-> 0]],
    [event |-> "CheckpointScopes", args |-> [o |-> 1, r |-> 1]],
    [event |-> "RangeCompleteTasksBegin", args |-> [o |-> 1]],
    [event |-> "RangeCompleteTasksCommit", args |-> [o |-> 1]],
    [event |-> "RangeCompleteTasksReply", args |-> [o |-> 1]],
    [event |-> "SetQueueStateBatched", args |-> [o |-> 1]],
    [event |-> "ClearSlicesBegin", args |-> [o |-> 1, r |-> 1, id |-> 1]],
    [event |-> "ClearCancel", args |-> [o |-> 1, e |-> 1]],
    [event |-> "ClearSlicesComplete", args |-> [o |-> 1]],
    [event |-> "SelectTasks", args |-> [o |-> 1, r |-> 1, es |-> <<2>>]],
    [event |-> "Execute", args |-> [e |-> 2]],
    [event |-> "ProcessTransferTaskEligible", args |-> [e |-> 2]],
    [event |-> "MatchingSpoolCommit", args |-> [e |-> 2]],
    [event |-> "MatchingReply", args |-> [e |-> 2]],
    [event |-> "HandleErrAck", args |-> [e |-> 2]],
    [event |-> "Ack", args |-> [e |-> 2]],
    [event |-> "CheckpointBegin", args |-> [o |-> 1]],
    [event |-> "ShrinkSlices", args |-> [o |-> 1, r |-> 0]],
    [event |-> "ShrinkSlices", args |-> [o |-> 1, r |-> 1]],
    [event |-> "MoveGroupCollect", args |-> [o |-> 1]],
    [event |-> "CheckpointScopes", args |-> [o |-> 1, r |-> 0]],
    [event |-> "CheckpointScopes", args |-> [o |-> 1, r |-> 1]],
    [event |-> "RangeCompleteTasksBegin", args |-> [o |-> 1]],
    [event |-> "RangeCompleteTasksCommit", args |-> [o |-> 1]],
    [event |-> "RangeCompleteTasksReply", args |-> [o |-> 1]],
    [event |-> "SetQueueStateSnapshot", args |-> [o |-> 1, j |-> 1]],
    [event |-> "UpdateShardCommit", args |-> [j |-> 1]],
    [event |-> "UpdateShardReply", args |-> [j |-> 1]],
    [event |-> "SelectTasks", args |-> [o |-> 1, r |-> 1, es |-> <<>>]],
    [event |-> "NotifyReader", args |-> [o |-> 1, r |-> 1]]
  >>
  []   FixtureKind = "healthy" -> <<
    [event |-> "SetAndTrackTaskKeys", args |-> [o |-> 1, t |-> 1, g |-> "g1", k |-> "Workflow"]],
    [event |-> "AppendHistoryNodes", args |-> [t |-> 1]],
    [event |-> "UpdateWorkflowExecutionCommit", args |-> [t |-> 1]],
    [event |-> "TaskRequestCompletion", args |-> [t |-> 1]],
    [event |-> "SetAndTrackTaskKeys", args |-> [o |-> 1, t |-> 2, g |-> "g2", k |-> "Activity"]],
    [event |-> "AppendHistoryNodes", args |-> [t |-> 2]],
    [event |-> "UpdateWorkflowExecutionCommit", args |-> [t |-> 2]],
    [event |-> "TaskRequestCompletion", args |-> [t |-> 2]],
    [event |-> "SetAndTrackTaskKeys", args |-> [o |-> 1, t |-> 3, g |-> "g1", k |-> "Activity"]],
    [event |-> "AppendHistoryNodes", args |-> [t |-> 3]],
    [event |-> "UpdateWorkflowExecutionCommit", args |-> [t |-> 3]],
    [event |-> "TaskRequestCompletion", args |-> [t |-> 3]],
    [event |-> "ProcessNewRange", args |-> [o |-> 1, id |-> 1]],
    [event |-> "SplitSlicesByRange", args |-> [o |-> 1, r |-> 0, id |-> 1, cut |-> 6, fresh |-> 2]],
    [event |-> "SplitSlicesByRange", args |-> [o |-> 1, r |-> 0, id |-> 2, cut |-> 7, fresh |-> 3]],
    [event |-> "SelectTasks", args |-> [o |-> 1, r |-> 0, es |-> <<1>>]],
    [event |-> "SelectTasks", args |-> [o |-> 1, r |-> 0, es |-> <<>>]],
    [event |-> "SelectTasks", args |-> [o |-> 1, r |-> 0, es |-> <<2>>]],
    [event |-> "Execute", args |-> [e |-> 2]],
    [event |-> "ProcessTransferTaskEligible", args |-> [e |-> 2]],
    [event |-> "MatchingSpoolCommit", args |-> [e |-> 2]],
    [event |-> "MatchingReply", args |-> [e |-> 2]],
    [event |-> "HandleErrAck", args |-> [e |-> 2]],
    [event |-> "Ack", args |-> [e |-> 2]],
    [event |-> "CheckpointBegin", args |-> [o |-> 1]],
    [event |-> "ShrinkSlices", args |-> [o |-> 1, r |-> 0]],
    [event |-> "ShrinkSlices", args |-> [o |-> 1, r |-> 1]],
    [event |-> "MoveGroupCollect", args |-> [o |-> 1]],
    [event |-> "MoveGroupSplit", args |-> [o |-> 1]],
    [event |-> "MoveGroupMerge", args |-> [o |-> 1]],
    [event |-> "CheckpointScopes", args |-> [o |-> 1, r |-> 0]],
    [event |-> "CheckpointScopes", args |-> [o |-> 1, r |-> 1]],
    [event |-> "RangeCompleteTasksBegin", args |-> [o |-> 1]],
    [event |-> "RangeCompleteTasksCommit", args |-> [o |-> 1]],
    [event |-> "RangeCompleteTasksReply", args |-> [o |-> 1]],
    [event |-> "SetQueueStateBatched", args |-> [o |-> 1]],
    [event |-> "ClearSlicesBegin", args |-> [o |-> 1, r |-> 1, id |-> 1]],
    [event |-> "ClearCancel", args |-> [o |-> 1, e |-> 1]],
    [event |-> "ClearSlicesComplete", args |-> [o |-> 1]],
    [event |-> "SelectTasks", args |-> [o |-> 1, r |-> 1, es |-> <<2>>]],
    [event |-> "Execute", args |-> [e |-> 2]],
    [event |-> "ProcessTransferTaskEligible", args |-> [e |-> 2]],
    [event |-> "MatchingSpoolCommit", args |-> [e |-> 2]],
    [event |-> "MatchingReply", args |-> [e |-> 2]],
    [event |-> "HandleErrAck", args |-> [e |-> 2]],
    [event |-> "Ack", args |-> [e |-> 2]],
    [event |-> "SelectTasks", args |-> [o |-> 1, r |-> 1, es |-> <<>>]],
    [event |-> "CheckpointBegin", args |-> [o |-> 1]],
    [event |-> "ShrinkSlices", args |-> [o |-> 1, r |-> 0]],
    [event |-> "ShrinkSlices", args |-> [o |-> 1, r |-> 1]],
    [event |-> "MoveGroupCollect", args |-> [o |-> 1]],
    [event |-> "CheckpointScopes", args |-> [o |-> 1, r |-> 0]],
    [event |-> "CheckpointScopes", args |-> [o |-> 1, r |-> 1]],
    [event |-> "RangeCompleteTasksBegin", args |-> [o |-> 1]],
    [event |-> "RangeCompleteTasksCommit", args |-> [o |-> 1]],
    [event |-> "RangeCompleteTasksReply", args |-> [o |-> 1]],
    [event |-> "SetQueueStateSnapshot", args |-> [o |-> 1, j |-> 1]],
    [event |-> "UpdateShardCommit", args |-> [j |-> 1]],
    [event |-> "UpdateShardReply", args |-> [j |-> 1]],
    [event |-> "SelectTasks", args |-> [o |-> 1, r |-> 1, es |-> <<3>>]],
    [event |-> "Execute", args |-> [e |-> 3]],
    [event |-> "ProcessTransferTaskEligible", args |-> [e |-> 3]],
    [event |-> "MatchingSpoolCommit", args |-> [e |-> 3]],
    [event |-> "MatchingReply", args |-> [e |-> 3]],
    [event |-> "HandleErrAck", args |-> [e |-> 3]],
    [event |-> "Ack", args |-> [e |-> 3]]
  >>
  []   FixtureKind = "recovery" -> <<
    [event |-> "SetAndTrackTaskKeys", args |-> [o |-> 1, t |-> 1, g |-> "g1", k |-> "Workflow"]],
    [event |-> "AppendHistoryNodes", args |-> [t |-> 1]],
    [event |-> "UpdateWorkflowExecutionCommit", args |-> [t |-> 1]],
    [event |-> "TaskRequestCompletion", args |-> [t |-> 1]],
    [event |-> "SetAndTrackTaskKeys", args |-> [o |-> 1, t |-> 2, g |-> "g2", k |-> "Activity"]],
    [event |-> "AppendHistoryNodes", args |-> [t |-> 2]],
    [event |-> "UpdateWorkflowExecutionCommit", args |-> [t |-> 2]],
    [event |-> "TaskRequestCompletion", args |-> [t |-> 2]],
    [event |-> "SetAndTrackTaskKeys", args |-> [o |-> 1, t |-> 3, g |-> "g1", k |-> "Activity"]],
    [event |-> "AppendHistoryNodes", args |-> [t |-> 3]],
    [event |-> "UpdateWorkflowExecutionCommit", args |-> [t |-> 3]],
    [event |-> "TaskRequestCompletion", args |-> [t |-> 3]],
    [event |-> "ProcessNewRange", args |-> [o |-> 1, id |-> 1]],
    [event |-> "SplitSlicesByRange", args |-> [o |-> 1, r |-> 0, id |-> 1, cut |-> 6, fresh |-> 2]],
    [event |-> "SplitSlicesByRange", args |-> [o |-> 1, r |-> 0, id |-> 2, cut |-> 7, fresh |-> 3]],
    [event |-> "SelectTasks", args |-> [o |-> 1, r |-> 0, es |-> <<1>>]],
    [event |-> "SelectTasks", args |-> [o |-> 1, r |-> 0, es |-> <<>>]],
    [event |-> "SelectTasks", args |-> [o |-> 1, r |-> 0, es |-> <<2>>]],
    [event |-> "Execute", args |-> [e |-> 2]],
    [event |-> "ProcessTransferTaskEligible", args |-> [e |-> 2]],
    [event |-> "MatchingSpoolCommit", args |-> [e |-> 2]],
    [event |-> "MatchingReply", args |-> [e |-> 2]],
    [event |-> "HandleErrAck", args |-> [e |-> 2]],
    [event |-> "Ack", args |-> [e |-> 2]],
    [event |-> "CheckpointBegin", args |-> [o |-> 1]],
    [event |-> "ShrinkSlices", args |-> [o |-> 1, r |-> 0]],
    [event |-> "ShrinkSlices", args |-> [o |-> 1, r |-> 1]],
    [event |-> "MoveGroupCollect", args |-> [o |-> 1]],
    [event |-> "MoveGroupSplit", args |-> [o |-> 1]],
    [event |-> "MoveGroupMerge", args |-> [o |-> 1]],
    [event |-> "CheckpointScopes", args |-> [o |-> 1, r |-> 0]],
    [event |-> "CheckpointScopes", args |-> [o |-> 1, r |-> 1]],
    [event |-> "RangeCompleteTasksBegin", args |-> [o |-> 1]],
    [event |-> "RangeCompleteTasksCommit", args |-> [o |-> 1]],
    [event |-> "RangeCompleteTasksReply", args |-> [o |-> 1]],
    [event |-> "SetQueueStateBatched", args |-> [o |-> 1]],
    [event |-> "ClearSlicesBegin", args |-> [o |-> 1, r |-> 1, id |-> 1]],
    [event |-> "ClearCancel", args |-> [o |-> 1, e |-> 1]],
    [event |-> "ClearSlicesComplete", args |-> [o |-> 1]],
    [event |-> "SelectTasks", args |-> [o |-> 1, r |-> 1, es |-> <<2>>]],
    [event |-> "Execute", args |-> [e |-> 2]],
    [event |-> "ProcessTransferTaskEligible", args |-> [e |-> 2]],
    [event |-> "MatchingSpoolCommit", args |-> [e |-> 2]],
    [event |-> "MatchingReply", args |-> [e |-> 2]],
    [event |-> "HandleErrAck", args |-> [e |-> 2]],
    [event |-> "Ack", args |-> [e |-> 2]],
    [event |-> "CheckpointBegin", args |-> [o |-> 1]],
    [event |-> "ShrinkSlices", args |-> [o |-> 1, r |-> 0]],
    [event |-> "ShrinkSlices", args |-> [o |-> 1, r |-> 1]],
    [event |-> "MoveGroupCollect", args |-> [o |-> 1]],
    [event |-> "CheckpointScopes", args |-> [o |-> 1, r |-> 0]],
    [event |-> "CheckpointScopes", args |-> [o |-> 1, r |-> 1]],
    [event |-> "RangeCompleteTasksBegin", args |-> [o |-> 1]],
    [event |-> "RangeCompleteTasksCommit", args |-> [o |-> 1]],
    [event |-> "RangeCompleteTasksReply", args |-> [o |-> 1]],
    [event |-> "SetQueueStateSnapshot", args |-> [o |-> 1, j |-> 1]],
    [event |-> "UpdateShardCommit", args |-> [j |-> 1]],
    [event |-> "UpdateShardReply", args |-> [j |-> 1]],
    [event |-> "SelectTasks", args |-> [o |-> 1, r |-> 1, es |-> <<>>]],
    [event |-> "NotifyReader", args |-> [o |-> 1, r |-> 1]],
    [event |-> "AcquireShardBegin", args |-> [o |-> 2]],
    [event |-> "RenewRangeLockedCommit", args |-> [o |-> 2]],
    [event |-> "AcquireShardComplete", args |-> [o |-> 2]],
    [event |-> "SelectTasks", args |-> [o |-> 2, r |-> 1, es |-> <<3>>]],
    [event |-> "Execute", args |-> [e |-> 3]],
    [event |-> "ProcessTransferTaskEligible", args |-> [e |-> 3]],
    [event |-> "MatchingSpoolCommit", args |-> [e |-> 3]],
    [event |-> "MatchingReply", args |-> [e |-> 3]],
    [event |-> "HandleErrAck", args |-> [e |-> 3]],
    [event |-> "Ack", args |-> [e |-> 3]]
  >>
  []   FixtureKind = "publication" -> <<
    [event |-> "SetAndTrackTaskKeys", args |-> [o |-> 1, t |-> 1, g |-> "g1", k |-> "Workflow"]],
    [event |-> "AppendHistoryNodes", args |-> [t |-> 1]],
    [event |-> "SetAndTrackTaskKeys", args |-> [o |-> 1, t |-> 2, g |-> "g2", k |-> "Activity"]],
    [event |-> "AppendHistoryNodes", args |-> [t |-> 2]],
    [event |-> "UpdateWorkflowExecutionCommit", args |-> [t |-> 1]],
    [event |-> "TaskRequestTimeout", args |-> [t |-> 1]],
    [event |-> "TaskRequestTimeout", args |-> [t |-> 2]],
    [event |-> "CheckpointBegin", args |-> [o |-> 1]],
    [event |-> "AcquireShardBegin", args |-> [o |-> 1]],
    [event |-> "RenewRangeLockedCommit", args |-> [o |-> 1]],
    [event |-> "AcquireShardComplete", args |-> [o |-> 1]],
    [event |-> "UpdateWorkflowExecutionFenced", args |-> [t |-> 2]],
    [event |-> "ShrinkSlices", args |-> [o |-> 1, r |-> 0]],
    [event |-> "ShrinkSlices", args |-> [o |-> 1, r |-> 1]],
    [event |-> "MoveGroupCollect", args |-> [o |-> 1]],
    [event |-> "CheckpointScopes", args |-> [o |-> 1, r |-> 0]],
    [event |-> "CheckpointScopes", args |-> [o |-> 1, r |-> 1]],
    [event |-> "RangeCompleteTasksBegin", args |-> [o |-> 1]],
    [event |-> "RangeCompleteTasksCommit", args |-> [o |-> 1]],
    [event |-> "RangeCompleteTasksReply", args |-> [o |-> 1]],
    [event |-> "SetQueueStateSnapshot", args |-> [o |-> 1, j |-> 1]],
    [event |-> "UpdateShardCommit", args |-> [j |-> 1]],
    [event |-> "UpdateShardReply", args |-> [j |-> 1]],
    [event |-> "ProcessNewRange", args |-> [o |-> 1, id |-> 1]],
    [event |-> "SelectTasks", args |-> [o |-> 1, r |-> 0, es |-> <<1>>]],
    [event |-> "Execute", args |-> [e |-> 1]],
    [event |-> "ProcessTransferTaskEligible", args |-> [e |-> 1]],
    [event |-> "MatchingSpoolCommit", args |-> [e |-> 1]],
    [event |-> "MatchingReply", args |-> [e |-> 1]],
    [event |-> "HandleErrAck", args |-> [e |-> 1]],
    [event |-> "Ack", args |-> [e |-> 1]]
  >>
  []   FixtureKind = "checkpoint" -> <<
    [event |-> "SetAndTrackTaskKeys", args |-> [o |-> 1, t |-> 1, g |-> "g1", k |-> "Workflow"]],
    [event |-> "AppendHistoryNodes", args |-> [t |-> 1]],
    [event |-> "UpdateWorkflowExecutionCommit", args |-> [t |-> 1]],
    [event |-> "TaskRequestCompletion", args |-> [t |-> 1]],
    [event |-> "SetAndTrackTaskKeys", args |-> [o |-> 1, t |-> 2, g |-> "g2", k |-> "Activity"]],
    [event |-> "AppendHistoryNodes", args |-> [t |-> 2]],
    [event |-> "UpdateWorkflowExecutionCommit", args |-> [t |-> 2]],
    [event |-> "TaskRequestCompletion", args |-> [t |-> 2]],
    [event |-> "ProcessNewRange", args |-> [o |-> 1, id |-> 1]],
    [event |-> "SelectTasks", args |-> [o |-> 1, r |-> 0, es |-> <<1>>]],
    [event |-> "Execute", args |-> [e |-> 1]],
    [event |-> "ProcessTransferTaskEligible", args |-> [e |-> 1]],
    [event |-> "MatchingSpoolCommit", args |-> [e |-> 1]],
    [event |-> "MatchingReply", args |-> [e |-> 1]],
    [event |-> "HandleErrAck", args |-> [e |-> 1]],
    [event |-> "Ack", args |-> [e |-> 1]],
    [event |-> "UpdateShardInfoSnapshot", args |-> [o |-> 1, j |-> 1]],
    [event |-> "CheckpointBegin", args |-> [o |-> 1]],
    [event |-> "ShrinkSlices", args |-> [o |-> 1, r |-> 0]],
    [event |-> "ShrinkSlices", args |-> [o |-> 1, r |-> 1]],
    [event |-> "MoveGroupCollect", args |-> [o |-> 1]],
    [event |-> "CheckpointScopes", args |-> [o |-> 1, r |-> 0]],
    [event |-> "CheckpointScopes", args |-> [o |-> 1, r |-> 1]],
    [event |-> "RangeCompleteTasksBegin", args |-> [o |-> 1]],
    [event |-> "RangeCompleteTasksCommit", args |-> [o |-> 1]],
    [event |-> "RangeCompleteTasksLostReply", args |-> [o |-> 1]],
    [event |-> "CheckpointBegin", args |-> [o |-> 1]],
    [event |-> "ShrinkSlices", args |-> [o |-> 1, r |-> 0]],
    [event |-> "ShrinkSlices", args |-> [o |-> 1, r |-> 1]],
    [event |-> "MoveGroupCollect", args |-> [o |-> 1]],
    [event |-> "CheckpointScopes", args |-> [o |-> 1, r |-> 0]],
    [event |-> "CheckpointScopes", args |-> [o |-> 1, r |-> 1]],
    [event |-> "RangeCompleteTasksBegin", args |-> [o |-> 1]],
    [event |-> "RangeCompleteTasksCommit", args |-> [o |-> 1]],
    [event |-> "RangeCompleteTasksReply", args |-> [o |-> 1]],
    [event |-> "SetQueueStateSnapshot", args |-> [o |-> 1, j |-> 2]],
    [event |-> "UpdateShardCommit", args |-> [j |-> 2]],
    [event |-> "UpdateShardLostReply", args |-> [j |-> 2]],
    [event |-> "UpdateShardCommit", args |-> [j |-> 1]],
    [event |-> "UpdateShardReply", args |-> [j |-> 1]],
    [event |-> "AcquireShardBegin", args |-> [o |-> 2]],
    [event |-> "RenewRangeLockedCommit", args |-> [o |-> 2]],
    [event |-> "AcquireShardComplete", args |-> [o |-> 2]],
    [event |-> "ProcessNewRange", args |-> [o |-> 2, id |-> 1]],
    [event |-> "SelectTasks", args |-> [o |-> 2, r |-> 0, es |-> <<1>>]],
    [event |-> "Execute", args |-> [e |-> 1]],
    [event |-> "ProcessTransferTaskEligible", args |-> [e |-> 1]],
    [event |-> "MatchingSpoolCommit", args |-> [e |-> 1]],
    [event |-> "MatchingReply", args |-> [e |-> 1]],
    [event |-> "HandleErrAck", args |-> [e |-> 1]],
    [event |-> "Ack", args |-> [e |-> 1]],
    [event |-> "SelectTasks", args |-> [o |-> 2, r |-> 0, es |-> <<>>]],
    [event |-> "CheckpointBegin", args |-> [o |-> 2]],
    [event |-> "ShrinkSlices", args |-> [o |-> 2, r |-> 0]],
    [event |-> "ShrinkSlices", args |-> [o |-> 2, r |-> 1]],
    [event |-> "MoveGroupCollect", args |-> [o |-> 2]],
    [event |-> "CheckpointScopes", args |-> [o |-> 2, r |-> 0]],
    [event |-> "CheckpointScopes", args |-> [o |-> 2, r |-> 1]],
    [event |-> "RangeCompleteTasksBegin", args |-> [o |-> 2]],
    [event |-> "RangeCompleteTasksCommit", args |-> [o |-> 2]],
    [event |-> "RangeCompleteTasksReply", args |-> [o |-> 2]],
    [event |-> "SetQueueStateSnapshot", args |-> [o |-> 2, j |-> 1]],
    [event |-> "UpdateShardCommit", args |-> [j |-> 1]],
    [event |-> "UpdateShardReply", args |-> [j |-> 1]]
  >>
  []   FixtureKind = "late_dlq" -> <<
    [event |-> "SetAndTrackTaskKeys", args |-> [o |-> 1, t |-> 1, g |-> "g1", k |-> "Workflow"]],
    [event |-> "AppendHistoryNodes", args |-> [t |-> 1]],
    [event |-> "UpdateWorkflowExecutionCommit", args |-> [t |-> 1]],
    [event |-> "TaskRequestCompletion", args |-> [t |-> 1]],
    [event |-> "ProcessNewRange", args |-> [o |-> 1, id |-> 1]],
    [event |-> "SelectTasks", args |-> [o |-> 1, r |-> 0, es |-> <<1>>]],
    [event |-> "Execute", args |-> [e |-> 1]],
    [event |-> "ExecuteTerminalError", args |-> [e |-> 1]],
    [event |-> "HandleErrTerminal", args |-> [e |-> 1]],
    [event |-> "Nack", args |-> [e |-> 1]],
    [event |-> "Reschedule", args |-> [e |-> 1]],
    [event |-> "Execute", args |-> [e |-> 1]],
    [event |-> "UpdateShardInfoSnapshot", args |-> [o |-> 1, j |-> 1]],
    [event |-> "AcquireShardBegin", args |-> [o |-> 2]],
    [event |-> "RenewRangeLockedCommit", args |-> [o |-> 2]],
    [event |-> "AcquireShardComplete", args |-> [o |-> 2]],
    [event |-> "EnqueueTaskCommit", args |-> [e |-> 1]],
    [event |-> "ClearSlicesBegin", args |-> [o |-> 1, r |-> 0, id |-> 1]],
    [event |-> "ClearCancel", args |-> [o |-> 1, e |-> 1]],
    [event |-> "ClearSlicesComplete", args |-> [o |-> 1]],
    [event |-> "StopReaderGroup", args |-> [o |-> 1]],
    [event |-> "UpdateShardFenced", args |-> [j |-> 1]],
    [event |-> "UpdateShardReply", args |-> [j |-> 1]],
    [event |-> "EnqueueTaskLostReply", args |-> [e |-> 1]],
    [event |-> "HandleErrRetry", args |-> [e |-> 1]],
    [event |-> "Nack", args |-> [e |-> 1]],
    [event |-> "ProcessNewRange", args |-> [o |-> 2, id |-> 1]],
    [event |-> "SelectTasks", args |-> [o |-> 2, r |-> 0, es |-> <<2>>]],
    [event |-> "Execute", args |-> [e |-> 2]],
    [event |-> "ProcessTransferTaskEligible", args |-> [e |-> 2]],
    [event |-> "MatchingSpoolCommit", args |-> [e |-> 2]],
    [event |-> "MatchingLostReply", args |-> [e |-> 2]],
    [event |-> "HandleErrUnexpected", args |-> [e |-> 2]],
    [event |-> "Nack", args |-> [e |-> 2]],
    [event |-> "Reschedule", args |-> [e |-> 2]],
    [event |-> "Execute", args |-> [e |-> 2]],
    [event |-> "ProcessTransferTaskEligible", args |-> [e |-> 2]],
    [event |-> "MatchingSpoolCommit", args |-> [e |-> 2]],
    [event |-> "MatchingReply", args |-> [e |-> 2]],
    [event |-> "HandleErrAck", args |-> [e |-> 2]],
    [event |-> "Ack", args |-> [e |-> 2]],
    [event |-> "SelectTasks", args |-> [o |-> 2, r |-> 0, es |-> <<>>]],
    [event |-> "CheckpointBegin", args |-> [o |-> 2]],
    [event |-> "ShrinkSlices", args |-> [o |-> 2, r |-> 0]],
    [event |-> "ShrinkSlices", args |-> [o |-> 2, r |-> 1]],
    [event |-> "MoveGroupCollect", args |-> [o |-> 2]],
    [event |-> "CheckpointScopes", args |-> [o |-> 2, r |-> 0]],
    [event |-> "CheckpointScopes", args |-> [o |-> 2, r |-> 1]],
    [event |-> "RangeCompleteTasksBegin", args |-> [o |-> 2]],
    [event |-> "RangeCompleteTasksCommit", args |-> [o |-> 2]],
    [event |-> "RangeCompleteTasksReply", args |-> [o |-> 2]],
    [event |-> "SetQueueStateSnapshot", args |-> [o |-> 2, j |-> 1]],
    [event |-> "UpdateShardCommit", args |-> [j |-> 1]],
    [event |-> "UpdateShardReply", args |-> [j |-> 1]]
  >>

Record(ev,st,n) == [tag |-> "trace", schema |-> 1,
 provenance |-> "synthetic-spec-test", seq |-> n, event |-> ev.event,
 args |-> ev.args, post |-> EncodeState(st)]
WitnessInit == /\ Init /\ pc = 1 /\ done = FALSE /\ l = 0
 /\ events = <<(Record([event |-> "Init",args |-> [dummy |-> 0]],s,1) @@
   [revision |-> "0c010ce5fe8c0180aa7573c72fe8fc87c6df7025",
    backend |-> "sqlite-wal", constants |-> ConstantsSnapshot])>>
Dispatch(ev) ==
  /\ ev.event = "SetAndTrackTaskKeys"
     /\ SetAndTrackTaskKeys(ev.args.o,ev.args.t,ev.args.g,ev.args.k)
  \/ /\ ev.event = "AppendHistoryNodes"
     /\ AppendHistoryNodes(ev.args.t)
  \/ /\ ev.event = "UpdateWorkflowExecutionCommit"
     /\ UpdateWorkflowExecutionCommit(ev.args.t)
  \/ /\ ev.event = "UpdateWorkflowExecutionFenced"
     /\ UpdateWorkflowExecutionFenced(ev.args.t)
  \/ /\ ev.event = "UpdateWorkflowExecutionFail"
     /\ UpdateWorkflowExecutionFail(ev.args.t)
  \/ /\ ev.event = "TaskRequestCompletion"
     /\ TaskRequestCompletion(ev.args.t)
  \/ /\ ev.event = "TaskRequestTimeout"
     /\ TaskRequestTimeout(ev.args.t)
  \/ /\ ev.event = "DropNotification"
     /\ DropNotification(ev.args.o)
  \/ /\ ev.event = "AcquireShardBegin"
     /\ AcquireShardBegin(ev.args.o)
  \/ /\ ev.event = "RenewRangeLockedCommit"
     /\ RenewRangeLockedCommit(ev.args.o)
  \/ /\ ev.event = "RenewRangeLockedFenced"
     /\ RenewRangeLockedFenced(ev.args.o)
  \/ /\ ev.event = "AcquireShardComplete"
     /\ AcquireShardComplete(ev.args.o)
  \/ /\ ev.event = "StopReaderGroup"
     /\ StopReaderGroup(ev.args.o)
  \/ /\ ev.event = "ProcessNewRange"
     /\ ProcessNewRange(ev.args.o,ev.args.id)
  \/ /\ ev.event = "SelectTasks"
     /\ SelectTasks(ev.args.o,ev.args.r,ev.args.es)
  \/ /\ ev.event = "NotifyReader"
     /\ NotifyReader(ev.args.o,ev.args.r)
  \/ /\ ev.event = "CheckpointBegin"
     /\ CheckpointBegin(ev.args.o)
  \/ /\ ev.event = "ShrinkSlices"
     /\ ShrinkSlices(ev.args.o,ev.args.r)
  \/ /\ ev.event = "MoveGroupCollect"
     /\ MoveGroupCollect(ev.args.o)
  \/ /\ ev.event = "MoveGroupSplit"
     /\ MoveGroupSplit(ev.args.o)
  \/ /\ ev.event = "MoveGroupMerge"
     /\ MoveGroupMerge(ev.args.o)
  \/ /\ ev.event = "CheckpointScopes"
     /\ CheckpointScopes(ev.args.o,ev.args.r)
  \/ /\ ev.event = "RangeCompleteTasksBegin"
     /\ RangeCompleteTasksBegin(ev.args.o)
  \/ /\ ev.event = "RangeCompleteTasksCommit"
     /\ RangeCompleteTasksCommit(ev.args.o)
  \/ /\ ev.event = "RangeCompleteTasksFail"
     /\ RangeCompleteTasksFail(ev.args.o)
  \/ /\ ev.event = "RangeCompleteTasksReply"
     /\ RangeCompleteTasksReply(ev.args.o)
  \/ /\ ev.event = "RangeCompleteTasksLostReply"
     /\ RangeCompleteTasksLostReply(ev.args.o)
  \/ /\ ev.event = "SetQueueStateBatched"
     /\ SetQueueStateBatched(ev.args.o)
  \/ /\ ev.event = "SetQueueStateSnapshot"
     /\ SetQueueStateSnapshot(ev.args.o,ev.args.j)
  \/ /\ ev.event = "SetQueueStateClosed"
     /\ SetQueueStateClosed(ev.args.o)
  \/ /\ ev.event = "UpdateShardInfoSnapshot"
     /\ UpdateShardInfoSnapshot(ev.args.o,ev.args.j)
  \/ /\ ev.event = "UpdateShardCommit"
     /\ UpdateShardCommit(ev.args.j)
  \/ /\ ev.event = "UpdateShardFenced"
     /\ UpdateShardFenced(ev.args.j)
  \/ /\ ev.event = "UpdateShardFail"
     /\ UpdateShardFail(ev.args.j)
  \/ /\ ev.event = "UpdateShardReply"
     /\ UpdateShardReply(ev.args.j)
  \/ /\ ev.event = "UpdateShardLostReply"
     /\ UpdateShardLostReply(ev.args.j)
  \/ /\ ev.event = "ProcessNewRangeMerge"
     /\ ProcessNewRangeMerge(ev.args.o)
  \/ /\ ev.event = "SplitSlicesByRange"
     /\ SplitSlicesByRange(ev.args.o,ev.args.r,ev.args.id,ev.args.cut,ev.args.fresh)
  \/ /\ ev.event = "CompactSlices"
     /\ CompactSlices(ev.args.o,ev.args.r,ev.args.i)
  \/ /\ ev.event = "ClearSlicesBegin"
     /\ ClearSlicesBegin(ev.args.o,ev.args.r,ev.args.id)
  \/ /\ ev.event = "ClearCancel"
     /\ ClearCancel(ev.args.o,ev.args.e)
  \/ /\ ev.event = "ClearSlicesComplete"
     /\ ClearSlicesComplete(ev.args.o)
  \/ /\ ev.event = "Execute"
     /\ Execute(ev.args.e)
  \/ /\ ev.event = "ProcessTransferTaskEligible"
     /\ ProcessTransferTaskEligible(ev.args.e)
  \/ /\ ev.event = "ProcessTransferTaskObsolete"
     /\ ProcessTransferTaskObsolete(ev.args.e)
  \/ /\ ev.event = "ExecuteRetryableError"
     /\ ExecuteRetryableError(ev.args.e)
  \/ /\ ev.event = "ExecuteUnexpectedError"
     /\ ExecuteUnexpectedError(ev.args.e)
  \/ /\ ev.event = "ExecuteTerminalError"
     /\ ExecuteTerminalError(ev.args.e)
  \/ /\ ev.event = "MatchingSpoolCommit"
     /\ MatchingSpoolCommit(ev.args.e)
  \/ /\ ev.event = "RecordTaskStarted"
     /\ RecordTaskStarted(ev.args.e)
  \/ /\ ev.event = "MatchingTerminalDiscard"
     /\ MatchingTerminalDiscard(ev.args.e)
  \/ /\ ev.event = "MatchingReply"
     /\ MatchingReply(ev.args.e)
  \/ /\ ev.event = "MatchingLostReply"
     /\ MatchingLostReply(ev.args.e)
  \/ /\ ev.event = "EnqueueTaskCommit"
     /\ EnqueueTaskCommit(ev.args.e)
  \/ /\ ev.event = "EnqueueTaskReply"
     /\ EnqueueTaskReply(ev.args.e)
  \/ /\ ev.event = "EnqueueTaskLostReply"
     /\ EnqueueTaskLostReply(ev.args.e)
  \/ /\ ev.event = "HandleErrAck"
     /\ HandleErrAck(ev.args.e)
  \/ /\ ev.event = "HandleErrRetry"
     /\ HandleErrRetry(ev.args.e)
  \/ /\ ev.event = "HandleErrTerminal"
     /\ HandleErrTerminal(ev.args.e)
  \/ /\ ev.event = "HandleErrUnexpected"
     /\ HandleErrUnexpected(ev.args.e)
  \/ /\ ev.event = "Ack"
     /\ Ack(ev.args.e)
  \/ /\ ev.event = "Nack"
     /\ Nack(ev.args.e)
  \/ /\ ev.event = "Reschedule"
     /\ Reschedule(ev.args.e)
  \/ /\ ev.event = "WorkflowNoLongerNeedsTask"
     /\ WorkflowNoLongerNeedsTask(ev.args.t)
  \/ /\ ev.event = "WorkerComplete"
     /\ WorkerComplete(ev.args.t)

WitnessStep ==
  /\ pc <= Len(Steps) /\ Dispatch(Steps[pc])
  /\ events' = Append(events,Record(Steps[pc],s',pc+1))
  /\ pc' = pc+1 /\ UNCHANGED <<done,l>>
WitnessFinish ==
  /\ pc > Len(Steps) /\ ~done
  /\ LET rb == [DurableProjection(s) EXCEPT !.queue = EncodeQS(@)]
         endpoint == Record([event |-> "Endpoint",args |-> [dummy |-> 0]],s,pc+1) @@
           [complete |-> TRUE, independent_readback |-> TRUE, readback |-> rb]
     IN ndJsonSerialize("output/fixture-" \o FixtureKind \o ".ndjson",Append(events,endpoint))
  /\ done' = TRUE /\ UNCHANGED <<s,pc,events,l>>
WitnessNext == WitnessStep \/ WitnessFinish
WitnessSpec == WitnessInit /\ [][WitnessNext]_wvars /\ WF_wvars(WitnessNext)
WitnessComplete == <>done
WitnessOutcome == done => CASE
  FixtureKind = "cursor" -> /\ ~LiveCursorSoundness
    /\ s.q[1].cursor[1] = 0 /\ 3 \in s.db.rows
    /\ 3 \notin s.db.matching /\ ScopeCovered(s.db.queue,3)
  [] FixtureKind = "healthy" -> /\ LiveCursorSoundness /\ 3 \in s.db.matching
  [] FixtureKind = "recovery" -> /\ s.db.range = 2 /\ 3 \in s.db.matching
  [] FixtureKind = "publication" -> /\ 1 \in s.db.matching /\ 2 \notin s.db.rows
  [] FixtureKind = "checkpoint" -> /\ s.db.rows = {} /\ s.db.range = 2
  [] FixtureKind = "late_dlq" -> /\ 1 \in s.db.dlq /\ 1 \in s.db.matching /\ s.db.rows = {}
=============================================================================
