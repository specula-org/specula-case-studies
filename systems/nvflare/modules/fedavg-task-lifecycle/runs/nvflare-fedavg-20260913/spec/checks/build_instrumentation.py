from pathlib import Path
import json,re
D=Path(__file__).resolve().parent.parent
actions=json.loads((D/'checks/action-map.json').read_text())
base=(D/'base.tla').read_text()
hooks={
'FedAvgRoundStarted':'After CURRENT_ROUND assignment and ROUND_STARTED at fedavg.py:189-195, before helper reset.',
'FedAvgResetAggregation':'After helper reset and _site_metric_weights={} at fedavg.py:205-212.',
'WFCommScheduleTask':'After _tasks.append(task) at wf_comm_server.py:574; record prepared task data version from _build_shareable.',
'WFCommProcessTaskRequest':'After selecting the new ClientTask and entering task.cb_lock, before before_task_sent_cb at :277-283.',
'WFCommResendTask':'Same boundary as initial request, after resend_task selects the existing ClientTask at :234-241.',
'BasePrepareTaskData':'After _prepare_task_data/BEFORE_TRAIN_TASK returns normally at base_model_controller.py:225-228.',
'BasePrepareTaskDataFailure':'After before_task_sent_cb exception sets ERROR at wf_comm_server.py:292-293; before deepcopy.',
'WFCommProtectBroadcast':'After first deepcopy assignment at :314, or after reusing existing _broadcast_data at :324.',
'WFCommProtectBroadcastFailure':'After failed deepcopy sets ERROR/can_send_task=False at :321-323.',
'WFCommCheckCanSend':'After final status check :340-345 and before _task_lock publication at :349.',
'WFCommPublishClientTask':'After task/client-map registration and per-client header/cookie construction :349-370 and server_runner.py:411-421, as communicator/wf_lock return to outer filtering.',
'WFCommTaskTryAgain':'At the preparation failure return :344-345, after the surrounding callback/controller/runner locks unwind.',
'ServerRunnerFilterTask':'After successful apply_filters and return envelope at server_runner.py:358-371; do not claim client delivery yet.',
'ServerRunnerFilterFailure':'At entry to the filter exception handler :344, before reacquiring wf_lock at :350.',
'WFCommHandleException':'After handle_exception/cancel_task returns and TRY_AGAIN is chosen at server_runner.py:350-356; capture whether mapping existed.',
'ClientReceiveTask':'After assignment payload delivery/decode and before executor processing starts; use task identity restored through client_runner.py:225-234.',
'TaskDeliveryFailure':'At the transport adapter return indicating no usable decoded assignment, before a subsequent task-retrieval retry.',
'ClientProcessTask':'After supported executor returns and _process_task restores cookie/task name/ID at client_runner.py:228-234; before task-check.',
'ClientExecutionError':'After _do_process_task exception creates EXECUTION_EXCEPTION at :246-248 and _process_task restores original identity.',
'ClientCheckTask':'After server task-map lookup decides OK/TASK_UNKNOWN at server_runner.py:599-605; mark the corresponding attempt checked before actual send.',
'ClientRetryResult':'On the next _send_task_result retry after a lost/failed reply at client_runner.py:606-608, allocating the next attempt number.',
'ServerRunnerProcessSubmission':'After outer wf_lock admission check at server_runner.py:463-471; retain this lock for accepted admission.',
'WFCommDispatchSubmission':'After live/completed lookup and owner/name/status/receipt guards at wf_comm_server.py:448-499, before callback.',
'BaseAcceptTrainResult':'After _accept_train_result returns and synchronous panic/event processing completes at base_model_controller.py:270,338-365.',
'BaseConvertResult':'After from_shareable and meta augmentation succeed at :273-275, immediately before invoking consumer.',
'BaseConvertResultFailure':'At conversion exception catch :276-277 before acceptance publication; record actual exception type, but diagnostic details go outside the trace tag.',
'FedAvgAggregateOneResult':'After empty-parameter decision :270-273; otherwise immediately before parameter helper add :299.',
'WeightedAddParamStats':'Immediately after key_contribution_counts[k] increments at weighted_aggregation_helper.py:168, before materialize().',
'WeightedAddParamValue':'After a successful parameter total and counts update :177-216 for this key, before the next key/history.',
'WeightedParamFailure':'At ordinary materialization/arithmetic exception escaping this key and caught at base_model_controller.py:285-286; preserve successful earlier updates.',
'WeightedAddParamHistory':'Immediately after parameter history.append completes at weighted_aggregation_helper.py:218-224 and helper lock releases.',
'FedAvgProcessMetrics':'After result.metrics/all_metrics/filter decision at fedavg.py:310-320, before metric helper entry or count increment.',
'FedAvgMetricPreparationFailure':'At metric-filter allocation exception, after completed parameter add and before _received_count; follow actual caught exception at base_model_controller.py:285-286.',
'WeightedAddMetricStats':'After metric helper key_contribution_counts increments at weighted_aggregation_helper.py:168.',
'WeightedAddMetricValue':'After metric helper total/counts update at :177-216.',
'WeightedMetricFailure':'At ordinary metric arithmetic allocation exception before this metric total is updated; parameter state remains observable.',
'WeightedAddMetricHistory':'After metric helper history.append completes at :218-224.',
'FedAvgIncrementReceived':'After _received_count+=1 and successful True return at fedavg.py:328-330.',
'BasePublishAcceptance':'After AGGREGATION_ACCEPTED is set at base_model_controller.py:290 and AFTER_CONTRIBUTION_ACCEPT is published at :291; no inference from receipt.',
'BaseClearTrainingResult':'After finally clears TRAINING_RESULT and client_task.result at :292-294.',
'WFCommStampReceipt':'Observe result_received_time assignment at wf_comm_server.py:521; emit completed-step state as callback/controller/runner contexts unwind, before dispatch ACK.',
'BaseProcessUnknownResult':'After process_result_of_unknown_task and preliminary acceptance return at base_model_controller.py:298-365; assert no consumer hook ran.',
'WFCommDropSubmission':'As the no-consumer/drop branch returns from communicator/runner; release held locks before ACK at server_command_agent.py:96-110.',
'ServerCommandDispatchAck':'When client_run_manager observes Cell OK (client_run_manager.py:145-151); correlate command completion, not AGGREGATION_ACCEPTED.',
'ClientLoseDispatchAck':'When the client observes timeout/error after a known server-side handled attempt; do not infer that server receipt was rolled back.',
'WFCommCancelTask':'Immediately after direct cancel_task writes completion_status at wf_comm_server.py:812; no communicator/callback lock acquired.',
'WFCommReportDeadClient':'After first process_dead_client_report inserts _DeadClientStatus at :181-186.',
'WFCommClientIsActive':'After a standalone heartbeat/activity removes the watch-list entry at :1250-1259.',
'ClockAdvance':'After FakeClock advances one 30-second grid tick; record saturating elapsed thresholds for reports/tasks. Do not silently drop a relevant tick.',
'WFCommMonitorBegin':'Capture local now at _check_dead_clients :1028, then observation-loop membership while holding _dead_clients_lock :1029.',
'WFCommCheckDeadClient':'After each disconnect check/assignment at :1030-1044, using the captured now, not a new per-client clock read.',
'WFCommDeadCheckDone':'After dead-client lock releases and before _job_policy_violated reads clients at :1218-1223.',
'WFCommReadPolicyClient':'Immediately after each disconnect-time read populates alive/dead local lists at :1223-1227.',
'WFCommJobPolicyDecision':'After policy return :1229-1248 and, on failure, synchronous system_panic at :1055-1057; record monitor stop.',
'WFCommMonitorAcquire':'After check_tasks acquires _controller_lock and _task_lock at :1061,1066.',
'WFCommMonitorSelect':'After inspecting terminal status/manager result and lead-time eligibility at :1067-1093, before terminal write/removal or per-target dead scan.',
'WFCommReadTaskDeadClient':'After each outstanding-target disconnect read at :1170-1185; a live target immediately ends the scan.',
'WFCommTaskDeadCheckDone':'At _get_task_dead_clients return, before CLIENT_DEAD assignment :1094-1097 or no-exit return.',
'WFCommMonitorMarkTerminal':'Immediately after completion_status becomes OK or CLIENT_DEAD at :1082 or :1096, before removal.',
'WFCommMonitorRemove':'After is_standing=False, _tasks removal, received-only LRU insertions and client-task-map removals :1101-1109; before exit callback/cleanup.',
'WFCommMonitorCleanup':'After _broadcast_data deletion at :1153-1155 and communicator lock release. No task_done_cb is installed for this FedAvg nonblocking task.',
'WFCommMonitorNoTask':'At empty-task-list return from _do_check_tasks :1113-1114, releasing communicator lock.',
'FedAvgPollStanding':'Immediately after get_num_standing_tasks returns at fedavg.py:224, before the conditional abort read or BEFORE_AGGREGATION.',
'FedAvgPollAbort':'Immediately after abort_signal.triggered is read at fedavg.py:225; if true, record return at :227.',
'FedAvgGetAggregationStats':'After get_aggregation_stats obtains its own helper lock and returns :346; copy actual stats/history before reset.',
'WeightedGetParamResult':'After parameter get_result captures totals and resets helper at weighted_aggregation_helper.py:226-240.',
'WeightedGetMetricResult':'After conditional metric get_result at fedavg.py:352; if _all_metrics=False capture skip with output None and retained helper state.',
'FedAvgBuildAggregateResult':'After FLModel construction/metadata at fedavg.py:355-365, before update_model.',
'BaseFedAvgUpdateModel':'After actual GLOBAL_MODEL assignment/update_model at base_fedavg.py:314-322; record source version and used provenance.',
'FedAvgSaveModel':'After successful configured persistor/file save returns at fedavg.py:497-504 or base_model_controller.py:445-446.',
'FedAvgAdvanceRound':'After end-of-round cleanup/loop decision at fedavg.py:261-266; next ROUND_STARTED is another event.',
'ServerRunnerCloseWorkflow':'After current_wf=None at server_runner.py:160-166, before communicator finalization.',
'WFCommFinalizeRun':'After synchronous clearing/resource release and _all_done=True at wf_comm_server.py:892-895.',
'ServerRunnerTaskRequestActive':'After request-specific _report_client_active("getTask") at server_runner.py:298, before later wf_lock acquisition :385.',
'ServerRunnerAcquireTaskRequest':'After wf_lock acquisition at server_runner.py:385, before waiting for communicator lock :392.',
'WFCommTaskUnavailable':'At TRY_AGAIN/no-workflow return from server_runner.py:386-388 or wf_comm_server.py:270-272, releasing runner lock.',
'ServerRunnerCheckTaskActive':'After task-check-specific _report_client_active at server_runner.py:586, before later mapping lookup lock.',
'ServerRunnerSubmissionActive':'After submission-specific _report_client_active at server_runner.py:475, retaining outer wf_lock.',
'WFCommAcquireSubmission':'After communicator lock acquisition at wf_comm_server.py:434, before dispatch lookup.',
'ServerRunnerDropClosedSubmission':'At outer runner rejection return at server_runner.py:464-470, before command-agent transport ACK.',
}
assert set(hooks)=={a['name'] for a in actions}
text='''# Instrumentation specification: nvflare-fedavg

Source: `/home/ubuntu/nvflare-runs-20260913/source-fedavg`, commit `53ba7ee567468ea7971dad4faccef13c6cb35dc2`. Category A; a controlled local functional harness must produce a single ordered NDJSON stream. This is a mapping/handoff, not implemented instrumentation or executed trace conformance.

## 1. Trace event schema

Write one metadata record, then one record per modeled action. Default location is **`../traces/trace.ndjson` relative to spec/**; `JSON` selects another file via `IOEnv.JSON`. Do not put ordinary implementation traces in spec/. `Trace.cfg` derives all configuration constants from metadata; do not edit TLA constants to disguise a configuration mismatch.

Metadata shape (all fields required):

```json
{"tag":"specula-meta","schema":1,"sourceHead":"53ba7ee567468ea7971dad4faccef13c6cb35dc2","origin":"implementation","config":{"Clients":["c1","c2"],"Selected":["c1","c2"],"NumRounds":2,"NumKeys":2,"HistoryLimit":4,"ErrorMode":"dynamic","OutboundFilter":false,"LazyOffload":false,"AllocationFailure":false,"ConversionFailure":false,"BeforeSendFailure":false,"AllowEmpty":true,"MetricKinds":["present"],"MinSites":2,"RequiredSites":[],"AllowPartialCompletion":false},"initial":"REPLACE WITH THE COMPLETE INITIAL STATE OBJECT"}
```

The string placeholder above is explanatory and must never be emitted. `initial` is the complete normalized `s` object matching base `Init`, captured after controller/communicator initialization but before the first ROUND_STARTED. Record actual job/persistor/format/offload settings separately as provenance evidence, including no early stop and successful save destination. `HistoryLimit` must match the harness's actual cache capacity: use 10000 for an unmodified communicator, or explicitly document any reduced-capacity fixture. `origin="synthetic-test"` is reserved for parser/replay controls and is not implementation evidence.

Each action event has exactly these fields:

```json
{"tag":"trace","event":{"name":"WeightedAddParamValue","nid":"server","args":[],"seq":17,"state":"REPLACE WITH COMPLETE POST-STATE OBJECT"}}
```

`seq` is 1-based and contiguous over trace-tagged events. `args` is an ordered array matching the table below. `nid` is server, clock, transport or the normalized client ID as specified. Every `state` is a **complete immutable post-state**, not a delta. Other diagnostic logs may use another tag; malformed or unknown trace-tagged records must remain visible and fail replay. Do not include diagnostic timestamps/exception messages as unchecked fields in the event object.

Normalization:

- Each workflow task index `t=1..NumRounds` corresponds to actual `current_round=t-1`; register each actual ClientTask UUID injectively as `[t,clientName]`. Task UUID and parent broadcast identity are distinct. `NoId=[0,""]`; per-client headers include the normalized ID and actual normalized round. Preserve task name `train`, workflow cookie and client ownership in the normalizer and reject inconsistent mappings. No forged/rewritten identity is in scope.
- JSON arrays encode TLA sequences and numeric-domain functions. Thus `task`, `ct`, `net`, `used`, `aggr.applied`, `aggr.stats` and `scratch.params/stats` are arrays indexed by `t-1` or `key-1` in Python, but by `t`/`key` in TLA. Client-domain functions are JSON objects keyed by actual client strings.
- Set fields are duplicate-free arrays: `wf.started`, `requested`, `committed`, `saved`, `unknownSeen`, `aggr.failedClients`, `comm.pending/deadView`, `mon.pending/deadView`, and each `task[t].retiredOutstanding`. `Trace.DecodeState` converts exactly these fields. Histories, applied-provenance lists, assignment order and completed LRU remain **ordered sequences with multiplicity**.
- The snapshot record's complete field layout is defined by base `Init`, `EmptyTask`, `EmptyClient`, `EmptyComm`, `EmptyRunner`, `EmptyAggregate` and `EmptyUsed`. No field is optional. `TraceStateShape` validates set encoding and task-array lengths; `ValidatePostState` checks `s' = DecodeState(event.state)`. Captured unchanged fields are checked too.

| State group | Implementation observation / shadow source |
|---|---|
| `wf.round,pc,started` | FedAvg current_round plus boundary PCs/events at :186-266. `pc` is the next modeled statement, not a production variable. |
| `wf.abort,outcome,open` | Actual shared abort signal, normal Finished FedAvg vs abort return, and runner current_wf/status. Normal controller return and run abort remain distinct. |
| `wf.sourceVersion` | Incremented observation label only when actual update_model exposes GLOBAL_MODEL; capture input/output object identity/hash evidence independently of the label. |
| `task[t]` | schedule/is_standing/status, task list membership, task.data version, protected `_broadcast_data`, ordered client_tasks and elapsed lead threshold. `retiredStatus/retiredOutstanding` snapshot the removal boundary; retain these ghosts even if task references are released. `cleaned` records `_broadcast_data`/finalization cleanup. |
| `ct[t][c]` | Actual assignment, task ID/round headers and protected input version; payload-delivery adapter stage; decoded result kind/metric presence; result_received_time; AGGREGATION_ACCEPTED; consumer invocation count. Never set receipt from ACK. Never infer accepted from a success return code. |
| `net[t][c]` | Per-attempt correlated task-check, queued send, handled server dispatch, delivered ACK, observed ACK loss or task-gone result. Attempt numbers start at 1; retries retain the ClientTask ID. A server-handled attempt can have lost ACK. |
| `runner` | Shadow ownership/PC of real wf_lock, including waiting for communicator; `client`, `id`, `attempt` identify the admitted operation. Map reentrant wf_lock nesting to one owner, not separate threads. |
| `comm` | Shadow ownership/PC of _controller_lock and relevant task/callback/helper scopes; active ID/attempt/key, local accepted boolean, monitor's cached exit/pending/deadView. Read real local branch outcomes. |
| `requested` | Request-specific activity has run, but the subsequent get-task wf_lock acquisition has not occurred. This models the actual caller gap. |
| `aggr.applied,stats` | Shadow ordered contributor IDs per successful parameter key update and per key_contribution_counts increment respectively; instrument BEFORE materialization and AFTER successful total/count update separately. Compare shadow multiplicities with actual counts/stats. |
| `aggr.paramHistory,metricHistory,metricStats,metricApplied` | Actual helper history/contribution-count observations plus successful per-key metric provenance. Helper history append occurs after the key loop. Do not reconstruct a complete history for a callback that threw midway. |
| `aggr.receivedCount,counted,failedClients,allMetrics,task` | Actual FedAvg _received_count, successful callback-return IDs, dynamic _current_failed_clients, _all_metrics, and helper owning round. Counted IDs are an observation ledger for the actual increment site. |
| `scratch` | Actual final aggregate's captured stats, parameter/metric provenance, histories and nr_aggregated metadata. Preserve snapshot before helper get_result resets its state. |
| `used[t],committed,saved` | Actual update_model/global-model exposure and successful save callback/file observation. Carry captured aggregate provenance into the actual exposed model; do not fill this from a desired acceptance policy. |
| `completed` | Actual ordered completed-client-task LRU, received entries only, insertion/eviction and lookup touch order. Read before/after removal and after finalize clear. |
| `unknownSeen` | Ledger of actual unknown train-result callback invocations; do not invoke FedAvg consumer to construct it. Diagnostic TRAINING_RESULT retention is outside modeled state. |
| `dead[c]` | Actual watch-list presence, elapsed grace class and disconnect_time. Requests, task-checks, submissions and heartbeat recovery must clear it at their real activity hooks. |
| `mon` | Actual monitor stage, pending local iteration items and cached per-client job-policy reads. `reportAges` captures the single now value used by `_check_dead_clients`; time may advance while it is scanning. |

Every action below captures all groups. The “changed groups” column identifies fields that must be freshly captured at that boundary, not permission to omit the rest. For actual mutable values, copy under the appropriate existing lock or controlled scheduler pause. Ghost ledgers derive only from observed successful mutations/returns and known pre-state; never call the TLA transition to manufacture the expected snapshot.

## 2. Action-to-code mapping

The trace event name is exactly the base action name. Each has one `Trace_<name>` wrapper calling the complete base action and validating the entire post-state. Parameterless internal actions use the captured active ID/key in `comm`; do not merge their events into one callback-end record.

| Spec action / event (`args` order) | Node | Source location | Exact capture boundary | Changed groups |
|---|---|---|---|---|
'''
for a in actions:
 name=a['name'];pattern=r'^'+re.escape(name)+r'(?:\([^\n]*\))? ==\n(.*?)(?=\n\\\*|\n[A-Z][A-Za-z_]* ==|\Z)'
 m=re.search(pattern,base,re.M|re.S)
 assert m,name
 groups=sorted(set(re.findall(r'!\.(wf|task|ct|net|comm|aggr|scratch|used|committed|saved|completed|unknownSeen|dead|mon|runner|requested)\b',m.group(1))))
 args=', '.join(a['args']) or '[]'
 node=a['traceNode'].replace('logline.args[1][2]','id[2]').replace('"','')
 text+='| `'+name+'` ('+args+') | `'+node+'` | '+a['source']+' | '+hooks[name]+' | '+', '.join('`'+g+'`' for g in groups)+' |\n'
text+='''
## 3. Special considerations

**Ordering and concurrency.** Use a controlled functional scheduler with gates at the listed boundaries and serialize immutable trace records through a short observer lock. The scheduler must preserve actual communicator, runner, callback, helper and dead-client locks, including waits; never release a real lock early to obtain a desired trace. Keep the observer lock out of blocking protocol calls and do not hold it across multiple model steps. A shadow-state ledger and sequence-number assignment must correspond to the same selected interleaving as the actual mutations. Sampling unrelated live objects opportunistically is not a coherent full snapshot. These traces establish the scheduled local executions only, not every production interleaving. If a boundary cannot be instrumented coherently, report a gap; do not replace its wrapper with a silent state repair or remove a field check.

**Cancellation.** Direct cancel writes status without rollback. A previously admitted callback may continue. Filter failure itself is outside runner wf_lock, but handle_exception reacquires that lock. Both callback/controller and caller wf_lock release are reflected when the submission returns; receipt is recorded after the callback. Monitor removal precedes cleanup, allowing the FedAvg thread to observe queue emptiness before cleanup, but communicator serialization prevents a live old aggregation callback after normal next-round reset.

**Task requests.** Trace only lifecycle-relevant polling attempts as `ServerRunnerTaskRequestActive`; idle polls with no state change are ordinary non-trace logs. `ServerRunnerAcquireTaskRequest` records the real second wf_lock acquisition. Task unavailable after that wait has its own explicit action. Per-client overlapping filter requests, duplicated retraining while a previous client execution is active, and arbitrary custom workflows are excluded; use ordinary one-task-at-a-time clients.

**Errors and supported payloads.** Ordinary executor error codes, valid empty params, failed conversion before consumer entry, lazy materialization failure and metric allocation failure are different paths. Use benign data. Do not substitute an arbitrary consumer or malformed payload to pretend to reproduce MC-1. LazyOffload requires enabled tensor disk offload, streamed PyTorch exchange and an active Cell; no conventional receiving content filter is modeled for that variant. AllocationFailure enables only the named pre-value/metric-preparation boundaries, not arbitrary partial native arithmetic corruption. The model does not explore aggregate-result construction, update or save failures: capture successful interfaces for the specified completion-observation tests.

**Payload transport.** “wire” means a published filtered envelope, “ready” means that client actually has a decoded assignment. A well-formed server-dispatch event presupposes decoded result availability but does not promise that every lazy tensor has materialized. Transport OK follows dispatch including drops. ACK loss can lead to an ordinary re-check/retry; retry and resend reactions have no independent budget in MC, because their introducing loss actions are bounded. Pre-dispatch streamed decode failure that terminates the job process, chunk completion, transport abort latency and durable recovery remain outside this model.

**Scope of accounting.** Use two ordered, nonexcluded parameter keys and one aggregatable metric with positive symbolic unit weights; uniform FULL results. Missing metrics disables output, empty metrics skips it, empty params returns False. Track applied-key provenance as ordered IDs so repeated additions cannot disappear into a set. Successful `get_result` resets helper totals/stats/history; copy needed evidence before reset. A save event requires actual configured persistor/file save success; a log saying no persistor was configured is not a save event.

**Finite history and time.** Keep the real default history bound 10000 for unmodified source traces. An explicitly reduced test fixture must publish its actual bound; never claim testing 10000 through capacity 1. Use FakeClock and 30-second grid advances for this suite, with lead threshold one tick and report grace two ticks. Do not equate a report with disconnection or a task-death decision with job-policy panic. Policy scans read clients separately, and the dead-client check uses its captured now value.

**Bootstrap and terminal traces.** Start before the first ROUND_STARTED with the complete base initial image. Preexisting controller rounds, previous workflows, variable selected cohorts, nonzero start_round and partially initialized traces need an explicit suite extension rather than an Init shortcut. No silent actions are provided. Traces may end at any captured boundary, but full lifecycle scenarios should include retirement/update/save/next-round or abort/finalization as appropriate. `TraceMatched` is enabled and fair cursor progression prevents stuttering from being mistaken for full consumption.

**Coverage handoff.** Collect a success control, staggered first/second retrieval, empty/absent-metric control, lost-ACK live/retired retry, pre-consumer conversion failure, the two independent MC-1 failure windows, primary MC-2 accepted-then-filter-failure path, admitted-callback direct cancellation, before-send ERROR, default dynamic error panic, explicit resilient rejection, and dead-policy permitted/panic variants. Keep functional runtime evidence, trace conformance and semantic hunting results separate. `brief-coverage.md` records cfg reachability and contract questions; it is not a bug-confirmation report.
'''
(D/'instrumentation-spec.md').write_text(text)
print('Wrote instrumentation-spec.md with',len(actions),'precise action mappings')
