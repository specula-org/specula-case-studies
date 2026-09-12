------------------------------ MODULE Trace ------------------------------
EXTENDS base, Json, IOUtils
B == INSTANCE base
CONSTANT EvidenceClass
VARIABLE l
tracevars == <<vars, l>>

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON
    ELSE "../traces/trace.ndjson"
TransportLog == ndJsonDeserialize(JsonFile)
RawLog == [i \in 1..Len(TransportLog) |->
    LET e == TransportLog[i] IN
    IF DOMAIN e = {"tag", "ts", "record"} /\ e.tag = "trace" /\ e.ts \in STRING
    THEN e.record
    ELSE Assert(FALSE, "Invalid timestamped trace transport envelope")]
TaggedLog == SelectSeq(RawLog, LAMBDA e :
    IF "tag" \in DOMAIN e THEN e.tag = "temporal-matching" ELSE FALSE)
Header == TaggedLog[1]
TraceLog == Tail(TaggedLog)
AsSet(s) == {s[i] : i \in 1..Len(s)}
Unique(s) == Cardinality(AsSet(s)) = Len(s)
TraceOwners == AsSet(Header.config.owners)
TraceWork == AsSet(Header.config.work)
TraceCallIds == AsSet(Header.config.callIds)
TracePollers == AsSet(Header.config.pollers)
TraceStartIds == AsSet(Header.config.startIds)
TraceInitialOwner == Header.config.initialOwner
TraceRangeSize == Header.config.rangeSize
TraceBatchSize == Header.config.batchSize
TraceReloadAt == Header.config.reloadAt
TraceDeleteBatchSize == Header.config.deleteBatchSize

\* Numeric actor IDs are dense; storage IDs are actual, possibly gapped IDs.
\* Work strings encode the COMPLETE namespace/workflow/run/type/event/stamp key.
AllKeys == {"durable", "catalog", "owner", "writer", "reader", "metadata", "dispatch", "calls", "history"}
DecodeOwner(x) == [x EXCEPT !.outstanding = AsSet(@), !.done = AsSet(@),
                                  !.adding = AsSet(@), !.queued = AsSet(@)]
DecodeReader(x) == [x EXCEPT !.rows = AsSet(@), !.todo = AsSet(@)]
DecodeCatalog(s) ==
    [r \in {s[i].id : i \in 1..Len(s)} |->
        LET row == CHOOSE x \in AsSet(s) : x.id = r
        IN [work |-> row.work, parent |-> row.parent]]
DecodeGroup(post,k) ==
    CASE k = "durable" -> [post[k] EXCEPT !.rows = AsSet(@)]
      [] k = "catalog" -> DecodeCatalog(post[k])
      [] k = "owner" -> [o \in Owners |-> DecodeOwner(post[k][o])]
      [] k = "reader" -> [o \in Owners |-> DecodeReader(post[k][o])]
      [] OTHER -> post[k]
ModelGroup(k) ==
    CASE k = "durable" -> durable [] k = "catalog" -> catalog
      [] k = "owner" -> owner [] k = "writer" -> writer
      [] k = "reader" -> reader [] k = "metadata" -> metadata
      [] k = "dispatch" -> dispatch [] k = "calls" -> calls
      [] k = "history" -> history
EncodingOK(post,k) ==
    CASE k = "durable" -> Unique(post[k].rows)
      [] k = "catalog" ->
          /\ Cardinality({post[k][i].id : i \in 1..Len(post[k])}) = Len(post[k])
          /\ \A x \in AsSet(post[k]) : DOMAIN x = {"id", "work", "parent"}
      [] k = "owner" ->
          /\ Len(post[k]) = Cardinality(Owners)
          /\ \A x \in AsSet(post[k]) : Unique(x.outstanding) /\ Unique(x.done)
                                      /\ Unique(x.adding) /\ Unique(x.queued)
      [] k = "reader" ->
          /\ Len(post[k]) = Cardinality(Owners)
          /\ \A x \in AsSet(post[k]) : Unique(x.rows) /\ Unique(x.todo)
      [] k \in {"writer", "metadata"} -> Len(post[k]) = Cardinality(Owners)
      [] k = "dispatch" -> Len(post[k]) = Cardinality(Pollers)
      [] k = "calls" -> Len(post[k]) = Cardinality(CallIds)
      [] OTHER -> TRUE

PostKeys(event) ==
    CASE event = "RenewLeaseFailure" -> {"writer"}
      [] event = "RenewLeaseRetry" -> {"writer"}
      [] event = "SyncTaskReceive" -> {"calls"}
      [] event = "SignalIfFatal" -> {"owner"}
      [] event = "TraceEnd" -> AllKeys
      [] event = "AddTask" -> {"calls"}
      [] event = "TrySyncMatchFallback" -> {"calls"}
      [] event = "TrySyncMatch" -> {"dispatch", "calls"}
      [] event = "SpoolTask" -> {"owner", "calls"}
      [] event = "TaskWriterDequeue" -> {"owner", "writer"}
      [] event = "AssignTaskIDs" -> {"catalog", "owner", "writer"}
      [] event = "CreateTasksBegin" -> {"writer"}
      [] event = "CreateTasksCommit" -> {"durable", "writer"}
      [] event = "CreateTasksConditionFailed" -> {"writer"}
      [] event = "CreateTasksReject" -> {"writer"}
      [] event = "CreateTasksReturn" -> {"owner", "writer"}
      [] event = "CreateTasksUncertainReturn" -> {"owner", "writer"}
      [] event = "SignalNewTasksBypass" -> {"owner", "writer"}
      [] event = "SignalNewTasksWake" -> {"owner", "writer"}
      [] event = "AddTaskToMatcher" -> {"owner"}
      [] event = "AddTaskToMatcherClosed" -> {"owner"}
      [] event = "SignalReadersDone" -> {"writer"}
      [] event = "TaskWriterPublish" -> {"writer", "calls"}
      [] event = "AppendTaskReceive" -> {"calls"}
      [] event = "AppendTaskShutdown" -> {"calls"}
      [] event = "AddTaskReply" -> {"calls"}
      [] event = "AddTaskReplyLost" -> {"calls"}
      [] event = "GetTasksPump" -> {"owner", "reader"}
      [] event = "GetTaskBatchMax" -> {"reader"}
      [] event = "GetTasksIssue" -> {"reader"}
      [] event = "GetTasksSnapshot" -> {"reader"}
      [] event = "GetTasksError" -> {"owner", "reader"}
      [] event = "BackoffSignal" -> {"owner", "reader"}
      [] event = "GetTaskBatchReturn" -> {"reader"}
      [] event = "ProcessTaskBatch" -> {"owner", "reader"}
      [] event = "ProcessTaskBatchDone" -> {"owner", "reader"}
      [] event = "SetReadLevelAfterGapStale" -> {"owner", "reader"}
      [] event = "SetReadLevelAfterGap" -> {"owner", "reader"}
      [] event = "SetReadLevelAfterGapAck" -> {"owner", "reader"}
      [] event = "UpdateAckLevelAfterGap" -> {"owner", "reader"}
      [] event = "PollTask" -> {"owner", "dispatch"}
      [] event = "RecordTaskStartedBegin" -> {"dispatch"}
      [] event = "RecordTaskStartedPrecheckError" -> {"dispatch"}
      [] event = "RecordTaskStarted" -> {"dispatch", "history"}
      [] event = "RecordTaskStartedError" -> {"dispatch"}
      [] event = "RecordTaskStartedReply" -> {"dispatch"}
      [] event = "RecordTaskStartedRetryRPC" -> {"dispatch"}
      [] event = "RecordTaskStartedReplyLost" -> {"dispatch"}
      [] event = "FinishSyncTask" -> {"dispatch", "calls"}
      [] event = "CompleteTaskTransient" -> {"owner", "dispatch"}
      [] event = "RespoolTaskAfterError" -> {"owner", "dispatch"}
      [] event = "TaskWriterPublishReplacement" -> {"writer", "dispatch"}
      [] event = "RespoolTaskReturn" -> {"owner", "dispatch"}
      [] event = "RespoolTaskRetry" -> {"owner", "dispatch"}
      [] event = "RespoolTaskShutdown" -> {"owner", "dispatch"}
      [] event = "CompleteTaskAck" -> {"owner", "dispatch"}
      [] event = "AckTaskLockedDrained" -> {"owner"}
      [] event = "MaybeGCLocked" -> {"owner"}
      [] event = "UpdateAckLevelAndBacklogStats" -> {"owner", "dispatch"}
      [] event = "PollTaskQueueResponse" -> {"dispatch", "history"}
      [] event = "PollTaskQueueResponseLost" -> {"dispatch"}
      [] event = "ExpireTask" -> {"history"}
      [] event = "ObsoleteTask" -> {"history"}
      [] event = "FinishExpiredTask" -> {"owner", "dispatch"}
      [] event = "SyncStateBegin" -> {"metadata"}
      [] event = "RenewLeaseBegin" -> {"metadata"}
      [] event = "TakeOverTaskQueueBegin" -> {"owner", "metadata"}
      [] event = "TakeOverTaskQueueSnapshot" -> {"metadata"}
      [] event = "UpdateTaskQueueCommit" -> {"durable", "metadata"}
      [] event = "VerifyOwnership" -> {"metadata"}
      [] event = "UpdateTaskQueueConditionFailed" -> {"metadata"}
      [] event = "UpdateTaskQueueError" -> {"metadata"}
      [] event = "UpdateTaskQueueReplyLost" -> {"metadata"}
      [] event = "UpdateTaskQueueReturn" -> {"owner", "metadata", "writer"}
      [] event = "StopBegin" -> {"owner"}
      [] event = "UnloadAfterError" -> {"owner"}
      [] event = "StopRefreshAck" -> {"owner"}
      [] event = "StopSyncState" -> {"owner", "metadata"}
      [] event = "StopCancel" -> {"owner"}
      [] event = "Crash" -> {"owner"}
      [] event = "CompleteTasksLessThan" -> {"durable", "owner"}
      [] event = "DoGCReturn" -> {"owner"}
      [] event = "DoGCError" -> {"owner"}
      [] event = "DiscardCrashedWriter" -> {"writer"}
      [] event = "PollerDisconnect" -> {"dispatch"}
      [] event = "PollTaskErrorReturn" -> {"dispatch"}

\* Decode actual TaskInfo from independently observed SQL/read/delete rows.
ObservedTasks(ts,ids) ==
    /\ Cardinality({ts[i].id : i \in 1..Len(ts)}) = Len(ts)
    /\ {ts[i].id : i \in 1..Len(ts)} = ids
    /\ \A row \in AsSet(ts) :
         /\ DOMAIN row = {"id", "work"}
         /\ row.id \in DOMAIN catalog /\ row.work = catalog[row.id].work

\* No optional field checks. Missing, extra or inconsistent captured state fails.
ValidatePostState(e) ==
    /\ DOMAIN e.post = PostKeys(e.event)
    /\ \A k \in DOMAIN e.post : EncodingOK(e.post,k)
    /\ \A k \in DOMAIN e.post : DecodeGroup(e.post,k) = ModelGroup(k)'
ValidateInitialState ==
    /\ DOMAIN Header.post = AllKeys
    /\ \A k \in AllKeys : EncodingOK(Header.post,k)
    /\ \A k \in AllKeys : DecodeGroup(Header.post,k) = ModelGroup(k)
Envelope(e,event,node,args) ==
    /\ DOMAIN e = {"tag", "seq", "event", "node", "queue", "args", "post"}
    /\ e.tag = "temporal-matching" /\ e.seq = l /\ e.event = event
    /\ e.node = node /\ e.queue = Header.queue /\ DOMAIN e.args = args

TraceSyncTaskReceive(e) ==
    /\ Envelope(e, "SyncTaskReceive", calls[e.args.a].owner, {"a"})
    /\ Track(B!SyncTaskReceive(e.args.a))
    /\ ValidatePostState(e)
    /\ l' = l + 1

TraceRenewLeaseRetry(e) ==
    /\ Envelope(e, "RenewLeaseRetry", e.args.o, {"o"})
    /\ Track(B!RenewLeaseRetry(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

TraceRenewLeaseFailure(e) ==
    /\ Envelope(e, "RenewLeaseFailure", e.args.o, {"o"})
    /\ Track(B!RenewLeaseFailure(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

TraceSignalIfFatal(e) ==
    /\ Envelope(e, "SignalIfFatal", e.args.o, {"o"})
    /\ Track(B!SignalIfFatal(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

TraceHeaderOK ==
    /\ DOMAIN Header = {"tag", "seq", "event", "source", "revision", "queue", "config", "post"}
    /\ Header.event = "bootstrap" /\ Header.seq = 0
    /\ DOMAIN Header.queue = {"namespace", "physicalName", "partition", "subqueue", "taskType"}
    /\ Header.queue.namespace \in STRING /\ Header.queue.physicalName \in STRING
    /\ Header.queue.partition = 0 /\ Header.queue.subqueue = 0
    /\ Header.queue.taskType \in {"workflow", "activity"}
    /\ DOMAIN Header.config = {"backend", "useNewMatcher", "enableFairness", "priority", "writeBatchSize",
          "owners", "work", "callIds", "pollers", "startIds", "initialOwner", "rangeSize", "batchSize", "reloadAt", "deleteBatchSize"}
    /\ \A w \in Work : w \in STRING
    /\ Header.source = EvidenceClass
    /\ Header.revision = "0c010ce5fe8c0180aa7573c72fe8fc87c6df7025"
    /\ Header.config.backend = "sqlite-v1"
    /\ Header.config.useNewMatcher /\ ~Header.config.enableFairness
    /\ Header.config.priority = 3 /\ Header.config.writeBatchSize = 1
    /\ Owners = 1..Cardinality(Owners) /\ CallIds = 1..Cardinality(CallIds)
    /\ Pollers = 1..Cardinality(Pollers)
    /\ Unique(Header.config.owners) /\ Unique(Header.config.work)
    /\ Unique(Header.config.callIds) /\ Unique(Header.config.pollers)
    /\ Unique(Header.config.startIds)
    /\ TraceLog[Len(TraceLog)].event = "TraceEnd"

TraceInit ==
    /\ Assert(Len(TaggedLog) >= 3, "Need bootstrap, at least one action and TraceEnd")
    /\ Assert(TraceHeaderOK, "Invalid trace bootstrap provenance or configuration")
    /\ Init
    /\ Assert(ValidateInitialState, "Trace bootstrap does not match implementation Init")
    /\ l = 1

\* service/matching/task_queue_partition_manager.go:612-619
TraceAddTask(e) ==
    /\ Envelope(e, "AddTask", e.args.o, {"a", "w", "o"})
    /\ Track(B!AddTask(e.args.a, e.args.w, e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_matcher.go:415-430; service/matching/task_queue_partition_manager.go:644-659
TraceTrySyncMatchFallback(e) ==
    /\ Envelope(e, "TrySyncMatchFallback", calls[e.args.a].owner, {"a"})
    /\ Track(B!TrySyncMatchFallback(e.args.a))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_matcher.go:390-421; service/matching/matching_engine.go:3511-3527
TraceTrySyncMatch(e) ==
    /\ Envelope(e, "TrySyncMatch", calls[e.args.a].owner, {"a", "p"})
    /\ Track(B!TrySyncMatch(e.args.a, e.args.p))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_backlog_manager.go:248-252; service/matching/pri_task_writer.go:68-98
TraceSpoolTask(e) ==
    /\ Envelope(e, "SpoolTask", calls[e.args.a].owner, {"a"})
    /\ Track(B!SpoolTask(e.args.a))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_task_writer.go:162-170,182-190
TraceTaskWriterDequeue(e) ==
    /\ Envelope(e, "TaskWriterDequeue", e.args.o, {"o"})
    /\ Track(B!TaskWriterDequeue(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_task_writer.go:108-121
TraceAssignTaskIDs(e) ==
    /\ Envelope(e, "AssignTaskIDs", e.args.o, {"o"})
    /\ Track(B!AssignTaskIDs(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/db.go:528-573
TraceCreateTasksBegin(e) ==
    /\ Envelope(e, "CreateTasksBegin", e.args.o, {"o"})
    /\ Track(B!CreateTasksBegin(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* common/persistence/sql/task_v1.go:80-98,187-205
TraceCreateTasksCommit(e) ==
    /\ Envelope(e, "CreateTasksCommit", e.args.o, {"o", "tasks", "actualRange", "expectedRange"})
    /\ Track(B!CreateTasksCommit(e.args.o))
    /\ ObservedTasks(e.args.tasks, {writer[e.args.o].id})
    /\ e.args.actualRange = durable.range
    /\ e.args.expectedRange = writer[e.args.o].range
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* common/persistence/sql/task_v1.go:80-98,187-205
TraceCreateTasksConditionFailed(e) ==
    /\ Envelope(e, "CreateTasksConditionFailed", e.args.o, {"o", "actualRange", "expectedRange"})
    /\ Track(B!CreateTasksConditionFailed(e.args.o))
    /\ e.args.actualRange = durable.range
    /\ e.args.expectedRange = writer[e.args.o].range
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/db.go:677-697; common/persistence/sql/task_v1.go:80-98
TraceCreateTasksReject(e) ==
    /\ Envelope(e, "CreateTasksReject", e.args.o, {"o", "result"})
    /\ Track(B!CreateTasksReject(e.args.o, e.args.result))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/db.go:575-597; service/matching/pri_task_writer.go:124-137; service/matching/pri_backlog_manager.go:108-116
TraceCreateTasksReturn(e) ==
    /\ Envelope(e, "CreateTasksReturn", e.args.o, {"o", "reply"})
    /\ Track(B!CreateTasksReturn(e.args.o, e.args.reply))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/db.go:575-596,677-697; service/matching/pri_task_writer.go:125-133
TraceCreateTasksUncertainReturn(e) ==
    /\ Envelope(e, "CreateTasksUncertainReturn", e.args.o, {"o"})
    /\ Track(B!CreateTasksUncertainReturn(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_task_reader.go:382-412
TraceSignalNewTasksBypass(e) ==
    /\ Envelope(e, "SignalNewTasksBypass", e.args.o, {"o"})
    /\ Track(B!SignalNewTasksBypass(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_task_reader.go:390-403
TraceSignalNewTasksWake(e) ==
    /\ Envelope(e, "SignalNewTasksWake", e.args.o, {"o"})
    /\ Track(B!SignalNewTasksWake(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_task_reader.go:298-314; service/matching/physical_task_queue_manager.go:601-610
TraceAddTaskToMatcher(e) ==
    /\ Envelope(e, "AddTaskToMatcher", e.args.o, {"o", "r"})
    /\ Track(B!AddTaskToMatcher(e.args.o, e.args.r))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_task_reader.go:316-338
TraceAddTaskToMatcherClosed(e) ==
    /\ Envelope(e, "AddTaskToMatcherClosed", e.args.o, {"o", "r"})
    /\ Track(B!AddTaskToMatcherClosed(e.args.o, e.args.r))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_task_reader.go:410-412; service/matching/pri_task_writer.go:136-137
TraceSignalReadersDone(e) ==
    /\ Envelope(e, "SignalReadersDone", e.args.o, {"o"})
    /\ Track(B!SignalReadersDone(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_task_writer.go:168-174
TraceTaskWriterPublish(e) ==
    /\ Envelope(e, "TaskWriterPublish", e.args.o, {"o"})
    /\ Track(B!TaskWriterPublish(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_task_writer.go:89-96; service/matching/task_queue_partition_manager.go:659-668
TraceAppendTaskReceive(e) ==
    /\ Envelope(e, "AppendTaskReceive", calls[e.args.a].owner, {"a"})
    /\ Track(B!AppendTaskReceive(e.args.a))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_task_writer.go:72-96
TraceAppendTaskShutdown(e) ==
    /\ Envelope(e, "AppendTaskShutdown", calls[e.args.a].owner, {"a"})
    /\ Track(B!AppendTaskShutdown(e.args.a))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/task_queue_partition_manager.go:638,659-670
TraceAddTaskReply(e) ==
    /\ Envelope(e, "AddTaskReply", calls[e.args.a].owner, {"a"})
    /\ Track(B!AddTaskReply(e.args.a))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/task_queue_partition_manager.go:638,659-670
TraceAddTaskReplyLost(e) ==
    /\ Envelope(e, "AddTaskReplyLost", calls[e.args.a].owner, {"a"})
    /\ Track(B!AddTaskReplyLost(e.args.a))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_task_reader.go:163-177,214-217
TraceGetTasksPump(e) ==
    /\ Envelope(e, "GetTasksPump", e.args.o, {"o"})
    /\ Track(B!GetTasksPump(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_task_reader.go:219-244; service/matching/db.go:120-129
TraceGetTaskBatchMax(e) ==
    /\ Envelope(e, "GetTaskBatchMax", e.args.o, {"o"})
    /\ Track(B!GetTaskBatchMax(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_task_reader.go:222-230; service/matching/db.go:700-715
TraceGetTasksIssue(e) ==
    /\ Envelope(e, "GetTasksIssue", e.args.o, {"o"})
    /\ Track(B!GetTasksIssue(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* common/persistence/sql/task_v1.go:114-155; common/persistence/sql/sqlplugin/sqlite/task_v1.go:45-74
TraceGetTasksSnapshot(e) ==
    /\ Envelope(e, "GetTasksSnapshot", e.args.o, {"o", "tasks", "min", "max", "limit"})
    /\ Track(B!GetTasksSnapshot(e.args.o))
    /\ ObservedTasks(e.args.tasks, reader'[e.args.o].rows)
    /\ e.args.min = reader[e.args.o].low + 1
    /\ e.args.max = reader[e.args.o].upper + 1
    /\ e.args.limit = BatchSize
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_task_reader.go:177-186,231-232,415-427
TraceGetTasksError(e) ==
    /\ Envelope(e, "GetTasksError", e.args.o, {"o"})
    /\ Track(B!GetTasksError(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_task_reader.go:415-427
TraceBackoffSignal(e) ==
    /\ Envelope(e, "BackoffSignal", e.args.o, {"o"})
    /\ Track(B!BackoffSignal(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_task_reader.go:222-244
TraceGetTaskBatchReturn(e) ==
    /\ Envelope(e, "GetTaskBatchReturn", e.args.o, {"o"})
    /\ Track(B!GetTaskBatchReturn(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_task_reader.go:247-295
TraceProcessTaskBatch(e) ==
    /\ Envelope(e, "ProcessTaskBatch", e.args.o, {"o"})
    /\ Track(B!ProcessTaskBatch(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_task_reader.go:198-200,280-282
TraceProcessTaskBatchDone(e) ==
    /\ Envelope(e, "ProcessTaskBatchDone", e.args.o, {"o"})
    /\ Track(B!ProcessTaskBatchDone(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_task_reader.go:484-497
TraceSetReadLevelAfterGapStale(e) ==
    /\ Envelope(e, "SetReadLevelAfterGapStale", e.args.o, {"o"})
    /\ Track(B!SetReadLevelAfterGapStale(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_task_reader.go:190-195,498-511
TraceSetReadLevelAfterGap(e) ==
    /\ Envelope(e, "SetReadLevelAfterGap", e.args.o, {"o"})
    /\ Track(B!SetReadLevelAfterGap(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_task_reader.go:498-511
TraceSetReadLevelAfterGapAck(e) ==
    /\ Envelope(e, "SetReadLevelAfterGapAck", e.args.o, {"o"})
    /\ Track(B!SetReadLevelAfterGapAck(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/db.go:336-355; service/matching/pri_task_reader.go:509-511,190-195
TraceUpdateAckLevelAfterGap(e) ==
    /\ Envelope(e, "UpdateAckLevelAfterGap", e.args.o, {"o"})
    /\ Track(B!UpdateAckLevelAfterGap(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/matching_engine.go:1015-1035,3511-3527,3590-3606
TracePollTask(e) ==
    /\ Envelope(e, "PollTask", e.args.o, {"o", "r", "p"})
    /\ Track(B!PollTask(e.args.o, e.args.r, e.args.p))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/matching_engine.go:3494-3527,3575-3606
TraceRecordTaskStartedBegin(e) ==
    /\ Envelope(e, "RecordTaskStartedBegin", dispatch[e.args.p].owner, {"p", "q"})
    /\ Track(B!RecordTaskStartedBegin(e.args.p, e.args.q))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/matching_engine.go:3494-3503,3575-3584
TraceRecordTaskStartedPrecheckError(e) ==
    /\ Envelope(e, "RecordTaskStartedPrecheckError", dispatch[e.args.p].owner, {"p", "result"})
    /\ Track(B!RecordTaskStartedPrecheckError(e.args.p, e.args.result))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/history/api/recordworkflowtaskstarted/api.go:68-111; service/history/api/recordactivitytaskstarted/api.go:150-183
TraceRecordTaskStarted(e) ==
    /\ Envelope(e, "RecordTaskStarted", dispatch[e.args.p].owner, {"p", "work", "request"})
    /\ Track(B!RecordTaskStarted(e.args.p))
    /\ e.args.work = dispatch[e.args.p].work
    /\ e.args.request = dispatch[e.args.p].request
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/matching_engine.go:865-879,1113-1123; service/matching/pri_task_reader.go:119-139
TraceRecordTaskStartedError(e) ==
    /\ Envelope(e, "RecordTaskStartedError", dispatch[e.args.p].owner, {"p", "result"})
    /\ Track(B!RecordTaskStartedError(e.args.p, e.args.result))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/matching_engine.go:808-885,1035-1128
TraceRecordTaskStartedReply(e) ==
    /\ Envelope(e, "RecordTaskStartedReply", dispatch[e.args.p].owner, {"p"})
    /\ Track(B!RecordTaskStartedReply(e.args.p))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/matching_engine.go:3527,3606; service/history/api/recordworkflowtaskstarted/api.go:98-111
TraceRecordTaskStartedRetryRPC(e) ==
    /\ Envelope(e, "RecordTaskStartedRetryRPC", dispatch[e.args.p].owner, {"p"})
    /\ Track(B!RecordTaskStartedRetryRPC(e.args.p))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/matching_engine.go:3527-3529,3606; service/matching/pri_task_reader.go:123-132
TraceRecordTaskStartedReplyLost(e) ==
    /\ Envelope(e, "RecordTaskStartedReplyLost", dispatch[e.args.p].owner, {"p"})
    /\ Track(B!RecordTaskStartedReplyLost(e.args.p))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/task.go:373-395; service/matching/pri_matcher.go:391-412; service/matching/task_queue_partition_manager.go:619-659
TraceFinishSyncTask(e) ==
    /\ Envelope(e, "FinishSyncTask", dispatch[e.args.p].owner, {"p"})
    /\ Track(B!FinishSyncTask(e.args.p))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_task_reader.go:119-133
TraceCompleteTaskTransient(e) ==
    /\ Envelope(e, "CompleteTaskTransient", dispatch[e.args.p].owner, {"p"})
    /\ Track(B!CompleteTaskTransient(e.args.p))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_task_reader.go:135-140; service/matching/pri_backlog_manager.go:360-369
TraceRespoolTaskAfterError(e) ==
    /\ Envelope(e, "RespoolTaskAfterError", dispatch[e.args.p].owner, {"p"})
    /\ Track(B!RespoolTaskAfterError(e.args.p))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_task_writer.go:172-174
TraceTaskWriterPublishReplacement(e) ==
    /\ Envelope(e, "TaskWriterPublishReplacement", e.args.o, {"o"})
    /\ Track(B!TaskWriterPublishReplacement(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_backlog_manager.go:367-387; service/matching/pri_task_reader.go:137-139
TraceRespoolTaskReturn(e) ==
    /\ Envelope(e, "RespoolTaskReturn", dispatch[e.args.p].owner, {"p"})
    /\ Track(B!RespoolTaskReturn(e.args.p))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_backlog_manager.go:367-369
TraceRespoolTaskRetry(e) ==
    /\ Envelope(e, "RespoolTaskRetry", dispatch[e.args.p].owner, {"p"})
    /\ Track(B!RespoolTaskRetry(e.args.p))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_task_writer.go:72-96; service/matching/pri_backlog_manager.go:374-387
TraceRespoolTaskShutdown(e) ==
    /\ Envelope(e, "RespoolTaskShutdown", dispatch[e.args.p].owner, {"p"})
    /\ Track(B!RespoolTaskShutdown(e.args.p))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_task_reader.go:142-156,452-479
TraceCompleteTaskAck(e) ==
    /\ Envelope(e, "CompleteTaskAck", dispatch[e.args.p].owner, {"p"})
    /\ Track(B!CompleteTaskAck(e.args.p))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_task_reader.go:448-449,476-479; service/matching/db.go:120-129
TraceAckTaskLockedDrained(e) ==
    /\ Envelope(e, "AckTaskLockedDrained", e.args.o, {"o"})
    /\ Track(B!AckTaskLockedDrained(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_task_reader.go:149-156,522-540
TraceMaybeGCLocked(e) ==
    /\ Envelope(e, "MaybeGCLocked", e.args.o, {"o", "launch"})
    /\ Track(B!MaybeGCLocked(e.args.o, e.args.launch))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_task_reader.go:156; service/matching/db.go:336-355
TraceUpdateAckLevelAndBacklogStats(e) ==
    /\ Envelope(e, "UpdateAckLevelAndBacklogStats", e.args.o, {"o"})
    /\ Track(B!UpdateAckLevelAndBacklogStats(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/matching_engine.go:885-887,1128-1130
TracePollTaskQueueResponse(e) ==
    /\ Envelope(e, "PollTaskQueueResponse", dispatch[e.args.p].owner, {"p"})
    /\ Track(B!PollTaskQueueResponse(e.args.p))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/matching_engine.go:885-887,1128-1130
TracePollTaskQueueResponseLost(e) ==
    /\ Envelope(e, "PollTaskQueueResponseLost", dispatch[e.args.p].owner, {"p"})
    /\ Track(B!PollTaskQueueResponseLost(e.args.p))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/task_validation.go:217-219
TraceExpireTask(e) ==
    /\ Envelope(e, "ExpireTask", 0, {"w"})
    /\ Track(B!ExpireTask(e.args.w))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/history/api/recordworkflowtaskstarted/api.go:68-78; service/history/api/recordactivitytaskstarted/api.go:178-183
TraceObsoleteTask(e) ==
    /\ Envelope(e, "ObsoleteTask", 0, {"w"})
    /\ Track(B!ObsoleteTask(e.args.w))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_matcher.go:211-216,268-271; service/matching/pri_task_reader.go:364-366
TraceFinishExpiredTask(e) ==
    /\ Envelope(e, "FinishExpiredTask", e.args.o, {"o", "r", "p"})
    /\ Track(B!FinishExpiredTask(e.args.o, e.args.r, e.args.p))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/db.go:298-333
TraceSyncStateBegin(e) ==
    /\ Envelope(e, "SyncStateBegin", e.args.o, {"o", "kind"})
    /\ Track(B!SyncStateBegin(e.args.o, e.args.kind))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_task_writer.go:108-116,212-224; service/matching/db.go:152-165
TraceRenewLeaseBegin(e) ==
    /\ Envelope(e, "RenewLeaseBegin", e.args.o, {"o"})
    /\ Track(B!RenewLeaseBegin(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/db.go:152-159,176-183
TraceTakeOverTaskQueueBegin(e) ==
    /\ Envelope(e, "TakeOverTaskQueueBegin", e.args.o, {"o"})
    /\ Track(B!TakeOverTaskQueueBegin(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/db.go:179-196
TraceTakeOverTaskQueueSnapshot(e) ==
    /\ Envelope(e, "TakeOverTaskQueueSnapshot", e.args.o, {"o"})
    /\ Track(B!TakeOverTaskQueueSnapshot(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* common/persistence/sql/task_queues.go:86-127; service/matching/db.go:241-255
TraceUpdateTaskQueueCommit(e) ==
    /\ Envelope(e, "UpdateTaskQueueCommit", e.args.o, {"o", "actualRange", "expectedRange"})
    /\ Track(B!UpdateTaskQueueCommit(e.args.o))
    /\ e.args.actualRange = durable.range
    /\ e.args.expectedRange = metadata[e.args.o].expect
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/db.go:318-333
TraceVerifyOwnership(e) ==
    /\ Envelope(e, "VerifyOwnership", e.args.o, {"o", "actualRange"})
    /\ Track(B!VerifyOwnership(e.args.o))
    /\ e.args.actualRange = durable.range
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* common/persistence/sql/task_queues.go:97-106; common/persistence/sql/task_v1.go:187-205
TraceUpdateTaskQueueConditionFailed(e) ==
    /\ Envelope(e, "UpdateTaskQueueConditionFailed", e.args.o, {"o", "actualRange", "expectedRange"})
    /\ Track(B!UpdateTaskQueueConditionFailed(e.args.o))
    /\ e.args.actualRange = durable.range
    /\ e.args.expectedRange = metadata[e.args.o].expect
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/db.go:246-251,319-325
TraceUpdateTaskQueueError(e) ==
    /\ Envelope(e, "UpdateTaskQueueError", e.args.o, {"o"})
    /\ Track(B!UpdateTaskQueueError(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/db.go:246-255
TraceUpdateTaskQueueReplyLost(e) ==
    /\ Envelope(e, "UpdateTaskQueueReplyLost", e.args.o, {"o"})
    /\ Track(B!UpdateTaskQueueReplyLost(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/db.go:196-207,241-255; service/matching/pri_task_writer.go:140-149,217-224; service/matching/pri_backlog_manager.go:108-116
TraceUpdateTaskQueueReturn(e) ==
    /\ Envelope(e, "UpdateTaskQueueReturn", e.args.o, {"o"})
    /\ Track(B!UpdateTaskQueueReturn(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/physical_task_queue_manager.go:319-328
TraceStopBegin(e) ==
    /\ Envelope(e, "StopBegin", e.args.o, {"o"})
    /\ Track(B!StopBegin(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_backlog_manager.go:108-116,374-387; service/matching/physical_task_queue_manager.go:319-334
TraceUnloadAfterError(e) ==
    /\ Envelope(e, "UnloadAfterError", e.args.o, {"o"})
    /\ Track(B!UnloadAfterError(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_backlog_manager.go:125-140
TraceStopRefreshAck(e) ==
    /\ Envelope(e, "StopRefreshAck", e.args.o, {"o"})
    /\ Track(B!StopRefreshAck(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_backlog_manager.go:142-144
TraceStopSyncState(e) ==
    /\ Envelope(e, "StopSyncState", e.args.o, {"o"})
    /\ Track(B!StopSyncState(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/physical_task_queue_manager.go:327-334
TraceStopCancel(e) ==
    /\ Envelope(e, "StopCancel", e.args.o, {"o"})
    /\ Track(B!StopCancel(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/db.go:176-207; service/matching/pri_task_writer.go:68-98
TraceCrash(e) ==
    /\ Envelope(e, "Crash", e.args.o, {"o"})
    /\ Track(B!Crash(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/db.go:741-765; common/persistence/sql/task_v1.go:158-184; common/persistence/sql/sqlplugin/sqlite/task_v1.go:28-31,77-96
TraceCompleteTasksLessThan(e) ==
    /\ Envelope(e, "CompleteTasksLessThan", e.args.o, {"o", "deleted", "max", "limit"})
    /\ Track(B!CompleteTasksLessThan(e.args.o))
    /\ ObservedTasks(e.args.deleted, durable.rows \ durable'.rows)
    /\ e.args.max = owner[e.args.o].gcBound + 1
    /\ e.args.limit = DeleteBatchSize
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_task_reader.go:543-577
TraceDoGCReturn(e) ==
    /\ Envelope(e, "DoGCReturn", e.args.o, {"o"})
    /\ Track(B!DoGCReturn(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_task_reader.go:550-568
TraceDoGCError(e) ==
    /\ Envelope(e, "DoGCError", e.args.o, {"o"})
    /\ Track(B!DoGCError(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_task_writer.go:68-98,152-179
TraceDiscardCrashedWriter(e) ==
    /\ Envelope(e, "DiscardCrashedWriter", e.args.o, {"o"})
    /\ Track(B!DiscardCrashedWriter(e.args.o))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/matching_engine.go:1002-1035,1128-1130
TracePollerDisconnect(e) ==
    /\ Envelope(e, "PollerDisconnect", dispatch[e.args.p].owner, {"p"})
    /\ Track(B!PollerDisconnect(e.args.p))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* service/matching/pri_task_reader.go:137-139; service/matching/matching_engine.go:865-882,1113-1126
TracePollTaskErrorReturn(e) ==
    /\ Envelope(e, "PollTaskErrorReturn", dispatch[e.args.p].owner, {"p"})
    /\ Track(B!PollTaskErrorReturn(e.args.p))
    /\ ValidatePostState(e)
    /\ l' = l + 1

\* Bootstrap/TraceEnd are trace framing, not hidden implementation steps.
TraceEnd(e) ==
    /\ l = Len(TraceLog) /\ Envelope(e,"TraceEnd",0,{})
    /\ UNCHANGED vars /\ ValidatePostState(e)
    /\ l' = l + 1

MatchEvent(e) ==
    CASE e.event = "RenewLeaseFailure" -> TraceRenewLeaseFailure(e)
      [] e.event = "RenewLeaseRetry" -> TraceRenewLeaseRetry(e)
      [] e.event = "SyncTaskReceive" -> TraceSyncTaskReceive(e)
      [] e.event = "SignalIfFatal" -> TraceSignalIfFatal(e)
      [] e.event = "TraceEnd" -> TraceEnd(e)
      [] e.event = "AddTask" -> TraceAddTask(e)
      [] e.event = "TrySyncMatchFallback" -> TraceTrySyncMatchFallback(e)
      [] e.event = "TrySyncMatch" -> TraceTrySyncMatch(e)
      [] e.event = "SpoolTask" -> TraceSpoolTask(e)
      [] e.event = "TaskWriterDequeue" -> TraceTaskWriterDequeue(e)
      [] e.event = "AssignTaskIDs" -> TraceAssignTaskIDs(e)
      [] e.event = "CreateTasksBegin" -> TraceCreateTasksBegin(e)
      [] e.event = "CreateTasksCommit" -> TraceCreateTasksCommit(e)
      [] e.event = "CreateTasksConditionFailed" -> TraceCreateTasksConditionFailed(e)
      [] e.event = "CreateTasksReject" -> TraceCreateTasksReject(e)
      [] e.event = "CreateTasksReturn" -> TraceCreateTasksReturn(e)
      [] e.event = "CreateTasksUncertainReturn" -> TraceCreateTasksUncertainReturn(e)
      [] e.event = "SignalNewTasksBypass" -> TraceSignalNewTasksBypass(e)
      [] e.event = "SignalNewTasksWake" -> TraceSignalNewTasksWake(e)
      [] e.event = "AddTaskToMatcher" -> TraceAddTaskToMatcher(e)
      [] e.event = "AddTaskToMatcherClosed" -> TraceAddTaskToMatcherClosed(e)
      [] e.event = "SignalReadersDone" -> TraceSignalReadersDone(e)
      [] e.event = "TaskWriterPublish" -> TraceTaskWriterPublish(e)
      [] e.event = "AppendTaskReceive" -> TraceAppendTaskReceive(e)
      [] e.event = "AppendTaskShutdown" -> TraceAppendTaskShutdown(e)
      [] e.event = "AddTaskReply" -> TraceAddTaskReply(e)
      [] e.event = "AddTaskReplyLost" -> TraceAddTaskReplyLost(e)
      [] e.event = "GetTasksPump" -> TraceGetTasksPump(e)
      [] e.event = "GetTaskBatchMax" -> TraceGetTaskBatchMax(e)
      [] e.event = "GetTasksIssue" -> TraceGetTasksIssue(e)
      [] e.event = "GetTasksSnapshot" -> TraceGetTasksSnapshot(e)
      [] e.event = "GetTasksError" -> TraceGetTasksError(e)
      [] e.event = "BackoffSignal" -> TraceBackoffSignal(e)
      [] e.event = "GetTaskBatchReturn" -> TraceGetTaskBatchReturn(e)
      [] e.event = "ProcessTaskBatch" -> TraceProcessTaskBatch(e)
      [] e.event = "ProcessTaskBatchDone" -> TraceProcessTaskBatchDone(e)
      [] e.event = "SetReadLevelAfterGapStale" -> TraceSetReadLevelAfterGapStale(e)
      [] e.event = "SetReadLevelAfterGap" -> TraceSetReadLevelAfterGap(e)
      [] e.event = "SetReadLevelAfterGapAck" -> TraceSetReadLevelAfterGapAck(e)
      [] e.event = "UpdateAckLevelAfterGap" -> TraceUpdateAckLevelAfterGap(e)
      [] e.event = "PollTask" -> TracePollTask(e)
      [] e.event = "RecordTaskStartedBegin" -> TraceRecordTaskStartedBegin(e)
      [] e.event = "RecordTaskStartedPrecheckError" -> TraceRecordTaskStartedPrecheckError(e)
      [] e.event = "RecordTaskStarted" -> TraceRecordTaskStarted(e)
      [] e.event = "RecordTaskStartedError" -> TraceRecordTaskStartedError(e)
      [] e.event = "RecordTaskStartedReply" -> TraceRecordTaskStartedReply(e)
      [] e.event = "RecordTaskStartedRetryRPC" -> TraceRecordTaskStartedRetryRPC(e)
      [] e.event = "RecordTaskStartedReplyLost" -> TraceRecordTaskStartedReplyLost(e)
      [] e.event = "FinishSyncTask" -> TraceFinishSyncTask(e)
      [] e.event = "CompleteTaskTransient" -> TraceCompleteTaskTransient(e)
      [] e.event = "RespoolTaskAfterError" -> TraceRespoolTaskAfterError(e)
      [] e.event = "TaskWriterPublishReplacement" -> TraceTaskWriterPublishReplacement(e)
      [] e.event = "RespoolTaskReturn" -> TraceRespoolTaskReturn(e)
      [] e.event = "RespoolTaskRetry" -> TraceRespoolTaskRetry(e)
      [] e.event = "RespoolTaskShutdown" -> TraceRespoolTaskShutdown(e)
      [] e.event = "CompleteTaskAck" -> TraceCompleteTaskAck(e)
      [] e.event = "AckTaskLockedDrained" -> TraceAckTaskLockedDrained(e)
      [] e.event = "MaybeGCLocked" -> TraceMaybeGCLocked(e)
      [] e.event = "UpdateAckLevelAndBacklogStats" -> TraceUpdateAckLevelAndBacklogStats(e)
      [] e.event = "PollTaskQueueResponse" -> TracePollTaskQueueResponse(e)
      [] e.event = "PollTaskQueueResponseLost" -> TracePollTaskQueueResponseLost(e)
      [] e.event = "ExpireTask" -> TraceExpireTask(e)
      [] e.event = "ObsoleteTask" -> TraceObsoleteTask(e)
      [] e.event = "FinishExpiredTask" -> TraceFinishExpiredTask(e)
      [] e.event = "SyncStateBegin" -> TraceSyncStateBegin(e)
      [] e.event = "RenewLeaseBegin" -> TraceRenewLeaseBegin(e)
      [] e.event = "TakeOverTaskQueueBegin" -> TraceTakeOverTaskQueueBegin(e)
      [] e.event = "TakeOverTaskQueueSnapshot" -> TraceTakeOverTaskQueueSnapshot(e)
      [] e.event = "UpdateTaskQueueCommit" -> TraceUpdateTaskQueueCommit(e)
      [] e.event = "VerifyOwnership" -> TraceVerifyOwnership(e)
      [] e.event = "UpdateTaskQueueConditionFailed" -> TraceUpdateTaskQueueConditionFailed(e)
      [] e.event = "UpdateTaskQueueError" -> TraceUpdateTaskQueueError(e)
      [] e.event = "UpdateTaskQueueReplyLost" -> TraceUpdateTaskQueueReplyLost(e)
      [] e.event = "UpdateTaskQueueReturn" -> TraceUpdateTaskQueueReturn(e)
      [] e.event = "StopBegin" -> TraceStopBegin(e)
      [] e.event = "UnloadAfterError" -> TraceUnloadAfterError(e)
      [] e.event = "StopRefreshAck" -> TraceStopRefreshAck(e)
      [] e.event = "StopSyncState" -> TraceStopSyncState(e)
      [] e.event = "StopCancel" -> TraceStopCancel(e)
      [] e.event = "Crash" -> TraceCrash(e)
      [] e.event = "CompleteTasksLessThan" -> TraceCompleteTasksLessThan(e)
      [] e.event = "DoGCReturn" -> TraceDoGCReturn(e)
      [] e.event = "DoGCError" -> TraceDoGCError(e)
      [] e.event = "DiscardCrashedWriter" -> TraceDiscardCrashedWriter(e)
      [] e.event = "PollerDisconnect" -> TracePollerDisconnect(e)
      [] e.event = "PollTaskErrorReturn" -> TracePollTaskErrorReturn(e)
      [] OTHER -> FALSE

\* There are no silent actions. All implementation/environment steps have hooks.
TraceNext ==
    \/ /\ l <= Len(TraceLog) /\ MatchEvent(TraceLog[l])
    \/ /\ l > Len(TraceLog) /\ UNCHANGED tracevars
TraceSpec == TraceInit /\ [][TraceNext]_tracevars /\ WF_tracevars(TraceNext)
TraceMatched == <>(l > Len(TraceLog))
=============================================================================
