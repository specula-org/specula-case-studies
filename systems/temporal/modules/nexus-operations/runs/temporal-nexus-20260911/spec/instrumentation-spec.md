# temporal-nexus instrumentation handoff

## 1. Trace event schema

Validation update: the Phase 2.5 files are raw receipts and do not yet satisfy this schema. See [validation-report.md](validation-report.md) for current replay status and [changelog.md](changelog.md) for source-backed boundary corrections. The synthetic fixtures in checks/ belong to the original spec hashes.

Current boundary corrections: Init starts after the first normal WFT is Started. Bufferable Nexus events enter the workspace buffer before close-transaction flushing even without a started WFT. The timer executor records consumed logical entries in the new tx.consumed set while v.timers remains the actual mutable-state timer list; FinishStateMachineTimers removes the processed entries. Full RefreshWorkflowTasks already generates logical timers and physical wake outputs before it returns. A positively identified definite pre-store failure can go from Prepared to Written without an AppendHistoryNodes receipt. These corrections supersede the corresponding capture descriptions below; the complete semantic join remains unfinished.

Pinned source: `temporalio/temporal@0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`; the source checkout was clean when inspected. This document specifies instrumentation, not an applied patch or an executed Temporal harness. Use the legacy workflow HSM implementation, SQLite `mode=memory, cache=shared`, CHASM workflow-operation flag=false/rollout=0, transition history=true, outbound reader enabled and cancel-ACK events=true, matching the brief. Read back these effective settings before recording a trace. Worker targets use `temporal://system`; a controlled external target needs the actual configured HTTP callback URL and allowlist. Keep that endpoint fixed throughout a trace.

Store implementation `.ndjson` files in `../traces/`, sibling to `spec/`. `Trace.tla` defaults to `../traces/trace.ndjson`; environment variable `JSON` selects another file. The `.ndjson` files in `checks/`, if present, are explicitly synthetic validator checks and must never be counted as implementation traces.

Every file begins with one Init header. Header fields are mandatory:

| Field | Value / capture |
|---|---|
| `recordingKind` | `"implementation"` for the future harness; `"synthetic"` only for the supplied validator checks; checked by Trace |
| `tag`, `event`, `schema` | `"temporal-nexus"`, `"Init"`, `1` |
| `sourceRevision`, `route`, `backend` | Exact pinned SHA, `"legacy-hsm"`, `"sqlite"` |
| `transitionHistory`, `cancelAckEvents`, `outboundEnabled` | Effective booleans, all true |
| `chasmWorkflowOperations`, `chasmRollout` | Effective false and 0 |
| `complete` | Exactly `{endpoint:true,hsm:true,persistence:true,tasks:true,history:true}`; assert only after the evidence join verifies completeness |
| `config.ops` | Array of stable normalized operation identities, e.g. `["op1"]`; two for capacity tests |
| `config.Capacity`, `S2C`, `S2S`, `STC`, `RequestTimeout`, `MinRequestTimeout`, `RetryDelay` | Observed effective limits/timeouts expressed in the same model time units; zero timeout means absent |
| `config.StartModes`, `config.RemoteResults` | Arrays of permitted outcomes; Async or synchronous Succeeded/Failed/Canceled, and remote Succeeded/Failed/Canceled |
| `post` | Complete initial semantic state corresponding to `base.Init`; start before the first modeled schedule command |

All subsequent rows have this envelope; no state fields may be omitted using `omitempty`:

```json
{
  "tag": "temporal-nexus",
  "index": 1,
  "event": "HandleScheduleCommand",
  "args": {"o": "op1"},
  "provenance": {"source": "workflow-lock", "receipt": "raw-source-file:record-id"},
  "evidence": {"boundary": "HandleScheduleCommand"},
  "post": {"...": "all fields specified below, never a partial snapshot"}
}
```

The ellipsis above is explanatory, not a valid trace. `Trace.tla` checks equality of the entire decoded `post` with the resulting base state and validates the separate evidence fields below. Unknown tags, empty step sequences, missing fields, mismatched input/config and a non-advancing cursor fail. The trace does not enable B1/B2 hunt invariants: authentic adverse implementation behavior must remain replayable.

### Complete semantic state (`post`, corresponding to `s`)

Use a capture/join ledger backed by raw observations. Do not run model actions in the tracer to manufacture post-state. A component may carry forward its last independently captured value while another component runs; record causality, ownership and source receipts for every update. The backend observer must resolve unknown write outcomes, even if resolution is joined retrospectively after RangeID reacquisition.

| State field | Implementation observation and mapping |
|---|---|
| `d`, `v` | Durable committed snapshot and current workflow-lock workspace, respectively. Capture raw persisted Nexus info/HSM tree, execution info, buffered events and history; `v` also includes uncommitted changes. `v` returns to `d` after AccessReturn or LoadMutableState. CacheLoss sets the unavailable workspace to EmptyDB; it does not erase durable data. |
| `d.ops[o]`, `v.ops[o]` | `node` = physical HSM node present. `state` maps Nexus enum to Absent/Scheduled/BackingOff/Started/Succeeded/Failed/Canceled/TimedOut. `rid`, `token` map actual RequestId and OperationToken with immutable aliases. `initial` is the parent initial versioned-transition identity; `cancelInitial` is the **separate child** initial identity. `attempt`, `cancelAttempt` are actual counters. `scheduled`, `started`, `next`, `cancelNext` capture timestamps. `cancel` maps absent child or its Unspecified/Scheduled/BackingOff/Succeeded/Failed state. `cancelRequested` is the observed committed/staged cancel-request event ledger. |
| Deleted-operation ledger | On deletion retain the last observed operation transition fields in the semantic ledger and set `node=false`. Independently prove DB node absence; do not serialize a fictitious persisted terminal HSM object. If cancellation is accepted against a missing node plus buffered completion, retain absent child and record the cancel-request event. |
| `d.history`, `v.history` | Ordered **Nexus-event projection** of visible/staged history: records `{op,kind,rid}`. Kinds: Scheduled, Started, CancelRequested, CancelAck, CancelFailed, Succeeded, Failed, Canceled, TimedOut. Record raw event IDs, batches and full attributes in the evidence sidecar. Preserve duplicate events and order; these are sequences, not sets. |
| `d.buffer`, `v.buffer` | Same event records for durable/staged buffered events. Capture actual buffer storage; do not derive it from what public History omits. Command events precede flushed buffered events. |
| `d.open`, `v.open`; `wft` | Actual workflow running flag; normalized in-flight WFT status Idle/Pending/Started. The modeled WFT is normal, not speculative. Command rows include their own WFT completion; independent StartWorkflowTask exposes the buffering window. Close rows are permitted only without unhandled buffered events. |
| `d.version`, `v.version` | DBRecordVersion as a dense commit ordinal relative to the bootstrap DB record; preserve the raw value in evidence and verify every increment. The staged workspace retains the precommit version until the atomic write. |
| `d.gen`, `v.gen` | Dense order-preserving alias for TaskGenerationShardClockTimestamp refresh generations; preserve raw TaskID/clock values and validate the before-watermark relation. RangeID is separate. |
| `d.timers`, `v.timers` | Array decoded as a **set** of logical HSM task records from actual StateMachineTimerGroup.Infos; preserve deadline and identity. An absent B1 timer stays absent. Invalid old logical entries can remain until their group is processed. |
| `d.wakeScheduled`, `v.wakeScheduled` | Array decoded as the set of deadlines whose logical timer groups have `Scheduled=true`. This is independently captured; an unscheduled first group generates a physical wake. |
| `queue`, `published` | Current available physical task tickets and cumulative publication ledger, captured at actual queue publication/readback and execution/ack boundaries. Physical task tickets are separate from logical timers. Current tickets are a set; a duplicate delivery has a distinct `copy` index. `published` only advances on observed backend commit or an observed copy of a published task. |
| `tx` | Trace transaction context, with `phase` Idle/Mutated/Timers/Prepared/Appended/Written/Notified; `source`, `op`, `work` (call/callback ID), `ticket`, `expected` DB version, `range` captured RangeID, `emitted` logical/outbound transition tasks, `wakes` physical wake outputs, `deleted` operation paths, `cutoff` wake reference time, `processed` inner logical-timer count, `outcome` and `trigger`. Set fields are arrays in JSON. Observe hook boundaries and actual transition output; never infer output from the desired invariant. |
| `calls` | Sequence of outbound call records `{op,rid,token,initial,task,phase,result,budget}`. One local ID per argument load, distinct from durable Attempt. Phases Loaded/Waiting/Received/Saving/Done. `budget` is zero before request construction, then the independently captured computed budget. `initial` is parent identity for start and child identity for cancel. |
| `messages` | Set of independently observed sent but not consumed requests/responses/callbacks. Message schema is below. Keep requests after caller expiry until the endpoint consumes them; do not infer nonacceptance from HTTP errors. |
| `remote[o]` | Controlled endpoint ledger `{accepted,mode,token,outcome,started,cancelSeen}`. Async initial outcome Pending; synchronous mode equals its terminal result. Record dedup hits/accepted effects independently. ACK changes cancelSeen and need not change outcome. |
| `callbackSeq` | Actual callback delivery ordinal, separate from outbound call ID and Attempt. |
| `replies`, `observed` | Set of server-produced pending callback responses and caller-received responses. Reply schema `{id,op,result,status}`, status Accepted/Error/NotFound. Success is observed only after actual caller receipt. |
| `raw` | Sequence of raw history append receipts represented by their Nexus history prefix. Append only when a new visible prefix was written; buffer-only writes do not append. Orphan prefixes can exist after noncommit and do not determine visible history. Preserve backend batch IDs/transaction IDs separately. |
| `notified` | Set of notification receipts `{version,source}` from NotifyOnExecutionMutation. May include a notification whose underlying unknown write did not commit. |
| `sealed[o]` | Set of terminal outcomes from independently observed **committed** history/buffer; a ghost audit ledger. |
| `cache`, `shard`, `range`, `readback` | Cache availability, Ready/Lost shard status, dense monotonic RangeID alias, last independently read DB-version ordinal. Cache reload copies durable timers; it does not call regeneration. |
| `now` | Monotonic normalized time; `AdvanceTime(to)` records the next observed instant and can jump. Use an affine integer time mapping preserving all deadline and minimum-budget comparisons, retaining original nanosecond timestamps. Reject an unmappable boundary or refine the model; do not round a comparison into agreement. |
| `admission` | Empty, Accepted or LimitExceeded from actual command handling. Accepted here is the staged command result; commit is independently observed in `d`. |

Task record: `{op,kind,initial,attempt,gen,at,origin,copy}`. `kind` is Invoke/Backoff/S2C/S2S/STC/Cancel/CancelBackoff/Wake. Immediate task deadline is 0. Wake has empty op and zero initial/attempt. `origin` is the creating workflow transaction ordinal, retained across a delivery copy; `copy` is an independently observed redelivery ordinal. Keep actual queue TaskID, initial/last/mutable-state versioned-transition tuples, node path and physical task deadline in the raw sidecar. Create immutable bijective identity maps; parent and child maps are separate. Raw RequestId and raw OperationToken need not have equal bytes: their separate maps use the same operation alias only for the endpoint's independently established stable binding; do not merge two different raw tokens into one token alias. No Attempt equality may be introduced by the trace join.

Message record: `{kind,id,op,rid,token,initial,result}`. `kind` is StartRequest/StartResponse/CancelRequest/CancelResponse/Callback. The first four use outbound call ordinal `id`; Callback uses callback delivery ordinal. `rid` comes from the actual wire request/callback token, not merely the HSM field. Results are Async/Succeeded/Failed/Canceled/Retryable/Refused/Ack or empty as applicable. BelowMin is local-only, never an endpoint acceptance. Stable request-ID dedup and async-token retention are controlled endpoint assumptions; record the endpoint's complete behavior to justify them.

### Additional mandatory independent evidence

| Event | Required `evidence` fields checked by Trace |
|---|---|
| UpdateWorkflowExecution | `outcome` equals the classified argument; `durable` is the independently observed resulting DB projection; `queue` is the independently observed queue projection. UnknownCommitted and UnknownNotCommitted both return errors but have different readback/commit evidence. |
| LoadMutableState | `durable`, `queue` from actual GetWorkflowExecution/task-store readback, after RangeID fencing if needed. |
| GenerateDirtySubStateMachineTasks | `logicalTimers`, `emitted` from actual timer groups and filtered transition outputs; include Scheduled flags in `post.v.wakeScheduled`. |
| executeInvocationTask / executeCancelationTask | `wire` is the actual normalized outgoing request and must match the modeled message. |
| EndpointAccept / EndpointCancelAck / EndpointComplete | `endpoint` is the independent endpoint ledger for that operation. |
| Every other action | Exactly `{boundary: "<event name>"}` plus the full post-state and a nonempty raw receipt reference. |

`provenance.source` is checked against the exact action-source mapping below: workflow-lock, endpoint, transport, persistence, recovery or clock. Receipt text alone is not an authenticity proof; preserve and review the raw receipts, completeness ledger, fault counters and backend readback. Do not mark complete when any required observer is absent.

## 2. Action-to-code mapping

All rows require the complete `post` state and provenance above, even when only a subset changes. `args` names exactly match Trace wrappers. Task parameters `t`/`w`, message `m` and reply `r` are complete records; `i` is a call ordinal, `o` an operation alias, `to` an observed clock instant. Environment rows instrument the controlled endpoint/transport scheduler around the cited interface, not a fabricated Temporal internal transition.

Source prefixes: `nx/` = `service/history/hsm/nexusoperations/`; `wf/` = `service/history/workflow/`; `hist/` = `service/history/`; `sql/` = `common/persistence/sql/`. All line numbers refer to the pinned SHA.

| Spec action = trace event | Code / interface | Trigger and capture point | args | provenance.source |
|---|---|---|---|---|
| `HandleScheduleCommand` | nx/workflow/commands.go:184-241; fixed valid command/endpoint, capacity first. | After Scheduled event application under the workflow lock; before close-transaction task generation. | `o` | `workflow-lock` |
| `HandleScheduleCommandLimit` | nx/workflow/commands.go:184-191; failure is observed, no operation is created. | Immediately when the physical collection-size admission check returns limit exceeded. | `o` | `workflow-lock` |
| `HandleCancelCommand` | nx/workflow/commands.go:259-299; buffered terminal makes a late command legal. nx/statemachine.go:428-449; missing node is ignored at commands.go:318-320. | After CancelRequested application, including missing-node/buffered-completion acceptance, and command/buffer ordering. | `o` | `workflow-lock` |
| `loadOperationArgs` | nx/executors.go:364-408; locked validated read, no Attempt increment. | At successful AccessRead return; capture request ID and initial ref before unlocking for RPC. | `t` | `workflow-lock` |
| `executeInvocationTask` | nx/executors.go:261-311; unlocked call can follow terminal local completion. | After request budget/header construction, at actual wire send; capture outgoing request independently. | `i` | `transport` |
| `executeInvocationTaskBelowMin` | nx/executors.go:287-289,554-556; no endpoint call, timeout through saveResult. | After minimum-budget branch, before saveResult; independently prove no wire send. | `i` | `workflow-lock` |
| `EndpointAccept` | S1 endpoint contract at nx/executors.go:261-268,311. Environment assumption: stable request-ID dedup, stable async token and retained response semantics. | At endpoint acceptance/dedup decision and response enqueue; effect precedes client receipt. | `m,mode` | `endpoint` |
| `EndpointStartFailure` | nx/executors.go:534-575; remote retry/refusal before acceptance is a fault. | At controlled preaccept retryable/refusal response generation; capture result classification. | `m,result` | `endpoint` |
| `ReceiveStartResponse` | nx/executors.go:311-339; receipt precedes a new write-side validation. | After client response decoding, before write-side Access and revalidation. | `m` | `transport` |
| `LoseResponse` | S1 transport fault across nx/executors.go:311,783 and callback response. | At transport hook discarding an independently recorded response. | `m` | `transport` |
| `RequestDeadlineExceeded` | nx/executors.go:256-257,557-559,726-727; request may still be accepted later. | At call context expiry while response not received; requests remain potentially deliverable. | `i` | `transport` |
| `DiscardLateResponse` | nx/executors.go:256-257,726-727; closed call context cannot receive a result. | When an expired/completed client context discards a late response. | `m` | `transport` |
| `saveStartedResult` | nx/executors.go:416-425,452-480; InvocationTask.Validate is rechecked. nx/statemachine.go:378-398; preserve the early return (B1). | After Started transition and nested child transition under AccessWrite; before task generation. | `i` | `workflow-lock` |
| `handleStartOperationErrorRetryable` | nx/executors.go:528-575; attempt increments on committed retryable failure. Shared update expression, not a transition: callers retain distinct implementation branches. | After TransitionAttemptFailed; capture incremented attempt and next schedule time. | `i` | `workflow-lock` |
| `saveResultSucceeded` | nx/executors.go:426-429; nx/completion.go:23-43; nx/events.go:164-175. | After synchronous successful event application and HSM deletion; before local commit. | `i` | `workflow-lock` |
| `handleOperationErrorFailed` | nx/executors.go:540-541; nx/completion.go:75-89; nx/events.go:193-205. | After failed event application/deletion; before local commit. | `i` | `workflow-lock` |
| `handleOperationErrorCanceled` | nx/executors.go:540-541; nx/completion.go:90-114; nx/events.go:228-242. | After canceled event application/deletion; before local commit. | `i` | `workflow-lock` |
| `handleNonRetryableStartOperationError` | nx/executors.go:542-553,578-603; nx/events.go:193-205. | After permanent-failure event/deletion; before local commit. | `i` | `workflow-lock` |
| `handleStartOperationErrorBelowMin` | nx/executors.go:554-556,645-676; preserve retained timeout node (B2). | After recordOperationTimeout direct transition; independently capture retained node. | `i` | `workflow-lock` |
| `RejectStaleCall` | hist/statemachine_environment.go:230-288; nx/executors.go:829-832 on cancel read. | After write-side ref/state rejection; record original call and task acknowledgment. | `i` | `workflow-lock` |
| `EndpointComplete` | S1 environment of nx/completion.go:181-223; cancel ACK does not determine result. | At independent endpoint terminal outcome; before any callback delivery. | `o,result` | `endpoint` |
| `SendCompletionCallback` | nx/executors.go:202-218; callback has stable initial identity, no attempt fence. | At each actual callback wire send with decoded original completion token/ref. | `o` | `transport` |
| `CompletionHandlerHandle` | nx/completion.go:199-223; callback fabricates Started before terminal processing. nx/events.go:164-175,193-205,228-242; deleted outputs filtered at close. | After optional fabricated Started and terminal event/deletion in the same AccessWrite closure. | `m` | `workflow-lock` |
| `CompletionHandlerReject` | nx/completion.go:200-217,224-250; same-run fallback can end in NotFound. | At final same-run NotFound/closed-run rejection; no successful local mutation. | `m` | `workflow-lock` |
| `loadArgsForCancelation` | nx/executors.go:823-859; child validation AND parent terminal check on read. | At successful child AccessRead and parent terminal check; capture parent token and child initial ref. | `t` | `workflow-lock` |
| `executeCancelationTask` | nx/executors.go:745-783; unlocked cancel uses the token captured by read. | At actual CancelOperation wire send with captured token and computed budget. | `i` | `transport` |
| `executeCancelationTaskBelowMin` | nx/executors.go:747-749,869-893; child fails, parent is not timed out here. | After minimum-budget branch; before saveCancelationResult; no wire send. | `i` | `workflow-lock` |
| `EndpointCancelAck` | nx/executors.go:783,902-904; accepting cancellation need not cancel the operation. | At endpoint cancellation ACK generation; capture unchanged or separately completed remote operation. | `m` | `endpoint` |
| `EndpointCancelFailure` | nx/executors.go:866-900; remote refusal/retry is independent of parent completion. | At controlled cancel refusal/retry response generation. | `m,result` | `endpoint` |
| `ReceiveCancelResponse` | nx/executors.go:783-801; saveCancelationResult will reacquire the lock. | After cancel client response decoding; before saveCancelationResult. | `m` | `transport` |
| `saveCancelationResultAck` | nx/executors.go:864-865,902-921; revalidate child, ACK event flag is enabled. No parent terminal guard is invented for the WRITE: timeout can retain child. | After child Succeeded and optional ACK event, before local commit; parent may remain running/terminal. | `i` | `workflow-lock` |
| `saveCancelationResultFailed` | nx/executors.go:869-893; permanent failure produces an ACK-failure history event. | After child Failed and failure event, before local commit. | `i` | `workflow-lock` |
| `saveCancelationResultRetryable` | nx/executors.go:895-900; nx/statemachine.go:626-637. | After child BackingOff and attempt/deadline update, before local commit. | `i` | `workflow-lock` |
| `executeStateMachineTimerTask` | hist/timer_queue_active_task_executor.go:861-891; lock covers the whole batch. | After acquiring workflow lock/loading current groups, before the first logical timer. | `w` | `workflow-lock` |
| `executeBackoffTask` | nx/executors.go:606-611; timer batch does not publish new invocation yet. | After one logical Backoff transition/removal under the batch lock; capture deferred output. | `t` | `workflow-lock` |
| `executeCancelationBackoffTask` | nx/executors.go:926-931; parent terminal status is not a child validator fence. | After one logical child Backoff transition/removal; parent terminal guard is not added. | `t` | `workflow-lock` |
| `executeOperationTimeout` | nx/executors.go:614-676; typed S2C/S2S/STC validators are in Eligible. No DeleteChild at executors.go:673-676: retained node reproduces B2. | After typed logical timeout transition/removal; direct executor retains node. | `t` | `workflow-lock` |
| `SkipStaleTimer` | hist/timer_queue_task_executor_base.go:317-340; stale ref/closed run skipped. | After skipping one invalid logical task inside the current due group. | `t` | `workflow-lock` |
| `FinishStateMachineTimers` | hist/timer_queue_task_executor_base.go:343-347; end batch before one commit. | After all due logical groups are processed; no-work path returns without a write. | `(none)` | `workflow-lock` |
| `GenerateDirtySubStateMachineTasks` | wf/task_generator.go:297-333,976-1002; filter outputs against FINAL node state. wf/state_machine_timers.go:18-40,47-69: publish only unscheduled first group. | After final-state output filtering, deletion trimming and first-unscheduled-group wake creation. | `(none)` | `workflow-lock` |
| `AppendHistoryNodes` | sql/execution.go:338-348; raw append is outside the mutable-state transaction. | After the SQL history-append loops, before atomic mutable-state update; capture raw append or no-append. | `(none)` | `persistence` |
| `UpdateWorkflowExecution` | sql/execution.go:350-357; sql/execution_util.go:44-82,155-175,629-664. Atomic d/timer/buffer/task publication; error receipt is NOT a noncommit oracle. | At actual SQL transaction outcome; attach independent commit/readback evidence and error receipt classification. | `outcome` | `persistence` |
| `ConditionalWriteRejected` | sql/execution_util.go:629-664; shard range and DB-record checks reject old writers. | At RangeID/DBRecordVersion conditional rejection before any mutable-state commit. | `(none)` | `persistence` |
| `NotifyOnExecutionMutation` | wf/transaction_impl.go:201-206; notifications can accompany a noncommitted unknown. | At the possibly-succeeded notification branch, before caller-visible Access return. | `(none)` | `persistence` |
| `AccessReturn` | hist/statemachine_environment.go:380-410; nx/completion.go:249-255. hist/shard/context_impl.go:1530-1548; uncertain writes require reacquisition. | After cache-release/write-error handling and task result or callback response production. | `(none)` | `persistence` |
| `ReceiveCompletionReply` | nx/completion.go:249-255; independent caller receipt, not just server return. | At actual callback caller receipt; distinguish Accepted from Error/NotFound. | `r` | `transport` |
| `LoseCompletionReply` | S1/S5 transport loss after CompletionHandler.Handle returned. | At controlled loss of an independently recorded callback server response. | `r` | `transport` |
| `CacheLoss` | hist/statemachine_environment.go:203-219; ordinary eviction changes no DB fields. | After actual workflow-context eviction, with independent durable state retained. | `(none)` | `recovery` |
| `LoseShard` | hist/shard/context_impl.go:1534-1547; ownership can change with a write in flight. | At shard ownership/lost transition, including an in-flight local write if injected. | `(none)` | `recovery` |
| `ReacquireShard` | hist/shard/context_impl.go:1541-1547; new RangeID fences the previous writer. | After successful new RangeID acquisition/fencing, before DB readback. | `(none)` | `recovery` |
| `LoadMutableState` | hist/statemachine_environment.go:186-219; sql/execution.go:295-330. | After GetWorkflowExecution/task readback populates the cache; do not call refresh. | `(none)` | `recovery` |
| `RefreshWorkflowTasks` | wf/task_refresher.go:64-72,699-730; explicit refresh, NOT LoadMutableState. | After explicit full refresh updates generation and derives uncommitted tasks; before publication. | `(none)` | `recovery` |
| `DropStaleOutboundTask` | hist/ndc_task_util.go:242-253 and nx/executors.go:829-832. | At task rejection for ref/state/generation or terminal parent on cancel read. | `t` | `recovery` |
| `DropStaleWake` | hist/ndc_task_util.go:242-253; old physical wake does not resurrect logical tasks. | At outer old-generation physical timer rejection. | `w` | `recovery` |
| `DuplicateOutboundTask` | S4 queue redelivery after uncertain acknowledgment; payload/identity unchanged. | At an observed extra delivery ticket for an already published outbound task. | `t` | `recovery` |
| `StartWorkflowTask` | wf/workflow_task_state_machine.go:453-479; one in-flight normal WFT. Signal/request plus WFT-start metadata is projected to this locked boundary. | After normal WFT start mutation; retain in-flight status through commit. | `(none)` | `workflow-lock` |
| `CompleteWorkflowTask` | wf/workflow_task_state_machine.go:761-772,1322-1324; hist/historybuilder/event_store.go:178-197 appends buffer after commands. | After WFT deletion and buffered-history flush; before history append/commit. | `(none)` | `workflow-lock` |
| `CloseWorkflowExecution` | hsm/tree.go:495-512 guards subsequent Nexus work; no cross-run recovery here. hist/api/respondworkflowtaskcompleted/workflow_task_completed_handler.go:803-805: no unhandled buffer. | After permitted close mutation with no unhandled buffer; late outbound/callbacks remain observable. | `(none)` | `workflow-lock` |
| `AdvanceTime` | S2/S4 environment clock for nx/executors.go:228,231,719,723 and timer queues. | Record the next monotonic normalized clock instant before a time-dependent observed boundary. | `to` | `clock` |

## 3. Special considerations and required harness checks

1. Preserve one event per listed action. Timer inner transitions run under the same held workflow lock, so their microevents must be emitted before that lock is released; remote and clock events may interleave, other local transactions may not. Completion fabrication plus terminal application is intentionally one locked mutation because the brief requires their transaction grouping. Every wrapper invokes the full base action. There are no silent state-changing actions.
2. Separate observation from commitment. Attach an actual transaction result and raw error type; a metric or a notification cannot determine commitment. `ExecuteAndTimeout` must log that the underlying write ran, preserve the injected returned error, reacquire the shard and perform readback. A definite-failure control must show unchanged durable HSM/history-buffer/tasks. Retain raw history append receipts even for the definite-failure path.
3. Queue projection includes local delivery/ack ownership, not simply rows physically awaiting range cleanup. Keep raw queue rows, task IDs, reader ownership and local in-flight copies in the sidecar. Report how this projection is derived. Capture logical timer `Scheduled` flags and physical wakeups independently. Never synthesize missing STC from RegenerateTasks during ordinary reload.
4. Retry calls use stable operation RequestId and independent call ordinals. A cancel child has its own initial HSM identity and attempt counter. An outbound serialized Attempt may be older than the current HSM Attempt and still execute in Scheduled state. A callback comes from the original start ref, has no outbound task-generation watermark, and has no attempt fence.
5. Record workflow lock ordering, endpoint ordering and persistence ordering in a global causal join. Block at controlled schedule points when total ordering cannot otherwise be established; do not arbitrarily reorder overlapping observations to force acceptance. Preserve all raw records and endpoint completeness counts. If any mandatory field is inaccessible, investigate and add a hook; do not remove its check or fill it from model state.
6. Reuse `tests/nexus_api_test.go` and the brief's retained probe fixture for healthy async completion, early callback, duplicate/late callback, synchronous sequential-capacity control, deferred-cancel/ACK missing-timer path, ordinary timeout/capacity path, explicit refresh repair, and database/shard readback. Then add accepted-start response loss, definite noncommit and ExecuteAndTimeout schedules. This document does not claim these new schedules have run.
7. Required negative controls: alter the independently observed wire RequestId/initial ref; remove an independently observed persisted logical timer from the trace; label a definite noncommit callback as caller-observed Accepted; mismatch the actual queue/DB evidence against `post`; remove an event or leave a nonmatching suffix; reject an empty file. Real B1 absence must still replay. A trace-matching result and a separately run hunt-oracle result are different facts.
8. Time mapping must preserve timestamp ordering, deadline equality, budget minimum comparisons and actual retry deadlines. The fixed RetryDelay abstraction is for schedules whose chosen retry gaps can use one unit; a trace exercising increasing backoff beyond this abstraction needs a source-backed delay function extension, not altered observations. Trace configuration has no MC time bound and clock jumps avoid per-unit synthetic ticks.
9. Model boundaries remain explicit: no standalone CHASM operations, reset/run-ID fallback into another run, Continue-As-New, XDC, endpoint administration, partial refresh, full history reconstruction, speculative WFT or arbitrary closure with unhandled buffers. B3/TV/CR findings stay in their direct testing/review handoff.

Example invocation from this directory using the verified installed tool paths:

```bash
JSON=../traces/trace.ndjson timeout 30m java -Xmx2g \
  -cp /home/ubuntu/Specula/tools/tlaplus/tlatools/org.lamport.tlatools/dist/tla2tools.jar:/home/ubuntu/Specula/tools/tlaplus/tlatools/org.lamport.tlatools/lib/CommunityModules.jar \
  tlc2.TLC -workers 1 -config Trace.cfg -metadir checks/states-trace -noGenerateSpecTE Trace
```

A missing trace file is a missing harness input, not a successful validation. `Trace.cfg` unconditionally enables `PROPERTIES TraceMatched`.
