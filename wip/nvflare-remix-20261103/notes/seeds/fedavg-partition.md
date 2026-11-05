# FedAvg seed: action-group partition (Remix ports)

Input: `inputs/seeds/fedavg/spec/base.tla` (one record `VARIABLE s`, 96 actions), MC/Update/Campaigns, Trace, handoff, `VSFedAvgInterface`, `VSComposition`, `FedAvgRefinement`. NVFlare pin `c411a201`. Analysis only; nothing was model-checked here. Machine-readable twin: `fedavg-partition.json` (actions[], fields{}, crossAccesses[], groups{}, wire[], environment[], properties[], mechanisms[], hardProblems[]).

Method: actions = top-level operators priming `s` (96, identical to `checks/action-map.json`). Reads/writes were extracted by a scanner over `s.<path>`, `EXCEPT` clauses (nested rewrites refined to sub-fields, identity copies dropped) and helper operators (`CT`, `LiveMap`, `KnownAssignment`, `HistoryAfterLookup`, `Outstanding`, `ClientCanPoll`, `Remember*`, `RunnerLockFree`, `Disconnected`, `AcceptedIds`, `HasAggregate`) expanded to field reads. Groups, processes, mechanisms and access classes are manual. Field classes are computed "as-is" on the seed encoding (before any re-encoding); `Proposed owner` is the owner after the split.

## Result in one paragraph

Three groups plus ENV: **FED_CTRL** (40 actions: controller thread + the application result-callback body including FedAvg consumer and weighted helpers), **FED_COMM** (48: WFComm + ServerRunner request/submission paths, monitor, dead-client watch, close/finalize), **FED_CLIENT** (6: CJ client runner), ENV (2: clock, assignment loss). 11 of 88 fields are multi-writer conflicts as encoded; 7 of them are real cut problems (`net[t][c][n].stage/outcome/receipt`, `ct[t][c].delivery`, `comm.pc`, `wf.pc`, `wf.abort`), the rest are benign (`comm.key/accepted` frame reset, `task.status` mark-only cancel, `dead.age` clock). 34 cross-process accesses: 23 real message/content, 7 shortcut/oracle, 4 clock. Worst oracle: `WFCommResendTask`/`WFCommTaskUnavailable` read the CJ's `ct.result` and the network-only `delivery="failed"`.

## Counts

| Item | Value |
|---|---|
| Actions (top-level operators priming `s`) | 96 |
| FED_CTRL actions | 40 |
| FED_COMM actions | 48 |
| FED_CLIENT actions | 6 |
| ENV actions | 2 |
| Fields (2nd level) | 88 |
| Fields `private` | 66 |
| Fields `port` | 11 |
| Fields `conflict` | 11 |
| Fields `constant-or-unused` | 0 |
| Cross-group accesses (vs proposed owner) | 130 |
| ...of which cross-process | 34 (a=23, b=7, c=4) |

## Proposed groups

| Group | Proc | Actions | Contents | Why this boundary |
|---|---|---|---|---|
| FED_CTRL | SJ | 40 | 13 controller-round, 4 aggregate build, 6 result-callback (`Base*`), 17 FedAvg/helper callback steps | The per-round guard `aggr.locked/failed/closed` is shared by the callback body and `FedAvgCloseRound`/`PollFailed`; partial helper mutation, shape prevalidation, zero-accepted and close-before-publish are the most bug-prone FedAvg mechanisms (#5293/#5357, Phase-1 Scenario 4). Keeping callback + round loop together keeps that lock private. |
| FED_COMM | SJ | 48 | 17 assignment path (incl. schedule rendezvous, direct cancel), 12 submission path, 17 monitor/dead-client, 2 teardown | Runner `wf_lock`, communicator `_controller_lock` (`s.comm`), task table and retired history are shared by request, submission, monitor and finalize; claim->dispatch window, LRU history and dead-client snapshot-then-act all live here. |
| FED_CLIENT | CJ | 6 | receive, execute (trainer stand-in), error, retry, receipt consume, local timeout | Only interacts through GET_TASK / TASK_ASSIGNMENT / TASK_CHECK / RESULT_ENVELOPE / RESULT_RECEIPT. |
| ENV | env | 2 | `ClockAdvance`, `TaskDeliveryFailure` | Shared clock, network loss. Other environment inputs (dead report, heartbeat, direct cancel, trainer choice) stay as input actions of their group (see Environment). |

Deviation from the candidate cut: the candidate put "callbacks" in FED_COMM. The data says the WFComm wrapper (`WFCommDispatchSubmission`, `WFCommStampReceipt`, `WFCommDropSubmission`) belongs to FED_COMM, but the callback *body* (from `BaseAcceptTrainResult` to `BaseClearTrainingResult`, plus `BaseProcessUnknownResult`) reads/writes `aggr.*` together with the controller thread. Putting it in FED_COMM would make the round lock a cross-group conflict. The resulting CTRL/COMM port is a blocking call: `APP_CALL(id, attempt, live|unknown, body)` issued by `WFCommDispatchSubmission` while COMM holds runner+comm locks, `APP_RETURN(id, decision)` consumed by `WFCommStampReceipt`/`WFCommDropSubmission`. `BasePrepareTaskData*` is controller-supplied `before_task_sent_cb` code but touches no CTRL state, so it stays in COMM.

Considered and rejected: (1) split FED_CTRL into round loop vs aggregation: both own the round guard. (2) split the dead-client watch (`mon.*`, `dead.*`) out of FED_COMM: possible later (port = `dead[c].disconnected` + PANIC), but the watch is cleared by runner activity actions (`ServerRunner*Active`) under the dead-client lock and the task monitor reads `dead[c].disconnected` under the comm lock; the repaired monitor defect and report-replacement scenario sit exactly there, so keep it inside for now.

Rendezvous / call actions (one atomic seed step whose effect crosses CTRL/COMM; model as joint actions with a half in each group): `WFCommScheduleTask` (SCHEDULE), `FedAvgCancelFailedTasks` (CANCEL_ALL ERROR, mark-only), `ServerRunnerCloseWorkflow` (WORKFLOW_RETURNED), `WFCommFinalizeRun` (CTRL pc finalize->finalized). Folded cross-process steps that must be split into separate actions: `ClientCheckTask` (SJ answer + CJ consume + RESULT_ENVELOPE upload) and `ServerRunnerTaskRequestActive` (CJ GET_TASK send + SJ receive).

### Bug-prone mechanisms vs the cut

| Mechanism | Evidence | Actions | Group | Verdict |
|---|---|---|---|---|
| claim->dispatch window with monitor retirement | integration-handoff.md atomic boundaries; validation-report U2; wf_comm_server.py:562-661 | WFCommClaimSubmission, WFCommAcquireSubmission, WFCommDispatchSubmission, WFCommMonitorAcquire, WFCommMonitorRemove | FED_COMM | inside |
| runner wf_lock serializes submission vs teardown | handoff; server_runner.py:158-172,456-612 | ServerRunnerProcessSubmission, ServerRunnerCloseWorkflow, WFCommFinalizeRun | FED_COMM | inside |
| retired history / first late result / eviction | validation-report U2 (first_late_unreceived, late_evicted_retry, closed_submission); Phase1 v2 Scenario 3 | WFCommMonitorRemove, ClientCheckTask, ServerRunnerCheckSubmission, WFCommDispatchSubmission, BaseProcessUnknownResult | FED_COMM (+ CTRL unknown hook) | inside except unknown-hook body (APP_CALL unknown) |
| dead-client watch snapshot-then-act | modeling-notes (report serial ghost), changelog (repaired monitor synthesis), R1 scenarios | WFCommMonitorClock, WFCommMonitorWatchList, WFCommCheckDeadClient, WFCommReadPolicyClient, WFCommJobPolicyDecision, WFCommReportDeadClient, ServerRunnerSubmissionActive | FED_COMM | inside |
| per-round guard + partial mutation + close-before-publish | validation-report U3; #5293/#5357; Phase1 Scenario 4 / MC-4 (SAG variant) | FedAvgCheckRoundGuard, WeightedParamFailure, WeightedMetricFailure, FedAvgPollFailed, FedAvgCancelFailedTasks, FedAvgCloseRound, FedAvgReleaseRoundGuard | FED_CTRL | inside |
| dynamic error context (failedClients) vs broadcast reset | changelog (moved reset to broadcast_model); Phase1 TV-1 | BaseAcceptTrainResult, BaseResetFailedClients, FedAvgResetAggregation | FED_CTRL | inside |
| client timeout vs in-flight server dispatch (duplicate attempts) | validation-report U1/U4 (timeout_inflight, timeout_queued, lost_ack_live) | ClientLoseDispatchAck, ClientRetryResult, ServerRunnerProcessSubmission, WFCommClaimSubmission | FED_CLIENT x FED_COMM | crosses the process cut by nature; dedup (claim) stays in COMM, wire is attempt-level |
| mark-only cancel overlapping admitted callback | S4 admitted_callback_cancel; modeling-notes | WFCommCancelTask, FedAvgCancelFailedTasks, WFCommDispatchSubmission, BasePublishAcceptance | FED_COMM x FED_CTRL | crosses via task.status only; CTRL callback never reads status; AbnormalTerminationVisible spans |
| resend-loop flag overwrite (WF-C1) | Phase1 v2 Scenario 3; wf_comm_server.py:238-280 | WFCommResendTask, WFCommProcessTaskRequest | FED_COMM | inside (not reachable in seed: one standing task) |

## Actions

Field-level (`s.` stripped; `[t][c][n]` = task, site, transport attempt; `x.*` = whole record). Italic = boundary role. Full read and guard-read sets per action are in the JSON (`actions[].reads`, `guardReads`).

| # | Action(params) | Group | Proc | Mechanism | Trigger | Source anchor | Writes | Cross-group reads |
|---|---|---|---|---|---|---|---|---|
| 1 | `FedAvgRoundStarted()` | FED_CTRL | SJ | controller-round | internal | app_common/workflows/fedavg.py:194-203 | wf.pc, wf.round, wf.started |  |
| 2 | `FedAvgResetAggregation()` | FED_CTRL | SJ | controller-round | internal | app_common/workflows/fedavg.py:206-224 | aggr.*, scratch.*, wf.pc |  |
| 3 | `BaseResetFailedClients()` | FED_CTRL | SJ | controller-round | internal | app_common/workflows/base_model_controller.py:160-166 | aggr.failedClients, wf.pc |  |
| 4 | `WFCommScheduleTask()` *rendezvous CTRL->COMM SCHEDULE* | FED_COMM | SJ | wfcomm-assignment | internal | app_common/workflows/base_model_controller.py:153-169,199-232; apis/impl/wf_comm_server.py:682-726 | task[t].scheduled, task[t].sourceAtSchedule, task[t].standing, task[t].status, **wf.pc** | wf.round, wf.sourceVersion |
| 5 | `FedAvgPollStanding()` *query COMM standing* | FED_CTRL | SJ | controller-round | internal | app_common/workflows/fedavg.py:245-260 | wf.pc | task[t].standing |
| 6 | `FedAvgPollFailed()` | FED_CTRL | SJ | controller-round | internal | app_common/workflows/fedavg.py:246-248 | wf.pc |  |
| 7 | `FedAvgCancelFailedTasks()` *rendezvous CTRL->COMM CANCEL_ALL(ERROR)* | FED_CTRL | SJ | controller-round | internal | app_common/workflows/fedavg.py:246-248; apis/impl/wf_comm_server.py:962-979 | **task[t].status**, wf.pc | task[t].standing |
| 8 | `FedAvgPollAbort()` *read abort latch* | FED_CTRL | SJ | controller-round | internal | app_common/workflows/fedavg.py:249-254 | wf.pc | wf.abort |
| 9 | `FedAvgCloseRound()` | FED_CTRL | SJ | controller-round | internal | app_common/workflows/fedavg.py:250-260 | aggr.closed, wf.outcome, wf.pc |  |
| 10 | `FedAvgRejectEmptyRound()` | FED_CTRL | SJ | aggregation | internal | app_common/workflows/fedavg.py:389-390 | wf.pc |  |
| 11 | `BaseModelControllerRunException()` *PANIC -> runner abort latch* | FED_CTRL | SJ | controller-round | internal | app_common/workflows/base_model_controller.py:389-401 | **wf.abort**, wf.outcome, wf.pc |  |
| 12 | `FedAvgGetAggregationStats()` | FED_CTRL | SJ | aggregation | internal | app_common/workflows/fedavg.py:262-265,388-396; app_common/aggregators/weighted_aggregation_helper.py:288-311 | scratch.paramHistory, scratch.stats, wf.pc |  |
| 13 | `WeightedGetParamResult()` | FED_CTRL | SJ | aggregation | internal | app_common/aggregators/weighted_aggregation_helper.py:272-286; app_common/workflows/fedavg.py:396 | aggr.applied, aggr.paramHistory, aggr.stats, scratch.params, wf.pc |  |
| 14 | `WeightedGetMetricResult()` | FED_CTRL | SJ | aggregation | internal | app_common/workflows/fedavg.py:397-398; app_common/aggregators/weighted_aggregation_helper.py:272-286 | aggr.metricApplied, aggr.metricHistory, aggr.metricStats, scratch.allMetrics, scratch.metricHistory, scratch.metricStats, scratch.metrics, wf.pc |  |
| 15 | `FedAvgBuildAggregateResult()` | FED_CTRL | SJ | aggregation | internal | app_common/workflows/fedavg.py:400-410 | scratch.count, scratch.counted, wf.pc |  |
| 16 | `BaseFedAvgUpdateModel()` | FED_CTRL | SJ | model-update | internal | app_common/workflows/fedavg.py:266-270; app_common/workflows/base_fedavg.py:302-322 | committed, used[t], wf.pc, wf.sourceVersion |  |
| 17 | `FedAvgSaveModel()` | FED_CTRL | SJ | model-update | internal | app_common/workflows/fedavg.py:289-291,534-549; app_common/workflows/base_model_controller.py:452-459 | saved, wf.pc |  |
| 18 | `FedAvgAdvanceRound()` | FED_CTRL | SJ | controller-round | internal | app_common/workflows/fedavg.py:194,293-298; private/fed/server/server_runner.py:152-184 | wf.outcome, wf.pc |  |
| 19 | `BaseAcceptTrainResult()` *APP_CALL entry (live path); PANIC* | FED_CTRL | SJ | result-callback | internal | app_common/workflows/base_model_controller.py:262-284,342-378; app_common/utils/error_handling_utils.py:51-61 | aggr.failedClients, **comm.pc**, **wf.abort** | comm.id, comm.kind, ct[t][c].result |
| 20 | `BaseConvertResult()` | FED_CTRL | SJ | result-callback | internal | app_common/workflows/base_model_controller.py:283-295 | **comm.pc**, ct[t][c].invocations | comm.id, comm.kind |
| 21 | `BaseConvertResultFailure()` | FED_CTRL | SJ | result-callback | internal (fault:conversion) | app_common/workflows/base_model_controller.py:283-289 | **comm.pc** | comm.kind |
| 22 | `FedAvgCheckRoundGuard()` | FED_CTRL | SJ | aggregation | internal | app_common/workflows/fedavg.py:225-233 | aggr.locked, **comm.pc** | comm.kind |
| 23 | `FedAvgAggregateOneResult()` | FED_CTRL | SJ | aggregation | internal | app_common/workflows/fedavg.py:301-325 | comm.key, **comm.pc** | comm.id, comm.kind, ct[t][c].result |
| 24 | `FedAvgValidateShapes()` | FED_CTRL | SJ | aggregation | internal | app_common/workflows/fedavg.py:326-339; app_common/aggregators/weighted_aggregation_helper.py:157-188 | **comm.pc** | comm.kind |
| 25 | `FedAvgRejectShape()` | FED_CTRL | SJ | aggregation | internal (fault:shape) | app_common/workflows/fedavg.py:335-337 | **comm.pc** | comm.kind |
| 26 | `FedAvgMetricPreparationFailure()` | FED_CTRL | SJ | aggregation | internal (fault:metricPrep) | app_common/workflows/fedavg.py:229-233,329-332 | aggr.failed, aggr.locked, **comm.pc** | comm.id, comm.kind, ct[t][c].metricKind |
| 27 | `WeightedAddParamStats()` | FED_CTRL | SJ | aggregation | internal | app_common/aggregators/weighted_aggregation_helper.py:207-221 | aggr.stats, **comm.pc** | comm.id, comm.kind |
| 28 | `WeightedAddParamValue()` | FED_CTRL | SJ | aggregation | internal | app_common/aggregators/weighted_aggregation_helper.py:219-262 | aggr.applied, comm.key, **comm.pc** | comm.id, comm.kind |
| 29 | `WeightedParamFailure()` | FED_CTRL | SJ | aggregation | internal (fault:param) | app_common/aggregators/weighted_aggregation_helper.py:218-261; app_common/workflows/fedavg.py:229-233 | aggr.failed, aggr.locked, **comm.pc** | comm.kind |
| 30 | `WeightedAddParamHistory()` | FED_CTRL | SJ | aggregation | internal | app_common/aggregators/weighted_aggregation_helper.py:264-270; app_common/workflows/fedavg.py:339-356 | aggr.paramHistory, **comm.pc** | comm.id, comm.kind |
| 31 | `FedAvgProcessMetrics()` | FED_CTRL | SJ | aggregation | internal | app_common/workflows/fedavg.py:345-351 | **comm.pc** | comm.id, comm.kind, ct[t][c].metricKind |
| 32 | `WeightedAddMetricStats()` | FED_CTRL | SJ | aggregation | internal | app_common/workflows/fedavg.py:358-358; app_common/aggregators/weighted_aggregation_helper.py:207-221 | aggr.metricStats, **comm.pc** | comm.id, comm.kind |
| 33 | `WeightedAddMetricValue()` | FED_CTRL | SJ | aggregation | internal | app_common/aggregators/weighted_aggregation_helper.py:223-262 | aggr.metricApplied, **comm.pc** | comm.id, comm.kind |
| 34 | `WeightedMetricFailure()` | FED_CTRL | SJ | aggregation | internal (fault:metric) | app_common/aggregators/weighted_aggregation_helper.py:218-261; app_common/workflows/fedavg.py:229-233 | aggr.failed, aggr.locked, **comm.pc** | comm.kind |
| 35 | `WeightedAddMetricHistory()` | FED_CTRL | SJ | aggregation | internal | app_common/aggregators/weighted_aggregation_helper.py:265-270; app_common/workflows/fedavg.py:345-368 | aggr.metricHistory, **comm.pc** | comm.id, comm.kind |
| 36 | `FedAvgCommitMetricCoverage()` | FED_CTRL | SJ | aggregation | internal | app_common/workflows/fedavg.py:353-368 | aggr.allMetrics, **comm.pc** | comm.id, comm.kind, ct[t][c].metricKind |
| 37 | `FedAvgIncrementReceived()` | FED_CTRL | SJ | aggregation | internal | app_common/workflows/fedavg.py:370-375 | aggr.counted, aggr.receivedCount, comm.accepted, **comm.pc** | comm.id, comm.kind |
| 38 | `FedAvgReleaseRoundGuard()` | FED_CTRL | SJ | aggregation | internal | app_common/workflows/fedavg.py:225-233 | aggr.locked, **comm.pc** | comm.kind |
| 39 | `BasePublishAcceptance()` | FED_CTRL | SJ | result-callback | internal | app_common/workflows/base_model_controller.py:278-302 | **comm.pc**, ct[t][c].decision | comm.id, comm.kind |
| 40 | `BaseClearTrainingResult()` *APP_RETURN (live path)* | FED_CTRL | SJ | result-callback | internal | app_common/workflows/base_model_controller.py:303-305 | **comm.pc** | comm.kind |
| 41 | `BaseProcessUnknownResult()` *APP_CALL(unknown)+APP_RETURN* | FED_CTRL | SJ | result-callback | internal | apis/impl/wf_comm_server.py:643-651; app_common/workflows/base_model_controller.py:309-378 | **comm.pc**, unknownSeen | comm.id, comm.kind |
| 42 | `ServerRunnerTaskRequestActive(c)` *GET_TASK arrival; CJ send folded (ClientCanPoll)* | FED_COMM | SJ (folds CJ GET_TASK send) | wfcomm-assignment | internal | private/fed/server/server_runner.py:290-299,614-620; apis/impl/wf_comm_server.py:1405-1414 | dead[c].age, dead[c].disconnected, dead[c].reported, requested | ct[t][c].delivery, ct[t][c].result, net[t][c][n].outcome |
| 43 | `ServerRunnerAcquireTaskRequest(c)` | FED_COMM | SJ | wfcomm-assignment | internal | private/fed/server/server_runner.py:390-400 | requested, runner.* |  |
| 44 | `WFCommProcessTaskRequest(c)` | FED_COMM | SJ | wfcomm-assignment | internal | private/fed/server/server_runner.py:390-432; apis/impl/wf_comm_server.py:225-299 | **comm.accepted**, comm.attempt, comm.deadView, comm.exit, comm.id, **comm.key**, comm.kind, comm.pc, comm.pending, comm.writeStatus | wf.round |
| 45 | `WFCommResendTask(id)` | FED_COMM | SJ | wfcomm-assignment | internal | apis/impl/wf_comm_server.py:246-257,293-395 | **comm.accepted**, comm.attempt, comm.deadView, comm.exit, comm.id, **comm.key**, comm.kind, comm.pc, comm.pending, comm.writeStatus | ct[t][c].delivery, ct[t][c].result |
| 46 | `BasePrepareTaskData()` | FED_COMM | SJ | wfcomm-assignment | internal | app_common/workflows/base_model_controller.py:236-239; apis/impl/wf_comm_server.py:297-314 | comm.pc |  |
| 47 | `BasePrepareTaskDataFailure()` | FED_COMM | SJ | wfcomm-assignment | internal (fault:before) | apis/impl/wf_comm_server.py:297-330 | comm.pc, task[t].status |  |
| 48 | `WFCommProtectBroadcast()` | FED_COMM | SJ | wfcomm-assignment | internal | apis/impl/wf_comm_server.py:321-340 | comm.pc, task[t].broadcastVersion |  |
| 49 | `WFCommProtectBroadcastFailure()` | FED_COMM | SJ | wfcomm-assignment | internal (fault:snapshot) | apis/impl/wf_comm_server.py:329-340 | comm.pc, task[t].status |  |
| 50 | `WFCommCheckCanSend()` | FED_COMM | SJ | wfcomm-assignment | internal | apis/impl/wf_comm_server.py:343-361; app_common/workflows/base_model_controller.py:224-232 | comm.pc |  |
| 51 | `WFCommPublishClientTask()` | FED_COMM | SJ | wfcomm-assignment | internal | apis/impl/wf_comm_server.py:369-396; private/fed/server/server_runner.py:419-430 | **comm.accepted**, comm.attempt, comm.deadView, comm.exit, comm.id, **comm.key**, comm.kind, comm.pc, comm.pending, comm.writeStatus, ct[t][c].assigned, ct[t][c].delivery, ct[t][c].headerAttempt, ct[t][c].headerId, ct[t][c].headerRound, ct[t][c].inputVersion, ct[t][c].job, ct[t][c].workflow, runner.*, task[t].assignedOrder |  |
| 52 | `WFCommTaskTryAgain()` *TRY_AGAIN reply (implicit)* | FED_COMM | SJ | wfcomm-assignment | internal | apis/impl/wf_comm_server.py:356-361 | **comm.accepted**, comm.attempt, comm.deadView, comm.exit, comm.id, **comm.key**, comm.kind, comm.pc, comm.pending, comm.writeStatus, runner.* |  |
| 53 | `WFCommTaskUnavailable()` *no-task reply (implicit)* | FED_COMM | SJ | wfcomm-assignment | internal | private/fed/server/server_runner.py:391-400; apis/impl/wf_comm_server.py:236-288 | runner.* | ct[t][c].delivery, ct[t][c].result |
| 54 | `ServerRunnerFilterTask(id)` *TASK_ASSIGNMENT send* | FED_COMM | SJ | wfcomm-assignment | internal | private/fed/server/server_runner.py:333-376 | ct[t][c].delivery |  |
| 55 | `ServerRunnerFilterFailure(id)` | FED_COMM | SJ | wfcomm-assignment | internal (fault:filter) | private/fed/server/server_runner.py:337-354 | ct[t][c].delivery |  |
| 56 | `WFCommHandleException(id)` *TRY_AGAIN reply after filter error* | FED_COMM | SJ | wfcomm-assignment | internal | private/fed/server/server_runner.py:354-360; apis/impl/wf_comm_server.py:397-415,945-963 | ct[t][c].delivery, task[t].status |  |
| 57 | `WFCommCancelTask(t)` | FED_COMM | SJ | task-lifecycle | environment (fault:cancel) | apis/impl/wf_comm_server.py:945-978 | task[t].status |  |
| 58 | `ServerRunnerCheckTaskActive(id, n)` *TASK_CHECK arrival* | FED_COMM | SJ | submission | internal | private/fed/server/server_runner.py:617-628 | dead[c].age, dead[c].disconnected, dead[c].reported, net[t][c][n].stage | net[t][c] |
| 59 | `ClientCheckTask(id, n)` *TASK_CHECK reply + CJ reaction + RESULT_ENVELOPE send folded* | FED_COMM | SJ+CJ (atomic RPC) | submission | internal | apis/impl/wf_comm_server.py:417-464; private/fed/server/server_runner.py:627-672 | completed, **net[t][c][n].outcome**, net[t][c][n].receipt, net[t][c][n].stage | net[t][c] |
| 60 | `ServerRunnerProcessSubmission(id, n)` *RESULT_ENVELOPE dequeue* | FED_COMM | SJ | submission | internal | private/fed/server/server_runner.py:456-464 | net[t][c][n].receipt, net[t][c][n].stage, runner.* | net[t][c] |
| 61 | `ServerRunnerSubmissionActive()` | FED_COMM | SJ | submission | internal | private/fed/server/server_runner.py:458-467,614-620; apis/impl/wf_comm_server.py:1405-1414 | dead[c].age, dead[c].disconnected, dead[c].reported, runner.pc |  |
| 62 | `ServerRunnerDropClosedSubmission()` *RESULT_RECEIPT send (TASK_CLOSED)* | FED_COMM | SJ | submission | internal | private/fed/server/server_runner.py:456-464 | net[t][c][n].stage, runner.* |  |
| 63 | `ServerRunnerCheckSubmission()` | FED_COMM | SJ | submission | internal | private/fed/server/server_runner.py:492-524; apis/impl/wf_comm_server.py:503-560 | completed, net[t][c][n].receipt, runner.pc |  |
| 64 | `WFCommClaimSubmission()` | FED_COMM | SJ | submission | internal | apis/impl/wf_comm_server.py:562-592 | completed, ct[t][c].claimed, net[t][c][n].receipt, runner.pc |  |
| 65 | `ServerRunnerRejectSubmission()` *RESULT_RECEIPT send* | FED_COMM | SJ | submission | internal | private/fed/server/server_runner.py:508-523 | net[t][c][n].stage, runner.* |  |
| 66 | `WFCommAcquireSubmission()` | FED_COMM | SJ | submission | internal | private/fed/server/server_runner.py:595-605; apis/impl/wf_comm_server.py:616-633 | **comm.accepted**, comm.attempt, comm.deadView, comm.exit, comm.id, **comm.key**, comm.kind, comm.pc, comm.pending, comm.writeStatus, runner.pc |  |
| 67 | `WFCommDispatchSubmission()` *APP_CALL(live|unknown)* | FED_COMM | SJ | submission | internal | apis/impl/wf_comm_server.py:632-661 | comm.pc, completed |  |
| 68 | `WFCommStampReceipt()` *APP_RETURN consume + RESULT_RECEIPT send* | FED_COMM | SJ | submission | internal | apis/impl/wf_comm_server.py:594-618; private/fed/server/server_runner.py:611-615 | **comm.accepted**, comm.attempt, comm.deadView, comm.exit, comm.id, **comm.key**, comm.kind, comm.pc, comm.pending, comm.writeStatus, completed, ct[t][c].receipt, net[t][c][n].stage, runner.* |  |
| 69 | `WFCommDropSubmission()` *APP_RETURN(unknown) + RESULT_RECEIPT send* | FED_COMM | SJ | submission | internal | apis/impl/wf_comm_server.py:600-614,647-661 | **comm.accepted**, comm.attempt, comm.deadView, comm.exit, comm.id, **comm.key**, comm.kind, comm.pc, comm.pending, comm.writeStatus, completed, ct[t][c].receipt, net[t][c][n].stage, runner.* |  |
| 70 | `WFCommReportDeadClient(c)` | FED_COMM | SJ | dead-client | environment (fault:dead) | apis/impl/wf_comm_server.py:191-202,82-85 | dead[c].* |  |
| 71 | `WFCommClientIsActive(c)` | FED_COMM | SJ | dead-client | environment | private/fed/server/server_runner.py:614-629; apis/impl/wf_comm_server.py:1405-1414 | dead[c].age, dead[c].disconnected, dead[c].reported |  |
| 72 | `WFCommMonitorBegin()` | FED_COMM | SJ | monitor | internal | apis/impl/wf_comm_server.py:1178-1180 | mon.deadView, mon.pc, mon.pending | wf.pc |
| 73 | `WFCommMonitorClock()` | FED_COMM | SJ | dead-client | internal | apis/impl/wf_comm_server.py:1182 | mon.pc, mon.reportAges, mon.reportSerial |  |
| 74 | `WFCommMonitorWatchList()` | FED_COMM | SJ | dead-client | internal | apis/impl/wf_comm_server.py:1183-1184 | mon.pc, mon.pending |  |
| 75 | `WFCommCheckDeadClient(c)` | FED_COMM | SJ | dead-client | internal | apis/impl/wf_comm_server.py:1182-1199 | dead[c].disconnected, mon.pending |  |
| 76 | `WFCommDeadCheckDone()` | FED_COMM | SJ | dead-client | internal | apis/impl/wf_comm_server.py:1204-1206,1373-1382 | mon.deadView, mon.pc, mon.pending |  |
| 77 | `WFCommReadPolicyClient(c)` | FED_COMM | SJ | dead-client | internal | apis/impl/wf_comm_server.py:1373-1382 | mon.deadView, mon.pending |  |
| 78 | `WFCommJobPolicyDecision()` *PANIC -> runner abort latch* | FED_COMM | SJ | dead-client | internal | apis/impl/wf_comm_server.py:1384-1403,1206-1212; private/fed/server/server_runner.py:253-257,675-679 | mon.pc, wf.abort |  |
| 79 | `WFCommMonitorAcquire()` | FED_COMM | SJ | monitor | internal | apis/impl/wf_comm_server.py:1215-1223 | **comm.accepted**, comm.attempt, comm.deadView, comm.exit, comm.id, **comm.key**, comm.kind, comm.pc, comm.pending, comm.writeStatus, mon.pc |  |
| 80 | `WFCommMonitorSelect(t)` | FED_COMM | SJ | monitor | internal | apis/impl/wf_comm_server.py:1222-1252; apis/impl/bcast_manager.py:52-75 | comm.deadView, comm.exit, comm.id, comm.pc, comm.pending |  |
| 81 | `WFCommReadTaskDeadClient(c)` | FED_COMM | SJ | monitor | internal | apis/impl/wf_comm_server.py:1325-1340 | comm.deadView, comm.exit, comm.pending |  |
| 82 | `WFCommTaskDeadCheckDone()` | FED_COMM | SJ | monitor | internal | apis/impl/wf_comm_server.py:1247-1253,1325-1342 | **comm.accepted**, comm.attempt, comm.deadView, comm.exit, comm.id, **comm.key**, comm.kind, comm.pc, comm.pending, comm.writeStatus, mon.pc |  |
| 83 | `WFCommMonitorMarkTerminal()` | FED_COMM | SJ | monitor | internal | apis/impl/wf_comm_server.py:1234-1239,1247-1252 | comm.pc, task[t].status |  |
| 84 | `WFCommMonitorRemove()` | FED_COMM | SJ | monitor | internal | apis/impl/wf_comm_server.py:1255-1264,464-497 | comm.pc, completed, task[t].retiredOutstanding, task[t].retiredStatus, task[t].standing |  |
| 85 | `WFCommMonitorCleanup()` | FED_COMM | SJ | monitor | internal | apis/impl/wf_comm_server.py:1271-1310 | **comm.accepted**, comm.attempt, comm.deadView, comm.exit, comm.id, **comm.key**, comm.kind, comm.pc, comm.pending, comm.writeStatus, mon.pc, task[t].cleaned |  |
| 86 | `WFCommMonitorNoTask()` | FED_COMM | SJ | monitor | internal | apis/impl/wf_comm_server.py:1222-1225,1268-1269 | **comm.accepted**, comm.attempt, comm.deadView, comm.exit, comm.id, **comm.key**, comm.kind, comm.pc, comm.pending, comm.writeStatus, mon.pc |  |
| 87 | `ServerRunnerCloseWorkflow()` *rendezvous CTRL->COMM WORKFLOW_RETURNED* | FED_COMM | SJ | workflow-teardown | internal | private/fed/server/server_runner.py:158-172 | wf.open, **wf.pc** |  |
| 88 | `WFCommFinalizeRun()` *CTRL pc finalize->finalized* | FED_COMM | SJ | workflow-teardown | internal | apis/impl/wf_comm_server.py:980-1046; private/fed/server/server_runner.py:171-179 | completed, mon.pc, task[t].cleaned, task[t].retiredOutstanding, task[t].retiredStatus, task[t].standing, task[t].status, **wf.pc** |  |
| 89 | `ClientReceiveTask(id)` *TASK_ASSIGNMENT consume* | FED_CLIENT | CJ | client-runner | internal | private/fed/client/client_runner.py:245-277; private/fed/server/server_runner.py:376 | **ct[t][c].delivery** |  |
| 90 | `ClientProcessTask(id, kind, mk)` *TASK_CHECK(1) send* | FED_CLIENT | CJ | client-runner | internal | private/fed/client/client_runner.py:245-277; app_common/workflows/fedavg.py:300-305,346-358 | ct[t][c].metricKind, ct[t][c].result, net[t][c], net[t][c][n].outcome, **net[t][c][n].receipt**, **net[t][c][n].stage** | ct[t][c].delivery |
| 91 | `ClientExecutionError(id)` *TASK_CHECK(1) send* | FED_CLIENT | CJ | client-runner | internal (fault:resultError) | private/fed/client/client_runner.py:245-277 | ct[t][c].result, net[t][c], net[t][c][n].outcome, **net[t][c][n].receipt**, **net[t][c][n].stage** | ct[t][c].delivery |
| 92 | `ClientRetryResult(id)` *TASK_CHECK(n+1) send* | FED_CLIENT | CJ | client-runner | internal | private/fed/client/client_runner.py:656-678 | net[t][c], net[t][c][n].outcome, **net[t][c][n].receipt**, **net[t][c][n].stage** |  |
| 93 | `ServerCommandDispatchAck(id, n)` *RESULT_RECEIPT consume* | FED_CLIENT | CJ | client-runner | internal | private/fed/client/client_runner.py:709-726; apis/shareable.py:51-72 | net[t][c][n].outcome | net[t][c][n].receipt, net[t][c][n].stage |
| 94 | `ClientLoseDispatchAck(id, n)` | FED_CLIENT | CJ | client-runner | fault (fault:ackLoss) | private/fed/client/client_runner.py:709-726 | net[t][c][n].outcome | net[t][c][n].stage |
| 95 | `ClockAdvance()` | ENV | env (clock) | clock | environment | apis/impl/wf_comm_server.py:1190-1195,1316-1323 | **dead[c].age**, **task[t].age** | dead[c].reported, task[t].scheduled, wf.pc |
| 96 | `TaskDeliveryFailure(id)` *TASK_ASSIGNMENT drop* | ENV | env (network) | network | fault (fault:delivery) | private/fed/server/server_runner.py:376; private/fed/client/client_runner.py:245-277 | **ct[t][c].delivery** |  |

Bold write = write to a field whose proposed owner is another group.

## Field ownership

Rows with identical attributes inside one record are folded. Properties column omits TypeOK/MCTypeOK.

| Field | Writer groups | Reader groups (actions) | Class (as-is) | Proposed owner | Resolution / port | Read by properties |
|---|---|---|---|---|---|---|
| `wf.round` | FED_CTRL | FED_COMM, FED_CTRL | port | FED_CTRL | private; COMM's use in ProcessTaskRequest is a task=round shortcut (pick standing task instead) | CallbackRoundIsolation, VSFedAvgInterface!Safety via FedAvgRefinement!Abs |
| `wf.pc` | FED_COMM, FED_CTRL | ENV, FED_COMM, FED_CTRL | conflict | FED_CTRL | split: CTRL keeps controller PCs; schedule/returned/finalize transitions become rendezvous halves (SCHEDULE, WORKFLOW_RETURNED); 'finalized' moves to COMM | EligibleTaskEventuallyDrains |
| `wf.sourceVersion` | FED_CTRL | FED_COMM | port | FED_CTRL | port: argument of SCHEDULE(t,version) | - |
| `wf.started` | FED_CTRL | - | private | FED_CTRL | private (ghost) | AbnormalTerminationVisible |
| `wf.abort` | FED_COMM, FED_CTRL | FED_COMM, FED_CTRL | conflict | FED_COMM | monotone run-abort latch owned by runner; CTRL writes become PANIC events; CTRL reads latch | DynamicErrorSignalsAbort |
| `wf.outcome` | FED_CTRL | - | private | FED_CTRL | private (ghost); exported in WORKFLOW_RETURNED | AbnormalTerminationVisible |
| `wf.open` | FED_COMM | FED_COMM | private | FED_COMM | private to runner (current_wf); rename srv.open | VSFedAvgInterface!Safety via FedAvgRefinement!Abs |
| `task[t].scheduled` | FED_COMM | ENV, FED_COMM | port | FED_COMM | private (SCHEDULE effect) | EligibleTaskEventuallyDrains, VSFedAvgInterface!Safety via FedAvgRefinement!Abs |
| `task[t].standing` | FED_COMM | FED_COMM, FED_CTRL | port | FED_COMM | port: read-only query for CTRL (get_num_standing_tasks) | CallbackRoundIsolation, EligibleTaskEventuallyDrains, OneStandingTask |
| `task[t].status` | FED_COMM, FED_CTRL | FED_COMM | conflict | FED_COMM | CTRL write = CANCEL_ALL(ERROR) rendezvous; ENV-driven cancel stays COMM | CompletedHistoryBound, EligibleTaskEventuallyDrains |
| `task[t].sourceAtSchedule` | FED_COMM | FED_COMM | private | FED_COMM | private (from SCHEDULE arg) | ProtectedBroadcastInput |
| `task[t].broadcastVersion` | FED_COMM | FED_COMM | private | FED_COMM | private; becomes TASK_ASSIGNMENT input generation | ProtectedBroadcastInput |
| `task[t].assignedOrder` | FED_COMM | FED_COMM | private | FED_COMM | private | - |
| `task[t].age` | ENV | FED_COMM | port | FED_COMM | clock-derived; replace ENV write by shared clock + schedule timestamp | EligibleTaskEventuallyDrains |
| `task[t].cleaned` | FED_COMM | - | private | FED_COMM | private (ghost) | - |
| `task[t].retiredStatus` | FED_COMM | - | private | FED_COMM | private; read by cross-group property AbnormalTerminationVisible | AbnormalTerminationVisible |
| `task[t].retiredOutstanding` | FED_COMM | - | private | FED_COMM | private; read by cross-group property | AbnormalTerminationVisible |
| `ct[t][c].assigned` | FED_COMM | FED_COMM | private | FED_COMM | private | AssignmentAuthorityPreserved, CommittedRoundProvenance, CompletedHistoryBound, ProtectedBroadcastInput, UpdateSafety, VSFedAvgInterface!Safety via FedAvgRefinement!Abs |
| `ct[t][c].headerId` | FED_COMM | - | private | FED_COMM | TASK_ASSIGNMENT correlation (clientTask) | ProtectedBroadcastInput, VSFedAvgInterface!Safety via FedAvgRefinement!Abs |
| `ct[t][c].headerRound` | FED_COMM | - | private | FED_COMM | TASK_ASSIGNMENT correlation (round) | CommittedRoundProvenance, ProtectedBroadcastInput, VSFedAvgInterface!Safety via FedAvgRefinement!Abs |
| `ct[t][c].inputVersion` | FED_COMM | - | private | FED_COMM | TASK_ASSIGNMENT content (input generation) | ProtectedBroadcastInput, VSFedAvgInterface!Safety via FedAvgRefinement!Abs |
| `ct[t][c].delivery` | ENV, FED_CLIENT, FED_COMM | ENV, FED_CLIENT, FED_COMM | conflict | FED_COMM | split: COMM sendStage {none,filter,filterFailed,sent,tryAgain}; CJ inbox {none,ready,failed}; wire->ready/failed via TASK_ASSIGNMENT delivery/drop | VSFedAvgInterface!Safety via FedAvgRefinement!Abs |
| `ct[t][c].result` | FED_CLIENT | FED_CLIENT, FED_COMM, FED_CTRL | port | FED_CLIENT | CJ-local result; content travels in RESULT_ENVELOPE body (rc, kind) | VSFedAvgInterface!Safety via FedAvgRefinement!Abs |
| `ct[t][c].metricKind` | FED_CLIENT | FED_CTRL | port | FED_CLIENT | CJ-local; RESULT_ENVELOPE body (metrics present/none/empty) | CommittedAcceptanceConsistency, PublishedContributionsAccepted, UpdateSafety |
| `ct[t][c].receipt` | FED_COMM | FED_COMM | private | FED_COMM | private (callback-finish timestamp) | ClaimBeforeFinish, EligibleTaskEventuallyDrains, ReceiptAfterDecision, ReceiptRequiresClaim, UpdateSafety, VSFedAvgInterface!Safety via FedAvgRefinement!Abs |
| `ct[t][c].claimed` | FED_COMM | FED_COMM | private | FED_COMM | private (complete-result claim) | ClaimBeforeFinish, ReceiptRequiresClaim, UpdateSafety, VSFedAvgInterface!Safety via FedAvgRefinement!Abs |
| `ct[t][c].headerAttempt` | FED_COMM | - | private | FED_COMM | TASK_ASSIGNMENT correlation (serverAttempt) | AssignmentAuthorityPreserved, UpdateSafety, VSFedAvgInterface!Safety via FedAvgRefinement!Abs |
| `ct[t][c].job` | FED_COMM | - | private | FED_COMM | TASK_ASSIGNMENT correlation (job) | AssignmentAuthorityPreserved, VSFedAvgInterface!Safety via FedAvgRefinement!Abs |
| `ct[t][c].workflow` | FED_COMM | - | private | FED_COMM | TASK_ASSIGNMENT correlation (workflow cookie) | AssignmentAuthorityPreserved, VSFedAvgInterface!Safety via FedAvgRefinement!Abs |
| `ct[t][c].decision` | FED_CTRL | - | private | FED_CTRL | move to CTRL contribution record; APP_RETURN carries it | CommittedAcceptanceConsistency, CommittedValuesAccepted, PublishedContributionsAccepted, ReceiptAfterDecision, UpdateSafety, VSFedAvgInterface!Safety via FedAvgRefinement!Abs |
| `ct[t][c].invocations` | FED_CTRL | - | private | FED_CTRL | move to CTRL contribution record (ghost) | AtMostOneConsumer, NoDuplicateConsumer, UpdateSafety |
| `net[t][c]` | FED_CLIENT | FED_CLIENT, FED_COMM | port | FED_CLIENT | split: CJ attempt list (transport attempts n) + message queue | - |
| `net[t][c][n].stage` | FED_CLIENT, FED_COMM | FED_CLIENT, FED_COMM | conflict | FED_COMM | split: CJ creation = TASK_CHECK send; COMM keeps server stage per received attempt | MessageBufferBound |
| `net[t][c][n].outcome` | FED_CLIENT, FED_COMM | FED_CLIENT, FED_COMM | conflict | FED_CLIENT | CJ-local observation; COMM write in ClientCheckTask becomes TASK_CHECK_REPLY consumption on CJ | - |
| `net[t][c][n].receipt` | FED_CLIENT, FED_COMM | FED_CLIENT | conflict | FED_COMM | reply content; carried in TASK_CHECK_REPLY / RESULT_RECEIPT body | - |
| `comm.kind` | FED_COMM | FED_COMM, FED_CTRL | port | FED_COMM | private lock owner (_controller_lock); CTRL callback reads it only as call frame | CallbackRoundIsolation, CallerLockDiscipline |
| `comm.pc` | FED_COMM, FED_CTRL | FED_COMM, FED_CTRL | conflict | FED_COMM | split: COMM keeps {before..publish,dispatch,inApp,receipt,drop,monitor PCs}; callback PCs move to CTRL app.pc | CallbackRoundIsolation |
| `comm.id` | FED_COMM | FED_COMM, FED_CTRL | port | FED_COMM | APP_CALL argument (clientTask id) | CallbackRoundIsolation |
| `comm.attempt` | FED_COMM | FED_COMM | private | FED_COMM | private (transport attempt of the admitted submission) | - |
| `comm.key` | FED_COMM, FED_CTRL | FED_CTRL | conflict | FED_CTRL | callback-local key cursor; move to CTRL app frame | - |
| `comm.accepted` | FED_COMM, FED_CTRL | FED_CTRL | conflict | FED_CTRL | callback-local; becomes APP_RETURN decision | - |
| `comm.{exit, pending}` | FED_COMM | FED_COMM | private | FED_COMM | private (monitor) | - |
| `comm.writeStatus` | FED_COMM | - | private | FED_COMM | unused (only in EmptyComm/TypeOK) | - |
| `comm.deadView` | FED_COMM | - | private | FED_COMM | private (monitor) | - |
| `runner.kind` | FED_COMM | FED_COMM | private | FED_COMM | private (runner wf_lock) | CallbacksTerminate, CallerLockDiscipline |
| `runner.{pc, client, id, attempt}` | FED_COMM | FED_COMM | private | FED_COMM | private | - |
| `requested` | FED_COMM | FED_COMM | private | FED_COMM | GET_TASK received, waiting for wf_lock | - |
| `aggr.task` | FED_CTRL | - | private | FED_CTRL | private (round guard / helper state / aggregate scratch) | CallbackRoundIsolation, NoFailedRoundPublished |
| `aggr.{applied, stats, paramHistory, metricApplied, metricStats, metricHistory, allMetrics, receivedCount, counted, failedClients, failed, closed, locked}` | FED_CTRL | FED_CTRL | private | FED_CTRL | private (round guard / helper state / aggregate scratch) | CountMatchesSuccessfulReturns, DynamicErrorSignalsAbort, NoFailedRoundPublished, UpdateSafety, VSFedAvgInterface!Safety via FedAvgRefinement!Abs |
| `scratch.{params, stats, paramHistory, metrics, metricStats, metricHistory, allMetrics, count, counted}` | FED_CTRL | FED_CTRL | private | FED_CTRL | private (round guard / helper state / aggregate scratch) | - |
| `used[t]` | FED_CTRL | - | private | FED_CTRL | private (published aggregate provenance) | CommittedAcceptanceConsistency, CommittedRoundProvenance, CommittedValuesAccepted, PublishedContributionsAccepted, PublishedHasAcceptedContribution, UpdateSafety |
| `committed` | FED_CTRL | - | private | FED_CTRL | private | CommittedAcceptanceConsistency, CommittedRoundProvenance, CommittedValuesAccepted, NoFailedRoundPublished, PublishedContributionsAccepted, PublishedHasAcceptedContribution, SavedWasCommitted, UpdateSafety, VSFedAvgInterface!Safety via FedAvgRefinement!Abs |
| `saved` | FED_CTRL | - | private | FED_CTRL | private | AbnormalTerminationVisible, SavedWasCommitted, VSFedAvgInterface!Safety via FedAvgRefinement!Abs |
| `completed` | FED_COMM | FED_COMM | private | FED_COMM | private (retired assignment LRU) | CompletedHistoryBound |
| `unknownSeen` | FED_CTRL | - | private | FED_CTRL | private (unknown-hook ghost) | ReceiptAfterDecision |
| `dead[c].reported` | FED_COMM | ENV, FED_COMM | port | FED_COMM | private; inputs = dead report / activity from neighbors | - |
| `dead[c].age` | ENV, FED_COMM | ENV, FED_COMM | conflict | FED_COMM | clock-derived; replace ENV write by shared clock + report timestamp | - |
| `dead[c].disconnected` | FED_COMM | FED_COMM | private | FED_COMM | private | EligibleTaskEventuallyDrains |
| `dead[c].serial` | FED_COMM | FED_COMM | private | FED_COMM | private (report-generation ghost) | - |
| `mon.{pc, pending, deadView, reportAges, reportSerial}` | FED_COMM | FED_COMM | private | FED_COMM | private (monitor thread) | AllDeadPolicyUnreached, EligibleTaskEventuallyDrains, RequiredPolicyUnreached |

## Cross-process accesses

Class: (a) real message/content, (b) modeling shortcut/oracle, (c) shared clock.

| Action | Access | Field | Owner | Class | Explanation |
|---|---|---|---|---|---|
| BaseAcceptTrainResult | read | `ct[t][c].result` | FED_CLIENT | a | RESULT_ENVELOPE body return code (OK vs EXECUTION_EXCEPTION); immutable after send, must arrive via APP_CALL arg |
| FedAvgAggregateOneResult | read | `ct[t][c].result` | FED_CLIENT | a | RESULT_ENVELOPE body: params vs empty |
| FedAvgMetricPreparationFailure | read | `ct[t][c].metricKind` | FED_CLIENT | a | RESULT_ENVELOPE body: metrics present |
| FedAvgProcessMetrics | read | `ct[t][c].metricKind` | FED_CLIENT | a | RESULT_ENVELOPE body: metrics present/none/empty |
| FedAvgCommitMetricCoverage | read | `ct[t][c].metricKind` | FED_CLIENT | a | RESULT_ENVELOPE body: metrics none clears allMetrics |
| ServerRunnerTaskRequestActive | read | `ct[t][c].result` | FED_CLIENT | a | ClientCanPoll(c) = CJ decides to send GET_TASK (folded send); real message exists iff CJ idle |
| ServerRunnerTaskRequestActive | read | `net[t][c][n].outcome` | FED_CLIENT | a | ClientCanPoll(c): CJ polls only after its last send ended ack/gone (folded GET_TASK send) |
| WFCommResendTask | read | `ct[t][c].result` | FED_CLIENT | b | ORACLE: SJ sees whether CJ has executed. Source resends whenever result_received_time is None on a re-request (wf_comm_server.py:246-257) |
| WFCommTaskUnavailable | read | `ct[t][c].result` | FED_CLIENT | b | ORACLE mirror of the resend guard (complement of eligible-resend) |
| ServerRunnerCheckTaskActive | read | `net[t][c]` | FED_CLIENT | a | TASK_CHECK message index n (transport attempt correlation) |
| ClientCheckTask | write | `net[t][c][n].outcome` | FED_CLIENT | b | SHORTCUT over real TASK_CHECK_REPLY: SJ writes the CJ's observed outcome atomically (zero-latency, lossless reply; RETRY immediately becomes queued envelope) |
| ClientCheckTask | read | `net[t][c]` | FED_CLIENT | a | TASK_CHECK message index n |
| ServerRunnerProcessSubmission | read | `net[t][c]` | FED_CLIENT | a | RESULT_ENVELOPE index n |
| ClientReceiveTask | write | `ct[t][c].delivery` | FED_COMM | a | TASK_ASSIGNMENT consumed and decoded (wire->ready) |
| ClientProcessTask | write | `net[t][c][n].receipt` | FED_COMM | a | framing: new attempt has no reply yet (NONE) |
| ClientProcessTask | write | `net[t][c][n].stage` | FED_COMM | a | TASK_CHECK(n=1) sent (new attempt record, stage=check) |
| ClientProcessTask | read | `ct[t][c].delivery` | FED_COMM | a | TASK_ASSIGNMENT delivered (CJ inbox half of split field) |
| ClientExecutionError | write | `net[t][c][n].receipt` | FED_COMM | a | framing: no reply yet |
| ClientExecutionError | write | `net[t][c][n].stage` | FED_COMM | a | TASK_CHECK(n=1) sent |
| ClientExecutionError | read | `ct[t][c].delivery` | FED_COMM | a | TASK_ASSIGNMENT delivered (CJ inbox half) |
| ClientRetryResult | write | `net[t][c][n].receipt` | FED_COMM | a | framing: no reply yet |
| ClientRetryResult | write | `net[t][c][n].stage` | FED_COMM | a | TASK_CHECK(n+1) sent after local timeout |
| ServerCommandDispatchAck | read | `net[t][c][n].receipt` | FED_COMM | a | RESULT_RECEIPT body (RECEIVED / TASK_CLOSED) |
| ServerCommandDispatchAck | read | `net[t][c][n].stage` | FED_COMM | a | stage=handled = RESULT_RECEIPT sent and in flight |
| ClientLoseDispatchAck | read | `net[t][c][n].stage` | FED_COMM | b | CJ guard reads SJ stage in {queued,processing,handled}; CJ really knows only 'envelope sent, receipt pending'. Excludes timeouts during TASK_CHECK |
| ClockAdvance | write | `dead[c].age` | FED_COMM | c | 30s tick of report age (saturating at 60s grace) |
| ClockAdvance | write | `task[t].age` | FED_COMM | c | 30s tick of task lead time (saturating at 30s) |
| ClockAdvance | read | `dead[c].reported` | FED_COMM | c | age only advances for reported entries (timestamp exists) |
| ClockAdvance | read | `task[t].scheduled` | FED_COMM | c | age only advances for scheduled tasks (timestamp exists) |
| ClockAdvance | read | `wf.pc` | FED_CTRL | b | clock stops when controller finalized (termination / state-space shortcut) |
| TaskDeliveryFailure | write | `ct[t][c].delivery` | FED_COMM | a | TASK_ASSIGNMENT dropped or undecodable (network/CJ) -> CJ may re-poll; SJ not informed |
| ServerRunnerTaskRequestActive | read | `ct[t][c].delivery` | FED_COMM | a | ClientCanPoll(c) reads the CJ-inbox half of the split delivery field (no undecoded/unexecuted assignment): folded GET_TASK issuance |
| WFCommResendTask | read | `ct[t][c].delivery` | FED_COMM | b | ORACLE for transport loss: SJ cannot observe TaskDeliveryFailure ('failed' via network); only the filter-failure route to 'failed' is SJ-visible |
| WFCommTaskUnavailable | read | `ct[t][c].delivery` | FED_COMM | b | ORACLE mirror of resend guard on delivery state |

## Intra-SJ cross-group accesses (FED_CTRL <-> FED_COMM)

Kinds: call-arg / call / handshake / query / latch / latch-read / frame / frame-reset / shortcut. Grouped by (field, access, kind).

| Field | Access | Owner | Kind | Actions | Explanation |
|---|---|---|---|---|---|
| `wf.pc` | write | FED_CTRL | handshake | WFCommScheduleTask | broadcast() returns to controller (schedule->wait); CTRL half of rendezvous SCHEDULE |
| `wf.round` | read | FED_CTRL | call-arg | WFCommScheduleTask | SCHEDULE(t) with t = current round (seed task=round identity) |
| `wf.sourceVersion` | read | FED_CTRL | call-arg | WFCommScheduleTask | SCHEDULE(..., sourceVersion): global model generation to broadcast |
| `task[t].standing` | read | FED_COMM | query | FedAvgPollStanding | get_num_standing_tasks(); read-only COMM state exported to CTRL |
| `task[t].status` | write | FED_COMM | call | FedAvgCancelFailedTasks | cancel_all_tasks(ERROR): mark-only write on COMM tasks, rendezvous CANCEL_ALL |
| `task[t].standing` | read | FED_COMM | query | FedAvgCancelFailedTasks | callee-side selection of standing tasks inside cancel_all_tasks |
| `wf.abort` | read | FED_COMM | latch-read | FedAvgPollAbort | abort_signal read by controller loop |
| `wf.abort` | write | FED_COMM | latch | BaseModelControllerRunException | system_panic -> ServerRunner.abort (PANIC event, monotone) |
| `comm.pc` | write | FED_COMM | frame | 23 actions (BaseAcceptTrainResult, BaseConvertResult, BaseConvertResultFailure, ...) | callback PC lives in COMM's lock frame; move to CTRL app.pc. Only APP_CALL entry/APP_RETURN exit cross |
| `wf.abort` | write | FED_COMM | latch | BaseAcceptTrainResult | non-OK rc and not resilient -> system_panic (PANIC event, monotone) |
| `comm.id` | read | FED_COMM | call-arg | 15 actions (BaseAcceptTrainResult, BaseConvertResult, FedAvgAggregateOneResult, ...) | APP_CALL argument: clientTask id (t,c) |
| `comm.kind` | read | FED_COMM | frame | 23 actions (BaseAcceptTrainResult, BaseConvertResult, BaseConvertResultFailure, ...) | asserts comm lock held by the submission (comm.kind=submit); implied by an outstanding APP_CALL |
| `comm.accepted` | write | FED_CTRL | frame-reset | 11 actions (WFCommProcessTaskRequest, WFCommResendTask, WFCommPublishClientTask, ...) | EmptyComm reset clears callback-local accepted flag; becomes part of APP_RETURN |
| `comm.key` | write | FED_CTRL | frame-reset | 11 actions (WFCommProcessTaskRequest, WFCommResendTask, WFCommPublishClientTask, ...) | EmptyComm reset clears callback-local key cursor; after split CTRL resets its app frame at APP_CALL |
| `wf.round` | read | FED_CTRL | shortcut | WFCommProcessTaskRequest | COMM picks task via controller round (task=round coincidence); should pick any standing LIVE task from its own table |
| `wf.pc` | read | FED_CTRL | handshake | WFCommMonitorBegin | monitor runs until finalize; 'finalized' becomes COMM-owned after split |
| `wf.pc` | write | FED_CTRL | handshake | ServerRunnerCloseWorkflow | consumes CTRL 'returned' (control_flow returned): rendezvous WORKFLOW_RETURNED |
| `wf.pc` | write | FED_CTRL | handshake | WFCommFinalizeRun | finalize->finalized after communicator drain; CTRL has no further step |

## Seed wire encoding -> port messages

The seed has no message variable. Wire state is spread over `s.net[t][c][n]` (one record per transport attempt `n` of ClientTask `(t,c)`: `stage` = server progress, `outcome` = CJ observation, `receipt` = reply body), `s.ct[t][c].delivery` (assignment send/transit/decode), `s.requested`/`s.runner` (GET_TASK queue/service), and `ct.result/metricKind` (envelope body). Correlation is by array index: a submission in `net[t][c]` is by construction for ClientTask `(t,c)` with attempt `Authority((t,c))`.

| Seed encoding | Transition / action | Message (port) | Dir | Correlation | Content |
|---|---|---|---|---|---|
| `ClientCanPoll(c)` guard + `requested` (+ `dead[c]` cleared) | ServerRunnerTaskRequestActive(c) | GET_TASK (send folded into receipt) | CJ->SJ | site c | none |
| `runner.kind=request, runner.client=c` | ServerRunnerAcquireTaskRequest .. WFCommPublishClientTask/TaskTryAgain/TaskUnavailable | GET_TASK in service under wf_lock | SJ-local | site c | - |
| runner reset with no `ct` change | WFCommTaskTryAgain, WFCommTaskUnavailable | TASK_ASSIGNMENT reply TRY_AGAIN / NO_TASK (implicit; CJ may re-poll) | SJ->CJ | site c | wait time |
| `ct.delivery` none->filter + `ct.header*` | WFCommPublishClientTask | ClientTask registered, outbound filter pending | SJ-local | job, workflow, task name, clientTask=(t,c), serverAttempt=Authority((t,c)), site c, round t-1 | inputVersion = protected broadcast version |
| `ct.delivery` filter->wire | ServerRunnerFilterTask | TASK_ASSIGNMENT(ASSIGNED) sent | SJ->CJ | job, workflow, task name, clientTask=(t,c), serverAttempt=Authority((t,c)), site c, round t-1 | input model generation |
| `ct.delivery` filter->filterFailed->failed (+task CANCELLED) | ServerRunnerFilterFailure, WFCommHandleException | TASK_ASSIGNMENT reply TRY_AGAIN after filter exception | SJ->CJ | site c | - |
| `ct.delivery` wire->ready | ClientReceiveTask | TASK_ASSIGNMENT delivered + decoded | CJ consume | job, workflow, task name, clientTask=(t,c), serverAttempt=Authority((t,c)), site c, round t-1 | - |
| `ct.delivery` wire->failed | TaskDeliveryFailure | TASK_ASSIGNMENT lost / undecodable | network drop | job, workflow, task name, clientTask=(t,c), serverAttempt=Authority((t,c)), site c, round t-1 | - |
| `ct.result`, `ct.metricKind` (written once) | ClientProcessTask, ClientExecutionError | RESULT_ENVELOPE body (retained for all attempts) | CJ-local until sent | job, workflow, task name, clientTask=(t,c), serverAttempt=Authority((t,c)), site c, round t-1 | rc OK|EXECUTION_EXCEPTION, kind params|empty, metrics present|none|empty |
| `net[t][c] := <<NewAttempt>>` / `Append(NewAttempt)` (stage=check) | ClientProcessTask, ClientExecutionError, ClientRetryResult | TASK_CHECK(n) sent | CJ->SJ | job, workflow, task name, clientTask=(t,c), serverAttempt=Authority((t,c)), site c, round t-1, transport attempt n | - |
| `net[n].stage` check->checking | ServerRunnerCheckTaskActive | TASK_CHECK(n) received (activity clears dead[c]) | SJ consume | (t,c,n) | - |
| `net[n]` checking -> [queued, pending, RETRY] | ClientCheckTask | TASK_CHECK_REPLY(RETRY) delivered AND RESULT_ENVELOPE(n) sent+queued (3 steps folded) | SJ->CJ->SJ | (t,c,n) | receipt RETRY; envelope body = ct.result/metricKind |
| `net[n]` checking -> [done, ack, RECEIVED] / [done, gone, TASK_CLOSED] | ClientCheckTask | TASK_CHECK_REPLY(RECEIVED | TASK_CLOSED) delivered and consumed | SJ->CJ | (t,c,n) | receipt |
| `net[n].stage` queued->processing, receipt:=TASK_CLOSED | ServerRunnerProcessSubmission | RESULT_ENVELOPE(n) dequeued under wf_lock (closed if workflow closed/aborted) | SJ consume | (t,c,n) | - |
| `net[n].receipt` := RECEIVED/TASK_CLOSED | ServerRunnerCheckSubmission, WFCommClaimSubmission | RESULT_RECEIPT body being computed | SJ-local | (t,c,n) | receipt |
| `net[n].stage` -> handled | WFCommStampReceipt, WFCommDropSubmission, ServerRunnerRejectSubmission, ServerRunnerDropClosedSubmission | RESULT_RECEIPT(n) sent | SJ->CJ | (t,c,n) | RECEIVED | TASK_CLOSED |
| `net[n].outcome` pending->ack/gone (lost if receipt not terminal: unreachable) | ServerCommandDispatchAck | RESULT_RECEIPT(n) consumed | CJ consume | (t,c,n) | - |
| `net[n].outcome` pending->lost, stage untouched | ClientLoseDispatchAck | submit timeout / receipt loss; server copy continues | CJ-local / network | (t,c,n) | - |
| `ClientCanPoll(c)`: last outcome in {ack,gone} | (guard) | CJ send loop finished (_send_task_result returned) | CJ-local | site c | - |

Gaps vs `VSNetworkV1`: no `TASK_CHECK` / `TASK_CHECK_REPLY` kinds (the seed's readiness check is a separate round-trip before every upload, with its own RETRY/RECEIVED/TASK_CLOSED reply); no transport-attempt correlation field (VS uses `Request("result",c,1)` fixed); TRY_AGAIN/NO_TASK need a `TASK_ASSIGNMENT` body status. In the seed, GET_TASK, TASK_CHECK, TASK_CHECK_REPLY and RESULT_ENVELOPE are never lost or delayed independently; only TASK_ASSIGNMENT (`TaskDeliveryFailure`) and RESULT_RECEIPT/CJ timeout (`ClientLoseDispatchAck`) are. A split network adds those losses unless the port contract forbids them. `VSComposition` itself has CJ-side oracles: `BuildSubmission` and `ReceiveReceipt` read `fedState.assignments[c]`; the assignment correlation must come from the consumed TASK_ASSIGNMENT instead.

## Environment abstractions

| Abstraction | Seed actions / state | What it stands for | Neighbor that should drive it |
|---|---|---|---|
| Trainer result choice | ClientProcessTask(id,kind,mk) nondeterministic kind in {params,empty}, mk in MetricKinds; ClientExecutionError | executor/trainer producing FLModel or raising | Trainer/in-process API (VS InProcessTrainerPublish/BuildSubmission), TaskWorker |
| Eager task input | ClientReceiveTask (decode complete, no pull); inputVersion integer | TASK_ASSIGNMENT payload transfer/materialization at CJ | Payload/transfer (InputDescriptor, PAYLOAD_PULL/REPLY) |
| Eager complete result | ServerRunnerCheckSubmission/WFCommClaimSubmission treat every envelope as complete; LazyOffload only as WeightedParamFailure flag | RESULT_ENVELOPE refs that must be materialized before claim (RETRY while incomplete) | Payload/transfer (MaterializeResult before ClaimResult, RECEIVER_CONFIRM, settlement) |
| Runner/job readiness | Init: wf.open=TRUE, wf.pc=start; every Selected client can poll from the first state | SJ launch + workflow admission; CJ launch/init_run/READY | Job lifecycle (ServerLaunch, WorkflowOpened, Launch, RunnerReady, READY) |
| Fixed cohort / identity | Selected, JobId, WorkflowId constants; t = round; Authority(id) from index | job metadata, controller config, task UUIDs, attempt UUIDs | Job lifecycle + root identity parameters |
| Dead-client reports | WFCommReportDeadClient(c) (MC fault 'dead') | dead-job report from CP/SP for a CJ | Job lifecycle (CJ exit/heartbeat loss -> SP -> SJ) |
| Client activity heartbeat | WFCommClientIsActive(c) | JOB_HEART_BEAT aux / reconnect | CJ client runner heartbeat thread / job lifecycle |
| Direct task cancellation | WFCommCancelTask(t) (MC fault 'cancel') | app/admin cancel_task | Workflow/admin layer or job abort |
| Clock | ClockAdvance: task age 0..1, report age 0..2 (30s grid); stops at finalized | wall clock vs schedule/report timestamps | Shared clock module |
| Network loss | TaskDeliveryFailure, ClientLoseDispatchAck; no loss of GET_TASK/TASK_CHECK/its reply | transport failure/timeouts | Network module (VSNetwork drop/delay) |
| Filters / allocation faults | OutboundFilter, BeforeSendFailure, AllocationFailure, ConversionFailure, LazyOffload flags | configured filters, memory errors, lazy tensor I/O | Filter/payload/object components |
| Persistence | FedAvgSaveModel always succeeds; sourceVersion integer | persistor save, file/object lifetime | Model/object store (NVModels/NVObjects) |
| Run abort / END_RUN | wf.abort only from in-seed panics; no END_RUN to CJ; CJ keeps polling after finalize | admin/job abort, END_RUN, client stop | Job lifecycle (SendEndRun/ReceiveEndRun/StopClientRunner) |

## Port sketches and interaction-preservation obligations

Correlation tuple for all task messages: `(job, workflow, taskName, clientTask=(t,c), serverAttempt, site, round)` plus transport attempt `n` on TASK_CHECK / RESULT_ENVELOPE / replies.

| Port | Message / shared state | Dir | Fields | Seed source |
|---|---|---|---|---|
| CLIENT<->COMM | GET_TASK | CJ->SJ | site | `ClientCanPoll` + `ServerRunnerTaskRequestActive` |
| | TASK_ASSIGNMENT{ASSIGNED, TRY_AGAIN, NO_TASK} | SJ->CJ | corr, inputGeneration (resend keeps corr) | `ServerRunnerFilterTask`, `WFCommTaskTryAgain`, `WFCommTaskUnavailable`, `WFCommHandleException` |
| | TASK_CHECK(n) | CJ->SJ | corr, n | new `net` entry |
| | TASK_CHECK_REPLY(n, RETRY/RECEIVED/TASK_CLOSED) | SJ->CJ | corr, n | `ClientCheckTask` |
| | RESULT_ENVELOPE(n) | CJ->SJ | corr, n, body{rc, kind, metricKind} | `ClientCheckTask` (RETRY branch), `ct.result/metricKind` |
| | RESULT_RECEIPT(n, RECEIVED/TASK_CLOSED) | SJ->CJ | corr, n | stage->handled actions |
| CTRL<->COMM | SCHEDULE(t, sourceVersion) | rendezvous | | `WFCommScheduleTask` |
| | standing(t) / anyStanding | COMM state read by CTRL | | `FedAvgPollStanding` |
| | CANCEL_ALL(ERROR) | rendezvous | | `FedAvgCancelFailedTasks` |
| | APP_CALL(id, attempt, live/unknown, body) | COMM->CTRL (COMM blocked) | | `WFCommDispatchSubmission` |
| | APP_RETURN(id, accepted/rejected/unknown-done) | CTRL->COMM | | `BaseClearTrainingResult`, `BaseProcessUnknownResult` |
| | PANIC -> abort latch; latch read | CTRL->COMM; COMM state | | `BaseAcceptTrainResult`, `BaseModelControllerRunException`, `FedAvgPollAbort` |
| | WORKFLOW_RETURNED(outcome) | rendezvous | | `ServerRunnerCloseWorkflow` |
| ENV->COMM | DEAD_JOB_REPORT(site), CLIENT_ACTIVE(site), CANCEL(t), clock | input | | `WFCommReportDeadClient`, `WFCommClientIsActive`, `WFCommCancelTask`, `ClockAdvance` |

### What a COARSE variant must still reproduce on its ports

**FED_CLIENT coarse** (e.g. receive+execute+submit collapsed): GET_TASK only when idle and again after TRY_AGAIN/NO_TASK/lost assignment (this drives resend); one result per (clientTask, attempt) chosen from {OK params, OK empty, EXECUTION_EXCEPTION} x metricKind; every transport attempt starts with TASK_CHECK and keeps the same authority; RETRY -> envelope, RECEIVED -> ack, TASK_CLOSED -> gone; a local timeout while awaiting RESULT_RECEIPT followed by attempt n+1 while the old envelope is still queued/processing at SJ (overlapping attempts are the duplicate-submission path).

**FED_COMM coarse** (e.g. atomic request handling, atomic check+claim+dispatch, one-step monitor): TRY_AGAIN for prepare/snapshot/filter failure and non-LIVE task; resend with the same authority; TASK_CHECK_REPLY by state (known & unclaimed RETRY, claimed RECEIVED, evicted/closed/aborted/unknown TASK_CLOSED, retired-in-history RETRY/RECEIVED); one RESULT_RECEIPT per processed envelope, RECEIVED for duplicates without a second APP_CALL; a stale queued attempt processed after the client moved on; APP_CALL(live) at most once and only for a standing LIVE task; APP_CALL(unknown) at most once per assignment, for the first claimed result whose task is retired-in-history or no longer LIVE; no new admission once the workflow is closed or aborted (TASK_CLOSED), while a submission admitted earlier still claims and dispatches; **retirement between claim and dispatch** (claimed, decision pending, no finish timestamp, client counted outstanding); **no retirement while APP_CALL outstanding**; retirement outcomes OK / CLIENT_DEAD (all outstanding disconnected after lead time) / CANCELLED / ERROR with `retiredOutstanding`; dead-policy PANIC (all dead, < MinSites, required site) before task checks; finalize cancels standing tasks, clears history, and closes later submissions.

**FED_CTRL coarse** (e.g. one-step callback, one-step round close+publish): one SCHEDULE per round and the next only after no standing task; exactly one APP_RETURN per APP_CALL before COMM stamps; rejection for rc error (+PANIC unless resilient, failedClients in dynamic mode, reset at next broadcast), conversion failure, empty params, shape mismatch (safe: no round failure), failed/closed round; param/metric failure: partial state kept, round failed, CANCEL_ALL(ERROR), outcome error, **no publication**; abort: round closed (later live APP_CALLs rejected), outcome aborted; zero accepted: error, no publication; APP_CALL(unknown): no aggregation/count/decision; close waits for a callback holding the round lock; after an abort-close, an admitted live APP_CALL returns rejected (closed round).

### Failure outcomes in the fine seed (must survive in some variant mix)

| Outcome | Fine actions | Port effect | Group |
|---|---|---|---|
| client timeout / lost receipt | `ClientLoseDispatchAck`, `ClientRetryResult` | RESULT_RECEIPT unconsumed; TASK_CHECK(n+1) | CLIENT |
| assignment lost | `TaskDeliveryFailure` -> re-poll -> `WFCommResendTask` | TASK_ASSIGNMENT drop; resend same corr | ENV/COMM |
| filter / prepare / snapshot failure | `ServerRunnerFilterFailure`+`WFCommHandleException`, `BasePrepareTaskDataFailure`, `WFCommProtectBroadcastFailure` | TRY_AGAIN; task CANCELLED/ERROR | COMM |
| failed client (rc error) | `ClientExecutionError` -> `BaseAcceptTrainResult` | envelope rc; APP_RETURN rejected; PANIC unless resilient | CLIENT/CTRL |
| rejected contribution | conversion, shape, empty, round failed/closed | APP_RETURN rejected; still RESULT_RECEIPT RECEIVED | CTRL |
| partial contribution -> round failure | `WeightedParamFailure`, `WeightedMetricFailure`, `FedAvgMetricPreparationFailure` -> `FedAvgCancelFailedTasks` -> `BaseModelControllerRunException` | CANCEL_ALL(ERROR), PANIC, WORKFLOW_RETURNED(error), no publish | CTRL |
| zero accepted | `FedAvgRejectEmptyRound` | PANIC, WORKFLOW_RETURNED(error) | CTRL |
| dead client / policy panic | `WFCommReportDeadClient`, monitor chain, `WFCommJobPolicyDecision` | task CLIENT_DEAD; PANIC | COMM |
| direct cancel | `WFCommCancelTask` | task CANCELLED (admitted callback continues) | COMM |
| late result (retired, in history) | `ClientCheckTask`/`ServerRunnerCheckSubmission` known via history, `WFCommDispatchSubmission`->unknown | APP_CALL(unknown) once; RECEIVED | COMM/CTRL |
| evicted / closed / aborted | `ServerRunnerProcessSubmission`(closed), `ServerRunnerRejectSubmission`, `ServerRunnerDropClosedSubmission` | TASK_CLOSED | COMM |
| duplicate submission | `ServerRunnerCheckSubmission` (claimed) | RECEIVED, no APP_CALL | COMM |

## Properties

| Property | Module | Kind | Fields | Scope | Note |
|---|---|---|---|---|---|
| TypeOK | base | invariant | all fields | spans:FED_CLIENT+FED_COMM+FED_CTRL | structural; split per group |
| ProtectedBroadcastInput | base | invariant | ct[t][c].assigned, ct[t][c].headerId, ct[t][c].headerRound, ct[t][c].inputVersion, task[t].broadcastVersion, task[t].sourceAtSchedule | local:FED_COMM | COMM-local given SCHEDULE arg |
| AtMostOneConsumer | base | invariant | ct[t][c].invocations | local:FED_CTRL | ghost in CTRL, guaranteed by COMM claim dedup: cross-group contract 'APP_CALL(live) at most once' |
| ReceiptAfterDecision | base | invariant | ct[t][c].decision, ct[t][c].receipt, unknownSeen | spans:FED_COMM+FED_CTRL | COMM stamps only after APP_RETURN |
| ClaimBeforeFinish | base | invariant | ct[t][c].claimed, ct[t][c].receipt | local:FED_COMM |  |
| CommittedRoundProvenance | base | invariant | committed, ct[t][c].assigned, ct[t][c].headerRound, used[t] | spans:FED_COMM+FED_CTRL | CTRL publication vs COMM authority |
| CommittedAcceptanceConsistency | base | invariant (hunting cfgs) | committed, ct[t][c].decision, ct[t][c].metricKind, used[t] | spans:FED_CLIENT+FED_CTRL | local to CTRL if CTRL records envelope metricKind with each contribution |
| AbnormalTerminationVisible | base | invariant (hunting cfgs) | saved, task[t].retiredOutstanding, task[t].retiredStatus, wf.outcome, wf.started | spans:FED_COMM+FED_CTRL | COMM retirement vs CTRL publication |
| OneStandingTask | base | invariant | task[t].standing | local:FED_COMM |  |
| CompletedHistoryBound | base | invariant | completed, ct[t][c].assigned, task[t].status | local:FED_COMM |  |
| CallbackRoundIsolation | base | invariant | aggr.task, comm.id, comm.kind, comm.pc, task[t].standing, wf.round | spans:FED_COMM+FED_CTRL | protocol property of the CTRL/COMM cut: APP_CALL only for current round's standing task |
| CallerLockDiscipline | base | invariant | comm.kind, runner.kind | local:FED_COMM |  |
| SavedWasCommitted | base | invariant | committed, saved | local:FED_CTRL |  |
| CountMatchesSuccessfulReturns | base | invariant | aggr.counted, aggr.receivedCount | local:FED_CTRL |  |
| CallbacksTerminate | base | temporal assumption | runner.kind | local:FED_COMM | needs CTRL callback termination (APP_RETURN) to discharge |
| EligibleTaskEventuallyDrains | base | liveness (incomplete, conditional) | ct[t][c].receipt, dead[c].disconnected, mon.pc, task[t].age, task[t].scheduled, task[t].standing, task[t].status, wf.pc | spans:FED_COMM+FED_CTRL | wf.pc only for 'finalized' (COMM after split) |
| MessageBufferBound | MC | state constraint | net[t][c][n].stage | wire (FED_CLIENT<->FED_COMM) | wire bound; becomes bound on in-flight messages |
| DynamicErrorSignalsAbort | MC | invariant (diagnostic) | aggr.failedClients, wf.abort | spans:FED_COMM+FED_CTRL | CTRL policy vs runner abort latch |
| CommittedValuesAccepted | MC | invariant (diagnostic) | committed, ct[t][c].decision, used[t] | local:FED_CTRL |  |
| ReceiptRequiresClaim | Update | invariant | ct[t][c].claimed, ct[t][c].receipt | local:FED_COMM | = ClaimBeforeFinish |
| AssignmentAuthorityPreserved | Update | invariant | ct[t][c].assigned, ct[t][c].headerAttempt, ct[t][c].job, ct[t][c].workflow | local:FED_COMM |  |
| NoFailedRoundPublished | Update | invariant | aggr.failed, aggr.task, committed | local:FED_CTRL |  |
| PublishedHasAcceptedContribution | Update | invariant | committed, used[t] | local:FED_CTRL |  |
| NoDuplicateConsumer | Update | invariant | ct[t][c].invocations | local:FED_CTRL | = AtMostOneConsumer |
| PublishedContributionsAccepted | Update | invariant | committed, ct[t][c].decision, ct[t][c].metricKind, used[t] | spans:FED_CLIENT+FED_CTRL | = CommittedAcceptanceConsistency |
| UpdateSafety | Update | invariant (conjunction) | aggr.failed, committed, ct[t][c].assigned, ct[t][c].claimed, ct[t][c].decision, ct[t][c].headerAttempt, ct[t][c].invocations, ct[t][c].metricKind, ct[t][c].receipt, used[t] | spans:FED_CLIENT+FED_COMM+FED_CTRL | conjunction of the six Update invariants |
| SnapshotFaultUnreached | Campaigns | reachability canary |  | mc-counter (FED_COMM fault) | MC fault counter only |
| MetricValueFaultUnreached | Campaigns | reachability canary |  | mc-counter (FED_CTRL fault) | MC fault counter only |
| RequiredPolicyUnreached | Campaigns | reachability canary | mon.deadView, mon.pc | local:FED_COMM |  |
| AllDeadPolicyUnreached | Campaigns | reachability canary | mon.deadView, mon.pc | local:FED_COMM |  |
| VSFedAvgInterface!Safety via FedAvgRefinement!Abs | vertical-slice | refinement (success-only subset) | aggr.closed, aggr.counted, committed, ct[t][c].assigned, ct[t][c].claimed, ct[t][c].decision, ct[t][c].delivery, ct[t][c].headerAttempt, ct[t][c].headerId, ct[t][c].headerRound, ct[t][c].inputVersion, ct[t][c].job, ct[t][c].receipt, ct[t][c].result, ct[t][c].workflow, saved, task[t].scheduled, wf.open, wf.round | spans:FED_CLIENT+FED_COMM+FED_CTRL | monolithic coarse FedAvg; 1 round, strict, all-required, success actions only; no failure outcomes |

## Hardest problems for splitting

1. s.net[t][c][n] is endpoint state + channel in one record (stage=SJ, outcome=CJ, receipt=reply); ClientCheckTask folds SJ answer, CJ consumption and envelope upload into one step, and ServerRunnerTaskRequestActive folds the CJ GET_TASK send. Splitting adds interleavings the 34 traces never exercised and their single 'server' events must be re-mapped.
2. ct.delivery merges SJ filter stage, network transit and CJ decode; the resend guard reads it plus ct.result as a cooperative-client oracle. Replacing it with the real SJ rule (resend while no finish timestamp) plus a CJ 'poll only when idle' gate must not re-introduce re-execution of a claimed task; needs a refinement check against the seed.
3. The application callback (23 actions) runs inside COMM's lock frame (comm.kind/pc/key/accepted). The CTRL/COMM cut becomes a blocking APP_CALL/APP_RETURN, and CallbackRoundIsolation plus 'standing=FALSE only after APP_RETURN' are cross-group protocol properties that every coarse COMM/CTRL must preserve.
4. wf.pc is a handshake for 4 COMM actions (schedule, close, finalize, monitor/clock stop); wf.abort is a 3-writer latch (2 CTRL panics, 1 COMM policy panic) read on both sides and later also driven by NVJobs.
5. Identity is encoded by index (t=round, (t,c,n) correlation, Authority from index): ports need explicit correlation fields; VSNetworkV1 has no TASK_CHECK/TASK_CHECK_REPLY kinds and no transport-attempt field; VSComposition's BuildSubmission/ReceiveReceipt read fedState.assignments from CJ (oracle).
6. Existing coarse interface/refinement is monolithic and success-only (1 round, strict, all-required, MetricKinds={none}); per-group coarse variants with failure outcomes and their refinement maps do not exist yet.

## Property locality (summary)

Local to FED_COMM: ProtectedBroadcastInput, ClaimBeforeFinish/ReceiptRequiresClaim, OneStandingTask, CompletedHistoryBound, CallerLockDiscipline, AssignmentAuthorityPreserved, Required/AllDead canaries, CallbacksTerminate (stated on `runner.kind`, but discharged only if CTRL returns). Local to FED_CTRL: SavedWasCommitted, CountMatchesSuccessfulReturns, NoFailedRoundPublished, PublishedHasAcceptedContribution, CommittedValuesAccepted, AtMostOneConsumer/NoDuplicateConsumer (ghost in CTRL, but *guaranteed* by COMM's claim dedup -> becomes an APP_CALL-at-most-once contract). Spanning: ReceiptAfterDecision (COMM+CTRL), CommittedRoundProvenance (CTRL+COMM), CommittedAcceptanceConsistency (CTRL+CLIENT body; local if CTRL records `metricKind` from the APP_CALL body), AbnormalTerminationVisible (COMM retirement vs CTRL publication), CallbackRoundIsolation (protocol property of the CTRL/COMM cut), DynamicErrorSignalsAbort (CTRL policy vs abort latch), EligibleTaskEventuallyDrains (COMM + `finalized`), MessageBufferBound (wire), UpdateSafety and the VS coarse Safety via `FedAvgRefinement!Abs` (all three groups).

## Re-encoding needed before any variant can be swapped

1. Replace `s.net` by explicit messages + per-endpoint state: CJ attempt list with `outcome`; SJ per-received-attempt `stage` and reply body. Split `ClientCheckTask` into SJ AnswerTaskCheck / CJ ObserveCheckReply / CJ SendEnvelope, and `ServerRunnerTaskRequestActive` into CJ SendGetTask / SJ ReceiveGetTask.
2. Split `ct.delivery` into COMM `sendStage` and CJ `inbox`; replace the resend oracle by the source rule (resend on re-request while the ClientTask has no finish timestamp) and keep "one result per assignment" on the CJ side; check by refinement that no new re-execution behavior appears.
3. Move callback-local `comm.pc` stages, `comm.key`, `comm.accepted`, `ct.decision`, `ct.invocations`, `unknownSeen` into a CTRL app frame/contribution record; COMM keeps `comm.pc in {..., inApp, receipt, drop}`; APP_CALL carries the envelope body so CTRL never reads CJ state.
4. Make `wf.abort` a COMM-owned latch with PANIC inputs (also from NVJobs later); give COMM its own `open`/`finalized`; turn the four `wf.pc` handshakes into rendezvous halves.
5. Replace `ClockAdvance` writes with a shared clock and COMM-held timestamps; drop the `wf.pc /= "finalized"` guard in favor of an explicit stop.
6. Make identity explicit (task id independent of round; corr tuple + n on every message) and add TASK_CHECK kinds and a transport-attempt field to the network schema.
