# Instrumentation specification: temporal-activity

Revision `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`; Category A. The ordinary-core projector is implemented in `../harness/project.py`. Current acceptance is 21 complete real traces; see `validation-report.md` for checking status and bounds. Original pre-validation contracts and incomplete inputs remain in `output/continuation-20260911/input-spec/` and older harness runs.

## 1. Trace event schema

Write real traces to `../traces/<scenario>.ndjson` relative to `spec/`. `Trace.tla` defaults to `../traces/trace.ndjson`; environment variable `JSON` chooses another file. Run from the spec directory with both the TLA tools and CommunityModules dependency jars. No silent actions are allowed. Every state-transition boundary below has one distinct event type; pure helper operators such as `RetryActivity`, `CreateNextActivityTimer` and the recursive timeout scan are captured within their enclosing in-lease action.

Every event has exactly the modeled `state` keys and its action's `args` keys. Common envelope:

```json
{
  "tag": "trace",
  "schemaVersion": 1,
  "seq": 2,
  "event": "AddActivityTaskScheduledEvent",
  "args": {},
  "state": "FULL INDEPENDENT POST-STATE OBJECT, as specified below",
  "evidence": {
    "sourceRevision": "0c010ce5fe8c0180aa7573c72fe8fc87c6df7025",
    "basis": "implementation",
    "complete": true,
    "ordering": "lease-and-transaction",
    "artifact": "relative/path/to/raw-observations-and-readbacks.jsonl"
  }
}
```

The string placeholder is explanatory, not an executable trace. Never replace missing fields with empty values, the model's successor, or a desired outcome. A field known to be empty is emitted explicitly. Unobserved/ambiguous values make the scenario **INCOMPLETE**; preserve the raw evidence and fix the capture point. The evidence envelope is a declared provenance contract: TLC checks its fields but cannot establish that a recorder is truthful.

Event 1 is `Bootstrap`, at the quiesced first normal WFT's already-accepted start, before its schedule commands. Its state must equal `base.Init`, including no Activities and no relevant generated tasks. It also carries `config` with all 16 base constants, `sourceRevision`, `backend="sqlite"`, `journalMode="wal"`, `synchronous="normal"`, `eagerRequest=false`, `workerControlCancellation=false`, `administrativeExtensions=false`. `Workers` is an array of stable actual worker identities. Record the instrumentation patch hash, binary/build identity, database paths, dynamic config and request options in its referenced provenance artifact. `KeepInitialWFT` records the first completion's actual ForceCreateNewWorkflowTask flag. `InitialDBVersion` is the independent DB version at this bootstrap boundary, not a guessed constant.

Integer Activity keys 1..ActivityCount are an order-preserving mapping from actual ScheduledEventIDs in this Run. Preserve original namespace/WorkflowID/RunID/event IDs and mappings in the raw artifact; no reuse across runs. Local model task/request/transaction IDs are canonical identities assigned on first independently observed creation, not reconstructed from a desired transition. Preserve their raw IDs, task categories and backend-attempt IDs too. IDs for tentative tasks are 0 until the shard key-allocation event. On key allocation, order descriptors consistently by their captured creation order (the Activity schedule batch is in ScheduledEventID order). This models identity/equality, not actual shard numeric spacing.

Time is integer milliseconds relative to a declared bootstrap origin with bootstrap now=1, after year 2000. A missing timestamp is -1; reloaded volatile heartbeat watermark is 0. `AdvanceTime.args.time` is the next actually observed clock reading: it can jump and requires no fabricated intermediate events. Use source timer millisecond truncation; do not compress timestamps by rank when doing so changes duration arithmetic, retry equality at expiration, or tie ordering. Clock skew and time skipping are excluded. Required request/policy inputs are positive integer retry parameters, finite attempts, no custom nextRetryDelay, and valid bounded payloads. Request details=-1 means absent/nil, 0 means present-empty, and 1 means one nonempty checkpoint. Final failure heartbeat progress is updated exactly when details is not -1. A standalone heartbeat always updates its timestamp, even with nil/empty details. Payload identity is abstracted to absent/empty=0 versus one nonempty checkpoint=1; use a different configured payload domain before validating scenarios with multiple distinct checkpoints.

### State objects and independent capture sources

`state` is a complete snapshot of `s`, assembled from immutable observations. JSON objects represent records; JSON arrays represent sequences or sets according to the exact field list below. `Trace.DecodeState` converts only declared set fields. Arrays for ActivityInfo and watermark are ordered by Activity key. Preserve event sequence order and duplicates; History and buffer are **sequences**, so duplicated terminal events are not silently deduplicated.

| State field(s) | Exact encoding and independent source |
|---|---|
| `now` | Observed normalized History clock milliseconds; hook each modeled use of current time. |
| `cache`, `db` | Workflow records below. `cache` comes from immutable in-lease Mutable State; `db` comes from actual store commits or fenced/version-bracketed reads, never the attempted payload alone. Cache-invalid encoding is `EmptyWF` with `valid=false`; this means unavailable cache, not empty durable state. |
| `valid`, `phase`, `tx`, `newTasks` | Cache presence; observed operation phase; current logical transaction metadata; generated descriptor sequence. `phase`: Idle, Mutated, Closed, Prepared, Waiting, Result, RejectedClose, CloseReloaded. Capture each boundary; do not infer phase from RPC return. |
| `watermark` | Array of `pendingActivityTimerHeartbeats` values, under lease. Capture directly before/after timer execution/generation/reload. It is not serialized ActivityInfo. If cleared cache, all -1; DB reconstruction maps set HB mask to 0. |
| `dbVersion`, `range`, `owner`, `needFence` | Actual DBRecordVersion and shard ownership receipt, normalized from bootstrap. `range` is durable fencing generation; `owner` is local generation. `needFence` records observed lost/unknown state requiring acquisition. No database power-loss claim. |
| `tasks` | Set-array of Task records, actual durable History queue task rows. Every committed generated task category is observed, including WFT transfer rows; no flattening that loses category/TaskID. Rows remain until observed category/range retirement. All selected rows in one backend deletion commit disappear in one RangeCompleteHistoryTasks event; never synthesize intermediate per-row states. Scheduled deletion retires whole millisecond buckets (queue_base.go:377-379). |
| `claimed`, `ackable` | Set-arrays of task IDs observed executing versus successfully classified for Ack. A task in `ackable` no longer promises execution; its row can remain until Ack. Capture actual queue status transitions. |
| `copies`, `matching`, `dispatchReturns` | Set-arrays of immutable producer Delivery copies, Matching accepted queue work, and pending successful AddActivityTask returns (origin task IDs). Matching copy is identified separately from durable source task. |
| `startCalls`, `startMsgs`, `polls`, `lostStarts` | All issued StartCall records; outstanding start messages; live Matching poll/start responsibility; start request IDs with controlled lost response. Correlate actual child request UUID/retries and child deadline. |
| `tokens` | Set-array of Token records actually delivered to workers, decoded from real poll response. Never create a token just because AI says started. |
| `requests` | Set-array of in-flight ordinary worker Request records, captured at send and History handler entry. |
| `replies`, `pollReplies`, `observed` | Set-arrays of Reply records at History return, Matching poll-response preparation, and actual client receipt, respectively. Each layer must have its own hook. |
| `acknowledged`, `cancelObserved` | Set-arrays of terminal Event projections from successful received result replies, and tokens whose received heartbeat response had CancelRequested=true. These are observation monitors, not server fields. |
| `writes`, `receipts` | Set-arrays of immutable Write records still executing and backend receipt records. A receipt is `{id,attempt,status}` where status is Commit, Aborted, Rejected, Condition or Ownership. Separate logical request ID from backend attempt. Retain prior Commit when the final attempt returns Condition. |
| `historyAppends` | Set-array of `{id,events}` containing newly appended raw History batches, before execution commit. Batches from failed writes remain raw evidence, excluded from committed logical History. Exact repeated append of the same request/batch is coalesced. |
| `committedOutcomes` | Monotone set-array of terminal Event projections independently observed in successful SQL commits. Monitor of actual commits, never derived from returned errors. |
| `issuedRequests` | Set-array of the exact original ordinary worker Request records, retained across server-interceptor retry. |
| `keyFloor` | Last observed minimum scheduled time at a selected key-allocation boundary; initially 0 as an observer ledger, not a claim that the actual shard cursor is zero. |
| `appended` | Set-array of `{id,attempt}` receipts for the actual SQL append stage, independent of invocation submission and response delivery. |
| `notifyPending`, `notified` | Set-arrays of logical transaction IDs eligible for task notification and notifications actually delivered. Notify may occur for an uncertain result and is not commit proof. |
| `nextTxn`, `nextTask`, `nextDelivery`, `nextRequest` | Canonical identity allocator state, driven by raw first-observation records. This is observer bookkeeping, not a prediction of server state. |
| `lastCheck` | `{stale,beforeAI,afterAI,beforeTerms,afterTerms}` from the most recent worker token handler's immutable before/after lease snapshots. Term fields are set-arrays. `stale` means AI absent or attempt differs; capture actual input token. |
| `readback` | `{version,range,outcomes}` from the last independent quiesced/fenced DB/task read; outcomes is a set-array. A stale readback remains labeled with its actual version. |
| `traceComplete` | False until observed complete endpoint; true only for final FinishTrace. |

Workflow record (`cache`/`db`/`Write.wf`):

| Field | Mapping |
|---|---|
| `ai` | Array of ActivityInfo records below. Deleted ActivityInfo becomes exactly EmptyAI; terminal outcome remains in History/buffer. |
| `scheduled` | Set-array of all scheduled Activity keys in the workload, derived from committed or tentative scheduled History events as appropriate. |
| `history`, `buffer` | Ordered Event arrays projected from logically selected History and persisted/tentative buffered events, respectively. Capture both; retry-policy transient Started state is not a History event. |
| `wft` | None, Pending or Started from normal WorkflowTaskInfo/ExecutionInfo. |
| `seen` | Set-array of terminal Events actually included in the currently accepted WFT's History input. A later buffered result is excluded. |
| `consumed` | Set-array accumulated only after the harness worker demonstrably observes those terminal input events and completes that WFT. This is a harness monitor of input consumption, not proof of external application side effects. |
| `open` | Actual IsWorkflowExecutionRunning projection; close can leave unresolved Activities. Core full-trace endpoint still requires every selected Activity terminal and consumed. |

ActivityInfo record:

| Model field | Source field / normalization |
|---|---|
| `present` | Membership in pendingActivityInfoIDs / persisted ActivityInfos. |
| `attempt` | ActivityInfo.Attempt; absent AI=0. |
| `started` | StartedEventId: empty -> No, TransientEventID -> Transient, concrete/buffered started marker -> Event. |
| `request` | Canonical RequestId; empty -> 0. |
| `version`, `startVersion`, `stamp` | ActivityInfo.Version, StartVersion, Stamp. Empty version is 0. Ordinary task tokens have no effective retry stamp; preserve raw ActivityAttemptStamp=0. |
| `first`, `scheduled`, `startTime` | FirstScheduledTime, ScheduledTime, StartedTime; absent -> -1. Freshly scheduled records have FirstScheduledTime; legacy-null fallback is outside initial trace schema. |
| `heartbeatTime`, `details` | LastHeartbeatUpdateTime and checkpoint projection from LastHeartbeatDetails. No fabricated initial heartbeat timestamp. |
| `cancel` | CancelRequested. Completion remains permitted after request. |
| `mask` | Set-array mapping TimerTaskStatus bits: 1->STC, 2->STS, 4->SCT, 8->HB. SCT survives ordinary retry. |

Message/payload record types:

| Type | Exact fields |
|---|---|
| Event | `{a,kind,attempt}`. kind: Scheduled, Started, CancelRequested, Completed, Failed, Canceled, STS, STC, SCT or HB. Timeout conversion to SCT follows actual RetryState=TIMEOUT except STS. Preserve raw RetryState/failure cause in evidence. |
| Task | `{id,kind,a,attempt,stamp,version,due,logical}`. kind also permits Transfer, Retry, WFT; WFT uses a=0/attempt=0/stamp=0. Pending generated IDs=0, then observed canonical IDs. `logical` retains the original timer/retry deadline; `due` is the physical visibility assigned by the shard. Both are -1 for immediate descriptors until physical key allocation; logical remains -1 for immediate tasks. |
| Delivery | `{id,origin,a,stamp,sent,expires}`. Contains no receiver attempt or not-before guard. sent is the producer observation clock; expires comes from actual Matching TaskInfo (initially -1 in an unaccepted copy). origin=0 for a Matching rewrite; all real queue/source IDs remain in raw correlation evidence. |
| StartCall | `{id,a,stamp,worker,sent,expires}`. sent/expires retain the originating delivery observations. Same UUID -> same id on internal retry; a new concrete dispatch gets a new id. |
| Token | `{a,attempt,version,startVersion,worker,request}`. Versions come from the received start response; duplicate-start path's missing versions are zero. Original namespace/Workflow/Run/ScheduledEventID and VectorClock are retained and checked against bootstrap identity in preprocessing. Future/forged clocks are excluded by the honest-issued-token, single-active-owner boundary. |
| Request | `{id,token,kind,details}`. kind: Completed, Failed, NonRetryable, Heartbeat, Canceled. Failed means retryable ApplicationFailure, NonRetryable means its actual nonretryable flag. |
| Reply | `{id,kind,status,token,outcome,cancel,details,metadata}`. outcome is an Event set-array (empty for retry success); status is OK, NotFound, Unknown, Rejected, Condition or Ownership. Internal placeholder uses None. metadata is true for fresh start response, false for duplicate reconstruction; raw record must include omitted WorkflowType/namespace/retryPolicy and HeartbeatDetails, not just this Boolean. |
| Write | `{id,attempt,expected,range,wf,tasks}`. expected is prior DBRecordVersion; tasks is a set-array of the exact observed generated tasks. |
| Transaction | `{id,attempt,expected,range,reply,cue,makeWFT,result}`. cue=0 except a timeout executor transaction. result initially Pending then actual persistence classification; reply is prepared output, not delivered acknowledgement. A rejected buffered close explicitly clears/reloads cache and fails/renews its WFT before the normal transaction stages. |

### Complete post-state validation

Every wrapper calls its full base action, checks the exact argument record shape, compares all of `s'` to `DecodeState(event.state)`, and advances `l`. Captured state fields cannot be omitted from comparisons. Buffer/history order, all AI identity/timing fields, durable tasks, pending writes, backend receipts, response tokens and observation monitors are checked. The final input line can advance only if its event is FinishTrace and the real endpoint guard holds. `Trace.cfg` enables `TraceMatched`; an unmatched event or prefix cannot be reported as a successful full trace.

## 2. Action-to-code mapping

All actions capture the complete `state` object above, using immutable carry-forward for fields whose observation has not changed. This is allowed only when the recorder has established causal order and an unchanged observation; it must never generate hidden server state. The following table identifies additional exact argument fields and capture timing for every action. **The trace event string equals the spec action name in each row.**

| Spec action / trace event | Source hook | Trigger point | `args` fields |
|---|---|---|---|
| `AddActivityTaskScheduledEvent` | `workflow/mutable_state_impl.go:4306-4401; api/respondworkflowtaskcompleted/api.go:558` | After schedule command batch and initial WFT completion, before close-transaction generation. | `{}` |
| `ProcessActivityTask` | `transfer_queue_active_task_executor.go:256-284` | After producer guards and immutable copy, at lease release. | `task: Task` |
| `ExecuteActivityRetryTimerTask` | `timer_queue_active_task_executor.go:563-621` | After attempt/stamp/start/version checks and snapshot, at lease release. | `task: Task` |
| `DiscardObsoleteActivityTask` | `transfer_queue_active_task_executor.go:256-274; timer_queue_active_task_executor.go:565-597` | After obsolete task classification; no mutable-state write. | `task: Task` |
| `AddActivityTask` | `service/matching/matching_engine.go:646-693; service/matching/task_queue_partition_manager.go:607-673` | After asynchronous AddTask success, or at synchronous receiver acceptance before History start request creation; response still in flight. | `delivery: Delivery`, `created: Int` |
| `DeliverAddActivityTaskResponse` | `timer_queue_active_task_executor.go:623-639; transfer_queue_task_executor_base.go:95-144` | History receives successful AddActivityTask return, before durable-task Ack. | `id: Int` |
| `LoseAddActivityTaskResponse` | `timer_queue_active_task_executor.go:623-639` | Controlled response loss after observed Matching acceptance; preserve queued copy. | `id: Int` |
| `PollActivityTaskQueue` | `service/matching/matching_engine.go:3587-3606` | After dequeue and creation of the History start request; record actual RequestID. | `delivery: Delivery`, `worker: Worker` |
| `RetryRecordActivityTaskStarted` | `client/history/retryable_client_gen.go:674-686` | Before retrying the same still-live start request; retain actual UUID. | `call: StartCall` |
| `RecordActivityTaskStarted` | `api/recordactivitytaskstarted/api.go:118-184,294-310; workflow/mutable_state_impl.go:4502-4565` | After fresh-start mutation under lease, before persistence. | `call: StartCall` |
| `RecordActivityTaskStartedDuplicate` | `api/recordactivitytaskstarted/api.go:150-165,71-77` | After same-RequestID reconstruction. Capture omitted fields as actual zeros; Noop=false still persists. | `call: StartCall` |
| `RecordActivityTaskStartedRejected` | `api/recordactivitytaskstarted/api.go:124-136,168-184` | At rejected start return, without mutation; record precise real error in raw evidence. | `call: StartCall` |
| `SendActivityRequest` | `service/frontend/workflow_handler.go:1453-1463,1650-1659,1856-1865,2083-2092` | Before worker RPC is sent; capture decoded issued token and normalized request payload. | `token: Token`, `kind: String`, `details: Int` |
| `RespondActivityTaskCompleted` | `api/respondactivitytaskcompleted/api.go:74-126` | After guarded completion mutation, before shared updater closes transaction. | `request: Request` |
| `RespondActivityTaskFailed` | `api/respondactivitytaskfailed/api.go:88-125; workflow/mutable_state_impl.go:6880-6975` | After final heartbeat/retry-or-terminal branch; capture complete AI and generated retry descriptor. | `request: Request` |
| `RespondActivityTaskCanceled` | `api/respondactivitytaskcanceled/api.go:82-108` | After token/cancel-request checks and terminal mutation. | `request: Request` |
| `RecordActivityTaskHeartbeat` | `api/recordactivitytaskheartbeat/api.go:73-101; workflow/mutable_state_impl.go:2117-2127` | After AI heartbeat mutation and flag capture, before persistence. | `request: Request` |
| `RejectActivityRequest` | `api/activity_util.go:58-79; api/respondactivitytaskcanceled/api.go:82-89` | At rejected ordinary token operation; capture immutable before/after AI and terminal projection. | `request: Request` |
| `ExecuteActivityTimeoutTask` | `timer_queue_active_task_executor.go:230-280,299-378` | After the entire sorted scan under one lease, before close-transaction generation; retain scan input and per-entry raw outcomes. | `task: Task` |
| `DiscardClosedWorkflowTimer` | `timer_queue_active_task_executor.go:221-227` | After closed-Workflow classification; old cue can then be acknowledged. | `task: Task` |
| `RecordWorkflowTaskStarted` | `workflow/workflow_task_state_machine.go:453-479` | After accepted normal WFT start mutation; record terminal events actually included in its History input. | `{}` |
| `RespondWorkflowTaskCompleted` | `api/respondworkflowtaskcompleted/api.go:384,557-566; historybuilder/event_store.go:178-199` | After command-free WFT completion/flush; before transaction close. | `{}` |
| `HandleCommandRequestCancelActivity` | `api/respondworkflowtaskcompleted/workflow_task_completed_handler.go:692-717; workflow/mutable_state_impl.go:4741-4783,4865-4892` | After the cancellation command and WFT completion within their single lease. | `activity: Int` |
| `HandleCommandCancelBufferedActivity` | `workflow/mutable_state_impl.go:4751-4763; api/respondworkflowtaskcompleted/api.go:384,557-566` | Competing command finds the terminal buffered; record request event and flush with no second terminal. | `activity: Int` |
| `HandleCommandCompleteWorkflow` | `api/respondworkflowtaskcompleted/workflow_task_completed_handler.go:804-805` | After legal close command with no preexisting buffered events; include terminal input consumption. | `{}` |
| `HandleCommandCancelAndCompleteWorkflow` | `api/respondworkflowtaskcompleted/workflow_task_completed_handler.go:692-717,804-805; historybuilder/event_store.go:168-175` | After same-batch cancel then close; distinguish suppressed command-generated cancellation from preexisting worker result. | `activity: Int` |
| `ExecuteWorkflowRunTimeoutTask` | `timer_queue_active_task_executor.go:658-818; workflow/util.go:72-92,28-49` | After run-timeout closure with buffered-event flush. Optional existing run-timer interface, disabled in baseline configs. | `{}` |
| `CloseTransactionAsMutation` | `workflow/context.go:973-1001; workflow/mutable_state_impl.go:7616-7643,9055-9066; workflow/timer_sequence.go:118-164` | After close-transaction WFT/task/timer generation, before shard task IDs are allocated. | `{}` |
| `SetAndTrackTaskKeys` | `shard/context_impl.go:623-649` | After task IDs and RangeID are assigned; capture allocationTime, actual minScheduledTime and reader-shift setting. | `minimum: Int` |
| `AppendHistoryNodes` | `common/persistence/sql/execution.go:334-357` | After the actual History append stage of this backend attempt, potentially after a caller timeout; emit an empty-stage receipt when no History batches exist. | `write: Write` |
| `ApplyWorkflowMutationTx` | `common/persistence/sql/execution_util.go:23-190,629-695; common/persistence/sql/shard.go:152-176; common/persistence/sql/common.go:77-80` | Below fault wrapper, after actual SQL commit; record execution, AI, buffer, task rows and DBRecordVersion together. | `write: Write` |
| `RejectWorkflowMutationTx` | `common/persistence/sql/execution_util.go:645-661; common/persistence/sql/shard.go:158-169` | After real ownership/version rejection of this backend attempt; preserve any earlier logical-request commit receipt. | `write: Write` |
| `RejectPersistenceWrite` | `common/persistence/sql/common.go:57-74; common/persistence/faultinjection/fault.go:48-53` | After verified nonexecution/rollback for the selected injected rejection, never inferred solely from a final logical error. | `write: Write` |
| `PersistenceTimeoutBeforeWrite` | `common/persistence/faultinjection/fault.go:40-47,61-71` | At Timeout injection that skips delegate execution; independently record actual nonexecution. | `{}` |
| `PersistenceResponseTimeout` | `common/persistence/faultinjection/fault.go:42-47,61-71; shard/context_impl.go:1540-1548` | At unknown result delivery. Keep actual backend commit/pending status separate; ExecuteAndTimeout follows an observed commit. | `{}` |
| `RetryPersistenceAfterUnavailable` | `common/persistence/persistence_retryable_clients.go:252-264; common/persistence/sql/common.go:77-78` | Before internal same-payload retry after lost successful commit response; backendAttempt increments, logical request does not. | `{}` |
| `ReturnPersistenceResult` | `workflow/transaction_impl.go:184-214` | After observed backend return; correlate final backendAttempt and error classification. | `{}` |
| `FinishUpdateWorkflowExecution` | `workflow/context.go:888-909; workflow/cache/cache.go:373-409; workflow/transaction_impl.go:201-214` | At update-helper completion and lease release; enqueue response separately from external delivery. | `{}` |
| `ClearWorkflowCache` | `workflow/context.go:174-185` | After cache-only clear; raw DB/task observations remain unchanged. | `{}` |
| `LoseShardContext` | `shard/context_impl.go:1534-1548` | At History shard-context loss; log kind exactly, retain any detached backend requests and independent Matching state. | `{}` |
| `ReacquireShard` | `shard/context_impl.go:1541-1547; common/persistence/sql/shard.go:152-176` | After successful RangeID acquisition fencing prior writers, before reliable readback. | `{}` |
| `LoadMutableState` | `workflow/context.go:416-435,474-497; workflow/mutable_state_impl.go:471-477` | After DB-based reconstruction, under lease; record volatile watermark reset separately from persistent AI mask. | `{}` |
| `ReadWorkflowExecution` | `common/persistence/sql/execution.go:210-330; api/describemutablestate/api.go:52-65` | After independent quiesced/fenced read, or version-bracketed matching DBRecordVersion; actual task-store read required. | `{}` |
| `NotifyOnExecutionMutation` | `workflow/transaction_impl.go:201-214` | At task notifier delivery; this is not evidence of task insertion. | `id: Int` |
| `RangeCompleteHistoryTasks` | `queues/queue_base.go:373-394; common/persistence/sql/execution_tasks.go:66-97` | After actual category/range batch deletion; all affected modeled rows retire atomically. An in-memory executable Ack is insufficient. | `tasks: Task set-array` |
| `RedeliverTask` | `queues/executable.go:742-770; timer_queue_active_task_executor.go:235-239` | When a previously executed but not durably retired task is redelivered; preserve its original task ID. | `task: Task` |
| `ReceiveRecordActivityTaskStartedResponse` | `service/matching/matching_engine.go:1117-1130; service/matching/backlog_manager.go:230-270` | Matching receives History return; success finishes queue task before worker response; transient error rewrites work. | `response: Reply` |
| `ExpireRecordActivityTaskStarted` | `service/matching/matching_engine.go:3587-3624,1117-1126; service/matching/backlog_manager.go:230-259` | After controlled lost History response reaches child deadline and Matching preserves/requeues task. | `call: StartCall` |
| `DeliverPollActivityTaskQueueResponse` | `service/matching/matching_engine.go:3435-3478` | At worker receipt of the actual poll response, after Matching finished queue task; decode token and metadata independently. | `response: Reply` |
| `DeliverActivityResponse` | `api/recordactivitytaskheartbeat/api.go:93-101; api/respondactivitytaskcompleted/api.go:131-133` | At client receipt of result/heartbeat response; cancellation observation and successful terminal acknowledgements are recorded here. | `response: Reply` |
| `LoseAPIResponse` | `service/matching/matching_engine.go:1128-1130; api/recordactivitytaskheartbeat/api.go:93-101` | At controlled response loss on History-to-Matching, Matching-to-worker or terminal/heartbeat response channel; identify exact boundary. | `response: Reply` |
| `AdvanceTime` | `queues/queue_scheduled.go:286-300; workflow/mutable_state_impl.go:2122-2123,4534,6949` | At next actually observed logical millisecond time; no model-derived intermediate timestamps or interpolated AI. | `time: Int` |
| `FinishTrace` | `api/respondworkflowtaskcompleted/api.go:384,557-566; common/persistence/sql/execution.go:210-330` | Observer endpoint only after independent terminal readback and terminal WFT consumption; no source successor is invented. | `{}` |
| `HandleCommandCompleteWorkflowRejected` | `api/respondworkflowtaskcompleted/workflow_task_completed_handler.go:804-805; api/respondworkflowtaskcompleted/api.go:490-529,1133-1134` | After close is rejected for preexisting buffer and cache is cleared; keep the same Workflow lease. | `{}` |
| `ReloadAfterRejectedWorkflowClose` | `api/respondworkflowtaskcompleted/api.go:1136-1141; workflow/mutable_state_impl.go:471-477` | After explicit DB reload under the held failed-command lease; capture conservative watermark. | `{}` |
| `FailWorkflowTaskAfterRejectedClose` | `api/respondworkflowtaskcompleted/api.go:1141-1154,529,557-566; historybuilder/event_store.go:178-199` | After WFT failure and buffer flush/renewed pending WFT, before close-transaction commit. | `{}` |

`Bootstrap` is the initial predicate observation, not a base transition. `RetryActivity`, `FinishActivity`, `CompleteWFT`, `CreateNextActivityTimer` and `ProcessSingleActivityTimeoutTask` are pure computations under one held lease; their whole input/output is included in their listed parent transition. In particular, emit one timeout-executor event after the **whole** scan, with raw per-entry evidence attached; do not split its SQL commit into per-Activity transactions. The close-transaction and shard-ID stages each have separate mandatory events.

## 3. Special considerations and acceptance handoff

**Ordering.** Allocate monotone `seq` when each observation is linearized, not when a background logger writes it. Freeze lease-owned snapshots before releasing the Workflow lock; timestamping a pointer after return is insufficient. Instrument below the fault wrapper for actual SQL completion and correlate immutable payload, actual DBRecordVersion, RangeID and backend attempt. Concurrent worker/Matching/network records must be ordered by their actual enqueue/dequeue/send/receive boundaries. A commit receipt arriving at the recorder later than the API error must still be placed at its independently established commit linearization point. If two layers cannot be ordered, preserve the ambiguity and mark INCOMPLETE; do not let a global logger mutex serialize application execution merely to make a trace match.

**Persistence.** The existing HistoryTaskRecorder records only nil delegate errors and flattens categories (`tests/testcore/history_task_recorder.go:83-168`); it is insufficient alone for ExecuteAndTimeout or atomic task/AI evidence. Capture commit below injection and independently read the concrete execution and task rows. Quiesce/fence before a multi-query SQLite read, or bracket the read with equal DBRecordVersions. For DescribeMutableState use SkipForceReload=false, capture any cache clear/load, and explicitly detect StartTransaction's possible flush write. The first schema assumes same namespace version and no speculative WFT so no such flush is required; a real flush demands a faithful new action, not a silent skip. Do not mislabel cache reload, shard reacquisition, process restart or database restart.

**Matching.** Track an in-flight poll through History start acceptance and persistence. On transient History error, Matching's backlog rewrite preserves work; on real NotFound/AlreadyStarted/obsolete rejection it can drop that copy. A successful Matching start response finishes its queue item before a worker receives the poll payload. Losing the latter can orphan an accepted start until its ordinary deadline/retry. Same-ID start retries are limited to the live child call. Metadata omission in duplicate-start reconstruction is known TV-2, not a new formal finding.

**Workflow responsibility.** Capture both buffered terminal information and pending/started WFT state; public Activity History alone misses intermediate attempts and buffered results. Complete the held WFT, observe the flush/follow-up obligation, start a WFT carrying the terminal event, and have the test worker assert it before completing. Do not count a successful result callback or prefix ending in ActivityInfo deletion as complete. Closing a Workflow with prior buffered events is blocked; same-command cancel+close may suppress its own immediate cancellation. Completed external Activities are not exactly-once external effects.

**Required next-phase scenarios and controls.** Reuse `tests/activity_test.go`/`tests/testcore/test_env.go` and the real SQLite persistence path: healthy schedule/start/heartbeat/complete; fail/retry followed by all four old-token operations; all four timeout types including shared two-Activity scan and heartbeat extension; scheduled/running/backoff cancellation with completion or timeout winning; start response loss; definitely uncommitted terminal write; commit with lost response; pending late write fenced by shard reacquisition; internal retry returning Condition after Commit; terminal buffered behind started WFT and consumed after reload. Both stamp settings need distinct provenance. Extend functional tests through complete endpoints. For each real positive trace make a wrong-attempt control and a separate wrong-durable-state control; also remove the last endpoint and a required state field. All controls must be rejected, while valid allowed races must remain accepted. Preserve raw and normalized traces, exact commands/configs, readbacks, hashes, and complete TLC output.

The original generation phase collected no real traces. Validation now includes 21 complete ordinary-core real traces; administrative extensions remain separate and unvalidated by this suite. Synthetic specification controls, if recorded in evidence, test the generated artifacts only and never count as independent Temporal executions.

## Continuation additions and exact projection roles

The complete current schema is the `s` record in base.Init plus the full DecodeState/ValidatePostState comparison in Trace.tla. New records and actions below are checked by the same comparison; these are not silent steps.

| Action | Independent boundary | Arguments |
|---|---|---|
| SubmitWorkflowMutation | execution_manager.go, immediately before the immutable request reaches the fault wrapper/store | `{}` |
| ShardReady | shard/context_impl.go, successful local contextRequestAcquired, separate from SQL RangeID write | `{}` |
| RetryActivityRequest | common/rpc/interceptor/retry.go, actual retry of the same ordinary request before the caller receives a result | `request: Request` |
| RetryMatchingActivityTask | pri_task_reader.go, retained work after the controlled lost History reply; ordinary internal reprocessing without an issued start is a side observation | `call: StartCall` |
| DropExpiredMatchingTask | matching/task.go or pri_task_reader.go, actual expiry disposition | `delivery: Delivery` |

Notifications become eligible at ReturnPersistenceResult and execute before lease release. A skipped pre-write Timeout has a submission receipt but no append receipt; ExecuteAndTimeout has an independent commit receipt. Internal retry retains the immutable expected version and payload. ReadWorkflowExecution requires matching returned/read-transaction versions, supports invalid cache before load, and records the actual independent readback. A rejected close is classified at the actual cache clear, followed by its under-lease reload and WFT failure/renewal.

The projector verifies the submitted mutation's version, AI changes/deletions, buffer delta, WFT state, tasks and History inputs. SQL commit and independent read snapshots supply durable state. Final separately retrieved History must equal the accumulated committed Activity projection. NewBufferedEvents is a delta and cannot replace the complete buffer. The source buffer flush reorders Started before terminal events while preserving each partition's order.

Only Activity transfer/retry/timeout and post-bootstrap normal WFT transfer tasks enter the formal task set. Pre-bootstrap WFT rows, WFT-timeout internals and visibility-indexing tasks are retained in raw evidence as excluded interfaces. This is a definition of the modeled Activity contract, not product-wide task coverage.

All source and receipt observations retain raw sequence anchors. Matching's private reprocessing, worker receipt copies and SQL-backup receipts are indexed as evidence roles rather than replayed as duplicate protocol mutations. Clock readings used by projected boundaries remain actual observed millisecond values; raw nanoseconds remain available. Neither an input state nor a missing value is obtained from TLA+ successors.
