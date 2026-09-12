# Applied source hooks

These are executed hooks, including scheduling and snapshot-only hooks. The observer maps outcome hooks to the exact action names listed in `post-keys.json`.

| Hook | Applied source location |
|---|---|
| `UpdateTaskQueueTransaction` | `common/persistence/sql/task_queues.go:127` |
| `CreateTasksTransaction` | `common/persistence/sql/task_v1.go:98` |
| `GetTasksSnapshot` | `common/persistence/sql/task_v1.go:137` |
| `CompleteTasksLessThan` | `common/persistence/sql/task_v1.go:186` |
| `SQLRangeCondition` | `common/persistence/sql/task_v1.go:202` |
| `RenewLeaseBegin` | `service/matching/db.go:159` |
| `TakeOverTaskQueueSnapshot` | `service/matching/db.go:188` |
| `MetadataLocalUpdated` | `service/matching/db.go:259` |
| `SyncStateBegin` | `service/matching/db.go:314` |
| `SyncStateReturn` | `service/matching/db.go:315` |
| `VerifyOwnership` | `service/matching/db.go:335` |
| `DBAckCache` | `service/matching/db.go:348` |
| `CreateTasksBegin` | `service/matching/db.go:574` |
| `CreateTasksReturn` | `service/matching/db.go:609` |
| `FairRespoolGate` | `service/matching/fair_backlog_manager.go:367` |
| `AddTaskToMatcher` | `service/matching/matcher_data.go:268` |
| `PollTask` | `service/matching/matcher_data.go:555` |
| `RecordTaskStartedReply` | `service/matching/matching_engine.go:809` |
| `PollTaskErrorReturn` | `service/matching/matching_engine.go:883` |
| `HistoryLimiterGate` | `service/matching/matching_engine.go:3497` |
| `RecordTaskStartedPrecheckError` | `service/matching/matching_engine.go:3505` |
| `RecordTaskStartedBegin` | `service/matching/matching_engine.go:3531` |
| `StopBegin` | `service/matching/physical_task_queue_manager.go:327` |
| `StopCancel` | `service/matching/physical_task_queue_manager.go:336` |
| `SignalIfFatal` | `service/matching/pri_backlog_manager.go:115` |
| `StopRefreshAck` | `service/matching/pri_backlog_manager.go:142` |
| `RespoolTaskReturn` | `service/matching/pri_backlog_manager.go:372` |
| `SignalIfFatal` | `service/matching/pri_backlog_manager.go:389` |
| `ValidatorGate` | `service/matching/pri_matcher.go:250` |
| `ValidationMatch` | `service/matching/pri_matcher.go:269` |
| `ValidationResult` | `service/matching/pri_matcher.go:271` |
| `FinishExpiredTask` | `service/matching/pri_matcher.go:274` |
| `ValidationDone` | `service/matching/pri_matcher.go:276` |
| `ValidationDone` | `service/matching/pri_matcher.go:285` |
| `CompleteTaskTransient` | `service/matching/pri_task_reader.go:131` |
| `RespoolCallbackBegin` | `service/matching/pri_task_reader.go:138` |
| `MaybeGCLocked` | `service/matching/pri_task_reader.go:158` |
| `UpdateAckLevelAndBacklogStats` | `service/matching/pri_task_reader.go:160` |
| `ReaderExited` | `service/matching/pri_task_reader.go:165` |
| `ReaderLoopGate` | `service/matching/pri_task_reader.go:170` |
| `GetTasksPump` | `service/matching/pri_task_reader.go:178` |
| `GapGate` | `service/matching/pri_task_reader.go:200` |
| `ProcessTaskBatchDone` | `service/matching/pri_task_reader.go:211` |
| `GetTaskBatchMax` | `service/matching/pri_task_reader.go:231` |
| `GetTasksIssue` | `service/matching/pri_task_reader.go:236` |
| `GetTaskBatchReturn` | `service/matching/pri_task_reader.go:247` |
| `ProcessTaskBatch` | `service/matching/pri_task_reader.go:293` |
| `MatcherRegistration` | `service/matching/pri_task_reader.go:325` |
| `AddTaskToMatcherClosed` | `service/matching/pri_task_reader.go:338` |
| `SignalNewTasksWake` | `service/matching/pri_task_reader.go:420` |
| `SignalNewTasksBypass` | `service/matching/pri_task_reader.go:427` |
| `BackoffFireGate` | `service/matching/pri_task_reader.go:440` |
| `BackoffSignal` | `service/matching/pri_task_reader.go:446` |
| `GetTasksError` | `service/matching/pri_task_reader.go:449` |
| `CompleteTaskAck` | `service/matching/pri_task_reader.go:498` |
| `AckTaskLockedDrained` | `service/matching/pri_task_reader.go:504` |
| `SetReadLevelAfterGapStale` | `service/matching/pri_task_reader.go:520` |
| `SetReadLevelAfterGapAck` | `service/matching/pri_task_reader.go:532` |
| `GapDone` | `service/matching/pri_task_reader.go:539` |
| `GCLaunch` | `service/matching/pri_task_reader.go:557` |
| `GCStoreGate` | `service/matching/pri_task_reader.go:574` |
| `GCDone` | `service/matching/pri_task_reader.go:575` |
| `DoGCReturn` | `service/matching/pri_task_reader.go:581` |
| `GCCount` | `service/matching/pri_task_reader.go:608` |
| `AppendTaskShutdown` | `service/matching/pri_task_writer.go:74` |
| `SpoolTask` | `service/matching/pri_task_writer.go:90` |
| `AppendTaskReceive` | `service/matching/pri_task_writer.go:93` |
| `AppendTaskShutdown` | `service/matching/pri_task_writer.go:99` |
| `RenewLeaseFailure` | `service/matching/pri_task_writer.go:118` |
| `LeaseBlockReturned` | `service/matching/pri_task_writer.go:122` |
| `AssignTaskIDs` | `service/matching/pri_task_writer.go:126` |
| `SignalReadersGate` | `service/matching/pri_task_writer.go:143` |
| `SignalReadersDone` | `service/matching/pri_task_writer.go:145` |
| `OwnerInitialized` | `service/matching/pri_task_writer.go:158` |
| `TaskWriterDequeue` | `service/matching/pri_task_writer.go:177` |
| `WriterPublishGate` | `service/matching/pri_task_writer.go:184` |
| `TaskWriterPublish` | `service/matching/pri_task_writer.go:186` |
| `RenewLeaseAttempt` | `service/matching/pri_task_writer.go:213` |
| `RenewLeaseErrorReturn` | `service/matching/pri_task_writer.go:216` |
| `SyncReceiveGate` | `service/matching/task.go:326` |
| `SyncTaskReceive` | `service/matching/task.go:328` |
| `FinishSyncTask` | `service/matching/task.go:396` |
| `AddTask` | `service/matching/task_queue_partition_manager.go:615` |
| `TrySyncMatchFallback` | `service/matching/task_queue_partition_manager.go:660` |

External observations and frame assembly are in:

- `service/matching/specula_observer_test.go:305`: `func (c *speculaObserver) probe(point string, a ...any) {`
- `service/matching/specula_observer_test.go:1088`: `func (c *speculaObserver) sqlProbe(ctx context.Context, point string, a ...any) {`
- `service/matching/specula_observer_test.go:1259`: `func (c *speculaObserver) bootstrap() {`
- `service/matching/specula_observer_test.go:1288`: `func (c *speculaObserver) seal() {`
- `service/matching/specula_observer_test.go:1307`: `func (c *speculaObserver) callerReply(info *persistencespb.TaskInfo, err error, lost bool) {`
- `service/matching/specula_observer_test.go:1326`: `func (c *speculaObserver) workerReply(p int, lost bool) {`
- `service/matching/specula_observer_test.go:1340`: `func (c *speculaObserver) historyObserved(req *historyservice.RecordWorkflowTaskStartedRequest, err error) {`
- `service/matching/specula_observer_test.go:1373`: `func (c *speculaObserver) expireWork(i int) {`
- `service/matching/specula_observer_test.go:1411`: `func (c *speculaObserver) retryObserved(req *historyservice.RecordWorkflowTaskStartedRequest) {`
- `service/matching/specula_observer_test.go:1426`: `func (c *speculaObserver) auditQuiescent() {`
