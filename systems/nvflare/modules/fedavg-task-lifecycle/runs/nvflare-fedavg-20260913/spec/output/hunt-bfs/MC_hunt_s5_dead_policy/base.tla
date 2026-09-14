------------------------------ MODULE base ------------------------------
EXTENDS Naturals, Integers, Sequences, FiniteSets, TLC

(***************************************************************************
 Category A. NVIDIA/NVFlare 53ba7ee567468ea7971dad4faccef13c6cb35dc2.
 Paths in annotations are relative to the pinned source root.
 S1..S5 refer to modeling-brief.md section 2. See modeling-notes.md.
 One built-in FedAvg task per round; fixed selected cohort; cooperative IDs.
 Zero task timeout, all selected responses, no response grace, no early stop.
 Task t represents current_round=t-1. No numerical/convergence assertions.
 s.comm retains _controller_lock; request/submit ALSO retain runner wf_lock.
 Direct cancellation, clock and round thread remain independent.
 Every action uses one record update so all other fields are UNCHANGED.
 Provenance/PC fields are observation ghosts, never desired-outcome guards.
***************************************************************************)
CONSTANTS Clients, Selected, NumRounds, NumKeys, HistoryLimit,
          ErrorMode, OutboundFilter, LazyOffload, AllocationFailure,
          ConversionFailure, BeforeSendFailure, AllowEmpty, MetricKinds,
          MinSites, RequiredSites, AllowPartialCompletion

Tasks == 1..NumRounds
Keys == 1..NumKeys
Ids == Tasks \X Clients
NoId == <<0, "">>
SeqSet(q) == {q[i] : i \in 1..Len(q)}
ClientIds(t) == {<<t,c>> : c \in Selected}
Statuses == {"NEW", "LIVE", "OK", "ERROR", "CANCELLED", "CLIENT_DEAD"}
Abnormal == {"ERROR", "CANCELLED", "CLIENT_DEAD"}
Decisions == {"pending", "accepted", "rejected"}
DeliveryStates == {"none", "filter", "filterFailed", "wire", "ready", "failed"}
AttemptStates == {"check", "checking", "queued", "handled", "ack", "lost", "gone"}
WfPCs == {"start", "reset", "schedule", "wait", "abortPoll", "aggregate",
          "params", "metrics", "build", "update", "save", "advance",
          "returned", "finalize", "finalized"}
CommPCs == {"idle", "before", "snapshot", "canSend", "publish", "tryAgain",
            "dispatch", "prelim", "convert", "consumer", "paramStats",
            "paramValue", "paramHistory", "metrics", "metricStats",
            "metricValue", "metricHistory", "count", "decision", "cleanup",
            "receipt", "drop", "unknown", "select", "deadScan", "mark",
            "remove", "exitCleanup"}
MonPCs == {"idle", "dead", "policy", "decide", "acquire", "locked", "stopped"}
ASSUME /\ IsFiniteSet(Clients) /\ Clients /= {} /\ "" \notin Clients
       /\ Selected \subseteq Clients /\ Selected /= {}
       /\ NumRounds \in Nat \ {0} /\ NumKeys \in Nat \ {0}
       /\ HistoryLimit \in Nat \ {0}
       /\ ErrorMode \in {"dynamic", "strict", "resilient"}
       /\ MetricKinds \subseteq {"present", "none", "empty"} /\ MetricKinds /= {}
       /\ MinSites \in 0..Cardinality(Clients) /\ RequiredSites \subseteq Clients
       /\ \A b \in {OutboundFilter, LazyOffload, AllocationFailure,
                    ConversionFailure, BeforeSendFailure, AllowEmpty,
                    AllowPartialCompletion} : b \in BOOLEAN

VARIABLE s
vars == <<s>>

EmptyRunner == [kind |-> "free", pc |-> "idle", client |-> "", id |-> NoId, attempt |-> 0]
EmptyComm == [kind |-> "free", pc |-> "idle", id |-> NoId, attempt |-> 0,
              key |-> 1, accepted |-> FALSE, exit |-> "LIVE", writeStatus |-> FALSE,
              pending |-> {}, deadView |-> {}]
EmptyAggregate(t) == [task |-> t, applied |-> [k \in Keys |-> <<>>],
    stats |-> [k \in Keys |-> <<>>], paramHistory |-> <<>>,
    metricApplied |-> <<>>, metricStats |-> <<>>, metricHistory |-> <<>>,
    allMetrics |-> TRUE, receivedCount |-> 0, counted |-> <<>>, failedClients |-> {}]
EmptyUsed == [params |-> [k \in Keys |-> <<>>], stats |-> [k \in Keys |-> <<>>],
    paramHistory |-> <<>>, metrics |-> <<>>, metricStats |-> <<>>,
    metricHistory |-> <<>>, allMetrics |-> TRUE, count |-> 0, counted |-> <<>>]
EmptyClient == [assigned |-> FALSE, headerId |-> NoId, headerRound |-> -1,
    inputVersion |-> -1, delivery |-> "none", result |-> "none", metricKind |-> "none",
    receipt |-> FALSE, decision |-> "pending", invocations |-> 0]
EmptyTask == [scheduled |-> FALSE, standing |-> FALSE, status |-> "NEW",
    sourceAtSchedule |-> -1, broadcastVersion |-> -1, assignedOrder |-> <<>>,
    age |-> 0, cleaned |-> FALSE, retiredStatus |-> "NEW", retiredOutstanding |-> {}]

\* S1-S5: constructor/bootstrap state, wf_comm_server.py:92-112;
\* fedavg.py:143-151,170-186; weighted_aggregation_helper.py:129-147.
Init == s = [
    wf |-> [round |-> 0, pc |-> "start", sourceVersion |-> 0, started |-> {},
            abort |-> FALSE, outcome |-> "running", open |-> TRUE],
    task |-> [t \in Tasks |-> EmptyTask],
    ct |-> [t \in Tasks |-> [c \in Clients |-> EmptyClient]],
    net |-> [t \in Tasks |-> [c \in Clients |-> <<>>]],
    comm |-> EmptyComm, runner |-> EmptyRunner, requested |-> {}, aggr |-> EmptyAggregate(0), scratch |-> EmptyUsed,
    used |-> [t \in Tasks |-> EmptyUsed], committed |-> {}, saved |-> {},
    completed |-> <<>>, unknownSeen |-> {},
    dead |-> [c \in Clients |-> [reported |-> FALSE, age |-> 0, disconnected |-> FALSE]],
    mon |-> [pc |-> "idle", pending |-> {}, deadView |-> {}, reportAges |-> [c \in Clients |-> 0]]]

CT(id) == s.ct[id[1]][id[2]]
Outstanding(t) == {c \in Selected : ~s.ct[t][c].receipt}
Disconnected == {c \in Clients : s.dead[c].disconnected}
RunnerLockFree == s.runner.kind = "free"
LiveMap(id) == s.task[id[1]].standing /\ CT(id).assigned
AcceptedIds(t) == {id \in ClientIds(t) : CT(id).decision = "accepted"}
HasAggregate == \E k \in Keys : s.aggr.applied[k] /= <<>>
\* S2 cooperative client sequencing: client_runner.py:515-526,548-588.
\* Fetch/process/send returns before the next poll; retries remain in send loop.
ClientCanPoll(c) == \A t \in Tasks :
    /\ ~(s.ct[t][c].delivery \in {"filter","filterFailed","wire","ready"}
         /\ s.ct[t][c].result = "none")
    /\ (s.net[t][c] /= <<>> => s.net[t][c][Len(s.net[t][c])] \in {"ack","gone"})

\* S2: real LRU insertion/touch, wf_comm_server.py:397-412. Reduced capacity
\* is a configuration abstraction, NOT execution of 10000 cache entries.
Touch(q,id) == Append(SelectSeq(q, LAMBDA x : x /= id), id)
Trim(q) == IF Len(q) <= HistoryLimit THEN q
           ELSE SubSeq(q, Len(q)-HistoryLimit+1, Len(q))
Remember(t) == Trim(s.completed \o
    SelectSeq(s.task[t].assignedOrder, LAMBDA id : CT(id).receipt))

\* nvflare/app_common/workflows/fedavg.py:186-195
\* S1/S4: enter loop and publish ROUND_STARTED; no abort or task-status guard here.
FedAvgRoundStarted ==
    /\ s.wf.pc = "start" /\ s.wf.round < NumRounds
    /\ s' = [s EXCEPT !.wf.round = @+1, !.wf.pc = "reset",
                     !.wf.started = @ \cup {s.wf.round+1}]

\* nvflare/app_common/workflows/fedavg.py:197-212
\* S3/S4: selected cohort fixed by configuration; reset helpers and callback count.
FedAvgResetAggregation ==
    /\ s.wf.pc = "reset"
    /\ s' = [s EXCEPT !.aggr = EmptyAggregate(s.wf.round),
                     !.scratch = EmptyUsed, !.wf.pc = "schedule"]

\* nvflare/app_common/workflows/base_model_controller.py:142-158,188-221; nvflare/apis/impl/wf_comm_server.py:531-575
\* S1/S5: broadcast publication; snapshot is not yet made; source model stays separate.
WFCommScheduleTask ==
    /\ s.wf.pc = "schedule"
    /\ (s.comm.kind /= "monitor" \/ s.comm.pc = "exitCleanup")
    /\ ~s.task[s.wf.round].scheduled
    /\ s' = [s EXCEPT !.task[s.wf.round].scheduled = TRUE,
         !.task[s.wf.round].standing = TRUE, !.task[s.wf.round].status = "LIVE",
         !.task[s.wf.round].sourceAtSchedule = s.wf.sourceVersion, !.wf.pc = "wait"]

\* nvflare/private/fed/server/server_runner.py:385-421; nvflare/apis/impl/wf_comm_server.py:209-283; nvflare/apis/impl/task_manager.py:61-70
\* S1: admit first retrieval under runner/communicator locks; one active task; supported selected client.
WFCommProcessTaskRequest(c) ==
    /\ s.wf.open /\ s.comm.kind = "free" /\ s.wf.round \in Tasks
    /\ s.runner.kind = "request" /\ s.runner.pc = "commWait" /\ s.runner.client = c
    /\ s.task[s.wf.round].standing /\ s.task[s.wf.round].status = "LIVE"
    /\ c \in Selected /\ ~s.ct[s.wf.round][c].assigned
    /\ s.ct[s.wf.round][c].delivery = "none"
    /\ s' = [s EXCEPT !.comm = [EmptyComm EXCEPT !.kind = "request",
                               !.pc = "before", !.id = <<s.wf.round,c>>]]

\* nvflare/apis/impl/wf_comm_server.py:230-241,277-370
\* S1/S2: retry after failed outbound delivery, preserving ClientTask ID; no duplicate retraining is assumed.
WFCommResendTask(id) ==
    /\ s.wf.open /\ s.comm.kind = "free" /\ LiveMap(id)
    /\ s.runner.kind = "request" /\ s.runner.pc = "commWait" /\ s.runner.client = id[2]
    /\ s.task[id[1]].status = "LIVE" /\ ~CT(id).receipt
    /\ CT(id).delivery = "failed" /\ CT(id).result = "none"
    /\ s' = [s EXCEPT !.comm = [EmptyComm EXCEPT !.kind = "request",
                                 !.pc = "before", !.id = id]]

\* nvflare/app_common/workflows/base_model_controller.py:225-228; nvflare/apis/impl/wf_comm_server.py:281-298
\* S1: BEFORE_TRAIN_TASK returns normally; no arbitrary shared input mutation.
BasePrepareTaskData ==
    /\ s.comm.kind = "request" /\ s.comm.pc = "before"
    /\ s' = [s EXCEPT !.comm.pc = "snapshot"]

\* nvflare/apis/impl/wf_comm_server.py:281-314
\* S4: declared before-send event-handler runtime error marks ERROR; deepcopy is still attempted.
BasePrepareTaskDataFailure ==
    /\ BeforeSendFailure /\ s.comm.kind = "request" /\ s.comm.pc = "before"
    /\ s' = [s EXCEPT !.task[s.comm.id[1]].status = "ERROR", !.comm.pc = "snapshot"]

\* nvflare/apis/impl/wf_comm_server.py:305-324
\* S1: first retrieval deep-copies task data once; subsequent retrievals reuse the protected version.
WFCommProtectBroadcast ==
    /\ s.comm.kind = "request" /\ s.comm.pc = "snapshot"
    /\ s' = [s EXCEPT !.task[s.comm.id[1]].broadcastVersion =
             IF @ = -1 THEN s.task[s.comm.id[1]].sourceAtSchedule ELSE @,
             !.comm.pc = "canSend"]

\* nvflare/apis/impl/wf_comm_server.py:313-324
\* S4: ordinary deepcopy allocation failure; no unprotected send fallback.
WFCommProtectBroadcastFailure ==
    /\ AllocationFailure /\ s.comm.kind = "request" /\ s.comm.pc = "snapshot"
    /\ s.task[s.comm.id[1]].broadcastVersion = -1
    /\ s' = [s EXCEPT !.task[s.comm.id[1]].status = "ERROR", !.comm.pc = "canSend"]

\* nvflare/apis/impl/wf_comm_server.py:327-345; nvflare/app_common/workflows/base_model_controller.py:213-221
\* S1/S4: selected Task has no after-send callback; final status check precedes task-map publication.
WFCommCheckCanSend ==
    /\ s.comm.kind = "request" /\ s.comm.pc = "canSend"
    /\ s' = [s EXCEPT !.comm.pc = IF s.task[s.comm.id[1]].status = "LIVE"
                                THEN "publish" ELSE "tryAgain"]

\* nvflare/apis/impl/wf_comm_server.py:349-370; nvflare/apis/shareable.py:157-173; nvflare/private/fed/server/server_runner.py:411-421,325-331
\* S1: copy per-client headers and publish the envelope; payload still awaits outer filtering/delivery. Release both locks.
WFCommPublishClientTask ==
    /\ s.comm.kind = "request" /\ s.comm.pc = "publish"
    /\ LET id == s.comm.id IN
       s' = [s EXCEPT !.task[id[1]].assignedOrder =
                   IF CT(id).assigned THEN @ ELSE Append(@,id),
            !.ct[id[1]][id[2]].assigned = TRUE,
            !.ct[id[1]][id[2]].headerId = id,
            !.ct[id[1]][id[2]].headerRound = id[1]-1,
            !.ct[id[1]][id[2]].inputVersion = s.task[id[1]].broadcastVersion,
            !.ct[id[1]][id[2]].delivery = "filter", !.comm = EmptyComm, !.runner = EmptyRunner]

\* nvflare/apis/impl/wf_comm_server.py:340-345
\* S4: failed preparation returns TRY_AGAIN without registering a new client task.
WFCommTaskTryAgain ==
    /\ s.comm.kind = "request" /\ s.comm.pc = "tryAgain"
    /\ s' = [s EXCEPT !.comm = EmptyComm, !.runner = EmptyRunner]

\* nvflare/private/fed/server/server_runner.py:329-371
\* S1/S4: no filter or successful configured filter; modeled filters preserve logical model provenance.
ServerRunnerFilterTask(id) ==
    /\ CT(id).delivery = "filter"
    /\ s' = [s EXCEPT !.ct[id[1]][id[2]].delivery = "wire"]

\* nvflare/private/fed/server/server_runner.py:333-350
\* S4: configured outbound filter raises an ordinary runtime exception; cancellation is a later lock-taking step.
ServerRunnerFilterFailure(id) ==
    /\ OutboundFilter /\ CT(id).delivery = "filter"
    /\ s' = [s EXCEPT !.ct[id[1]][id[2]].delivery = "filterFailed"]

\* nvflare/private/fed/server/server_runner.py:350-356; nvflare/apis/impl/wf_comm_server.py:372-390,794-812
\* S4: acquire runner wf_lock (not communicator lock); cancel only if client-task mapping still exists; no run abort.
WFCommHandleException(id) ==
    /\ CT(id).delivery = "filterFailed" /\ RunnerLockFree
    /\ (s.comm.kind /= "monitor" \/ s.comm.pc = "exitCleanup")
    /\ s' = [s EXCEPT !.task[id[1]].status =
           IF s.wf.open /\ LiveMap(id) THEN "CANCELLED" ELSE @,
           !.ct[id[1]][id[2]].delivery = "failed"]

\* nvflare/private/fed/client/client_runner.py:225-248; nvflare/private/fed/server/server_runner.py:371
\* S1/S2: delivery and decode complete for this envelope; assignment alone promises neither.
ClientReceiveTask(id) ==
    /\ CT(id).delivery = "wire"
    /\ s' = [s EXCEPT !.ct[id[1]][id[2]].delivery = "ready"]

\* nvflare/private/fed/server/server_runner.py:371; nvflare/private/fed/client/client_runner.py:225-248
\* S1/S4 payload interface: ordinary envelope delivery failure before execution; no byte/chunk model.
TaskDeliveryFailure(id) ==
    /\ CT(id).delivery = "wire"
    /\ s' = [s EXCEPT !.ct[id[1]][id[2]].delivery = "failed"]

\* nvflare/private/fed/client/client_runner.py:225-248; nvflare/app_common/workflows/fedavg.py:268-273,306-326
\* S2/S3: cooperative FULL reply, same task ID/cookie and round; one result per client-task; empty parameters can be deliberately skipped.
ClientProcessTask(id, kind, mk) ==
    /\ CT(id).delivery = "ready" /\ CT(id).result = "none"
    /\ kind \in (IF AllowEmpty THEN {"params","empty"} ELSE {"params"})
    /\ mk \in MetricKinds
    /\ s' = [s EXCEPT !.ct[id[1]][id[2]].result = kind,
                     !.ct[id[1]][id[2]].metricKind = mk,
                     !.net[id[1]][id[2]] = <<"check">>]

\* nvflare/private/fed/client/client_runner.py:225-248
\* S5: ordinary executor exception produces a nonfatal-to-runner EXECUTION_EXCEPTION reply with original identity.
ClientExecutionError(id) ==
    /\ CT(id).delivery = "ready" /\ CT(id).result = "none"
    /\ s' = [s EXCEPT !.ct[id[1]][id[2]].result = "error",
                     !.net[id[1]][id[2]] = <<"check">>]

\* nvflare/private/fed/client/client_runner.py:615-630; nvflare/private/fed/server/server_runner.py:585-605
\* S2: task-check precedes submission; terminal-but-still-mapped tasks return OK; delayed checked sends may arrive after retirement.
ClientCheckTask(id, n) ==
    /\ n \in 1..Len(s.net[id[1]][id[2]]) /\ s.net[id[1]][id[2]][n] = "checking"
    /\ RunnerLockFree /\ (s.comm.kind /= "monitor" \/ s.comm.pc = "exitCleanup")
    /\ s' = [s EXCEPT !.net[id[1]][id[2]][n] =
                 IF s.wf.open /\ LiveMap(id) THEN "queued" ELSE "gone"]

\* nvflare/private/fed/client/client_runner.py:590-637
\* S2: retry after ambiguous/lost reply; retain task identity, re-check mapping; the old queued dispatch may still finish.
ClientRetryResult(id) ==
    /\ s.net[id[1]][id[2]] /= <<>>
    /\ s.net[id[1]][id[2]][Len(s.net[id[1]][id[2]])] = "lost"
    /\ s' = [s EXCEPT !.net[id[1]][id[2]] = Append(@,"check")]

\* nvflare/private/fed/server/server_runner.py:460-475.
\* S2/S4: runner admission is checked once under wf_lock; abort sets status=done.
ServerRunnerProcessSubmission(id, n) ==
    /\ n \in 1..Len(s.net[id[1]][id[2]]) /\ s.net[id[1]][id[2]][n] = "queued"
    /\ RunnerLockFree
    /\ s' = [s EXCEPT !.runner = [EmptyRunner EXCEPT !.kind = "submit",
              !.pc = IF s.wf.open /\ ~s.wf.abort THEN "activity" ELSE "closed",
              !.id = id, !.attempt = n]]

\* nvflare/apis/impl/wf_comm_server.py:448-499
\* S2: live terminal/receipt guards and finite-history guard retained; unknown route has no aggregation callback.
WFCommDispatchSubmission ==
    /\ s.comm.kind = "submit" /\ s.comm.pc = "dispatch"
    /\ LET id == s.comm.id IN
       s' = [s EXCEPT !.comm.pc =
             IF LiveMap(id)
             THEN IF s.task[id[1]].status /= "LIVE" \/ CT(id).receipt
                  THEN "drop" ELSE "prelim"
             ELSE IF id \in SeqSet(s.completed) THEN "drop" ELSE "unknown",
           !.completed = IF ~LiveMap(id) /\ id \in SeqSet(s.completed)
                         THEN Touch(@,id) ELSE @]

\* nvflare/app_common/workflows/base_model_controller.py:251-273,329-365; nvflare/app_common/utils/error_handling_utils.py:51-61; nvflare/private/fed/server/server_runner.py:252-256,607-611
\* S3/S5: default all-selected dynamic tolerance is zero; non-OK sets panic unless resilient; conversion/consumer exceptions do not use this helper.
BaseAcceptTrainResult ==
    /\ s.comm.kind = "submit" /\ s.comm.pc = "prelim"
    /\ LET bad == CT(s.comm.id).result = "error" IN
       s' = [s EXCEPT !.comm.pc = IF bad THEN "decision" ELSE "convert",
          !.wf.abort = @ \/ (bad /\ ErrorMode /= "resilient"),
          !.aggr.failedClients = IF bad /\ ErrorMode = "dynamic"
                                THEN @ \cup {s.comm.id[2]} ELSE @]

\* nvflare/app_common/workflows/base_model_controller.py:272-284
\* S3: successful FLModel conversion; consumer invocation begins only afterward.
BaseConvertResult ==
    /\ s.comm.kind = "submit" /\ s.comm.pc = "convert"
    /\ s' = [s EXCEPT !.comm.pc = "consumer",
                     !.ct[s.comm.id[1]][s.comm.id[2]].invocations = @+1]

\* nvflare/app_common/workflows/base_model_controller.py:272-278
\* S3: declared ordinary conversion allocation/interface failure; no consumer and no tolerance-helper panic.
BaseConvertResultFailure ==
    /\ ConversionFailure /\ s.comm.kind = "submit" /\ s.comm.pc = "convert"
    /\ s' = [s EXCEPT !.comm.pc = "decision"]

\* nvflare/app_common/workflows/fedavg.py:268-304
\* S3: empty params returns False; otherwise enter built-in helper with valid uniform keys and positive symbolic unit weights.
FedAvgAggregateOneResult ==
    /\ s.comm.kind = "submit" /\ s.comm.pc = "consumer"
    /\ s' = [s EXCEPT !.comm.pc = IF CT(s.comm.id).result = "empty"
                                           THEN "decision" ELSE "paramStats", !.comm.key = 1]

\* nvflare/app_common/aggregators/weighted_aggregation_helper.py:162-175
\* S3: helper lock retained throughout add; per-key count precedes lazy materialization.
WeightedAddParamStats ==
    /\ s.comm.kind = "submit" /\ s.comm.pc = "paramStats"
    /\ s.comm.key \in Keys
    /\ s' = [s EXCEPT !.aggr.stats[s.comm.key] = Append(@,s.comm.id), !.comm.pc = "paramValue"]

\* nvflare/app_common/aggregators/weighted_aggregation_helper.py:173-216
\* S3: successful materialization and arithmetic apply one key; source values are not mutated; provenance represents total and weight together.
WeightedAddParamValue ==
    /\ s.comm.kind = "submit" /\ s.comm.pc = "paramValue"
    /\ s' = [s EXCEPT !.aggr.applied[s.comm.key] = Append(@,s.comm.id),
               !.comm.key = @+1, !.comm.pc = IF s.comm.key = NumKeys
                                                    THEN "paramHistory" ELSE "paramStats"]

\* nvflare/app_common/aggregators/weighted_aggregation_helper.py:173-216; nvflare/app_opt/pt/lazy_tensor_dict.py:77-80; nvflare/app_common/workflows/base_model_controller.py:281-286
\* S3: declared lazy disk I/O or ordinary allocation failure before this key value update; prior key updates and stats survive; callback catch returns rejected.
WeightedParamFailure ==
    /\ (LazyOffload \/ AllocationFailure)
    /\ s.comm.kind = "submit" /\ s.comm.pc = "paramValue"
    /\ s' = [s EXCEPT !.comm.pc = "decision"]

\* nvflare/app_common/aggregators/weighted_aggregation_helper.py:218-224; nvflare/app_common/workflows/fedavg.py:299-310
\* S3: history appended only after every parameter key; helper lock then releases.
WeightedAddParamHistory ==
    /\ s.comm.kind = "submit" /\ s.comm.pc = "paramHistory"
    /\ s' = [s EXCEPT !.aggr.paramHistory = Append(@,s.comm.id), !.comm.pc = "metrics"]

\* nvflare/app_common/workflows/fedavg.py:306-326
\* S3/S5: missing metrics disables round-level metrics; empty metrics skips this contribution; present metric enters helper only while allMetrics is true.
FedAvgProcessMetrics ==
    /\ s.comm.kind = "submit" /\ s.comm.pc = "metrics"
    /\ LET mk == CT(s.comm.id).metricKind IN
       s' = [s EXCEPT !.aggr.allMetrics = @ /\ mk /= "none",
              !.comm.pc = IF s.aggr.allMetrics /\ mk = "present"
                          THEN "metricStats" ELSE "count"]

\* nvflare/app_common/workflows/fedavg.py:312-320; nvflare/app_common/workflows/base_model_controller.py:281-286
\* S3: ordinary metric-filter allocation failure AFTER completed parameter history, before count increment.
FedAvgMetricPreparationFailure ==
    /\ AllocationFailure /\ s.comm.kind = "submit" /\ s.comm.pc = "metrics"
    /\ s.aggr.allMetrics /\ CT(s.comm.id).metricKind = "present"
    /\ s' = [s EXCEPT !.comm.pc = "decision"]

\* nvflare/app_common/workflows/fedavg.py:321-326; nvflare/app_common/aggregators/weighted_aggregation_helper.py:162-175
\* S3: one symbolic aggregatable metric key; stats precede arithmetic.
WeightedAddMetricStats ==
    /\ s.comm.kind = "submit" /\ s.comm.pc = "metricStats"
    /\ s' = [s EXCEPT !.aggr.metricStats = Append(@,s.comm.id), !.comm.pc = "metricValue"]

\* nvflare/app_common/aggregators/weighted_aggregation_helper.py:177-216
\* S3: successful metric key arithmetic; history and FedAvg callback count remain separate.
WeightedAddMetricValue ==
    /\ s.comm.kind = "submit" /\ s.comm.pc = "metricValue"
    /\ s' = [s EXCEPT !.aggr.metricApplied = Append(@,s.comm.id), !.comm.pc = "metricHistory"]

\* nvflare/app_common/aggregators/weighted_aggregation_helper.py:177-216; nvflare/app_common/workflows/base_model_controller.py:281-286
\* S3: ordinary metric arithmetic allocation failure before the metric value update; parameter contribution is not rolled back.
WeightedMetricFailure ==
    /\ AllocationFailure /\ s.comm.kind = "submit" /\ s.comm.pc = "metricValue"
    /\ s' = [s EXCEPT !.comm.pc = "decision"]

\* nvflare/app_common/aggregators/weighted_aggregation_helper.py:218-224; nvflare/app_common/workflows/fedavg.py:328-330
\* S3: finish metric helper; count increment occurs in next step.
WeightedAddMetricHistory ==
    /\ s.comm.kind = "submit" /\ s.comm.pc = "metricHistory"
    /\ s' = [s EXCEPT !.aggr.metricHistory = Append(@,s.comm.id), !.comm.pc = "count"]

\* nvflare/app_common/workflows/fedavg.py:328-330; nvflare/app_common/workflows/base_model_controller.py:281-284
\* S3: callback returns True after count increment; definitive event still not published.
FedAvgIncrementReceived ==
    /\ s.comm.kind = "submit" /\ s.comm.pc = "count"
    /\ s' = [s EXCEPT !.aggr.receivedCount = @+1, !.aggr.counted = Append(@,s.comm.id),
                     !.comm.accepted = TRUE, !.comm.pc = "decision"]

\* nvflare/app_common/workflows/base_model_controller.py:267-291
\* S3: current consumer-first accepted decision is retained; reject on conversion/consumer exception or empty skip.
BasePublishAcceptance ==
    /\ s.comm.kind = "submit" /\ s.comm.pc = "decision"
    /\ s' = [s EXCEPT !.ct[s.comm.id[1]][s.comm.id[2]].decision =
                 IF s.comm.accepted THEN "accepted" ELSE "rejected", !.comm.pc = "cleanup"]

\* nvflare/app_common/workflows/base_model_controller.py:292-294
\* S3/S4: finally clears context/result references; no helper rollback. PC records cleanup, without retaining model data.
BaseClearTrainingResult ==
    /\ s.comm.kind = "submit" /\ s.comm.pc = "cleanup"
    /\ s' = [s EXCEPT !.comm.pc = "receipt"]

\* nvflare/apis/impl/wf_comm_server.py:504-521; nvflare/private/fed/server/server_runner.py:559-565
\* S2/S3/S4: receipt after the callback, even if mark-only cancellation interleaved; release locks and complete server dispatch.
WFCommStampReceipt ==
    /\ s.comm.kind = "submit" /\ s.comm.pc = "receipt"
    /\ s' = [s EXCEPT !.ct[s.comm.id[1]][s.comm.id[2]].receipt = TRUE,
        !.net[s.comm.id[1]][s.comm.id[2]][s.comm.attempt] = "handled", !.comm = EmptyComm, !.runner = EmptyRunner]

\* nvflare/apis/impl/wf_comm_server.py:454-473; nvflare/app_common/workflows/base_model_controller.py:298-365
\* S2: unknown train result calls only preliminary acceptance with errors ignored; NO callback, count, history or acceptance event.
BaseProcessUnknownResult ==
    /\ s.comm.kind = "submit" /\ s.comm.pc = "unknown"
    /\ s' = [s EXCEPT !.unknownSeen = @ \cup {s.comm.id}, !.comm.pc = "drop"]

\* nvflare/apis/impl/wf_comm_server.py:454-495; nvflare/private/fed/server/server_runner.py:516-518; nvflare/private/fed/server/server_commands.py:242-246
\* S2: duplicate/terminal/unknown/closed-workflow dispatch finishes without a contribution; command still returns non-None.
WFCommDropSubmission ==
    /\ s.comm.kind = "submit" /\ s.comm.pc = "drop"
    /\ s' = [s EXCEPT !.net[s.comm.id[1]][s.comm.id[2]][s.comm.attempt] = "handled", !.comm = EmptyComm, !.runner = EmptyRunner]

\* nvflare/private/fed/server/server_command_agent.py:96-110; nvflare/private/fed/client/client_runner.py:628-637
\* S2: successful delivery of transport OK acknowledges command dispatch, including semantic drops.
ServerCommandDispatchAck(id, n) ==
    /\ n \in 1..Len(s.net[id[1]][id[2]]) /\ s.net[id[1]][id[2]][n] = "handled"
    /\ s' = [s EXCEPT !.net[id[1]][id[2]][n] = "ack"]

\* nvflare/private/fed/client/client_runner.py:628-637; nvflare/private/fed/server/server_command_agent.py:96-110
\* S2 payload interface: server handled result but client observed timeout/lost reply; no rollback of receipt/acceptance.
ClientLoseDispatchAck(id, n) ==
    /\ n \in 1..Len(s.net[id[1]][id[2]]) /\ s.net[id[1]][id[2]][n] = "handled"
    /\ s' = [s EXCEPT !.net[id[1]][id[2]][n] = "lost"]

\* nvflare/apis/impl/wf_comm_server.py:794-827
\* S4: supported direct cancellation is mark-only and takes no communicator/callback lock; admitted work can finish.
WFCommCancelTask(t) ==
    /\ s.task[t].standing /\ s.task[t].status = "LIVE"
    /\ s' = [s EXCEPT !.task[t].status = "CANCELLED"]

\* nvflare/apis/impl/wf_comm_server.py:175-186,79-82
\* S5: first ordinary dead-client report starts grace; dead-client lock excludes monitor observation loop.
WFCommReportDeadClient(c) ==
    /\ s.wf.open /\ s.mon.pc /= "dead" /\ ~s.dead[c].reported
    /\ s' = [s EXCEPT !.dead[c] = [reported |-> TRUE, age |-> 0, disconnected |-> FALSE]]

\* nvflare/private/fed/server/server_runner.py:572-587; nvflare/apis/impl/wf_comm_server.py:1250-1259
\* S5: supported activity/heartbeat clears reported and disconnected state under runner and dead-client locks.
WFCommClientIsActive(c) ==
    /\ s.wf.open /\ RunnerLockFree /\ s.mon.pc /= "dead" /\ s.dead[c].reported
    /\ s' = [s EXCEPT !.dead[c] = [reported |-> FALSE, age |-> 0, disconnected |-> FALSE]]

\* nvflare/apis/impl/wf_comm_server.py:1035-1040,1161-1168
\* S5 environment clock: one 30-second tick, saturating at task lead=30s and report grace=60s. No task timeout. This is a declared time-grid abstraction.
ClockAdvance ==
    /\ s.wf.pc /= "finalized"
    /\ s' = [s EXCEPT !.task = [t \in Tasks |-> [s.task[t] EXCEPT !.age =
          IF s.task[t].scheduled THEN 1 ELSE @]],
        !.dead = [c \in Clients |-> [s.dead[c] EXCEPT !.age =
          IF s.dead[c].reported /\ s.dead[c].age < 2 THEN @+1 ELSE @]]]

\* nvflare/apis/impl/wf_comm_server.py:1046-1049,1024-1030
\* S5: live monitor starts dead-client observation, holding the dead-client lock through this loop.
WFCommMonitorBegin ==
    /\ s.mon.pc = "idle" /\ s.wf.pc /= "finalized"
    /\ s' = [s EXCEPT !.mon.pc = "dead", !.mon.pending = Clients,
              !.mon.reportAges = [c \in Clients |-> s.dead[c].age]]

\* nvflare/apis/impl/wf_comm_server.py:1029-1044
\* S5: process one report; only grace-expired reported clients become disconnected.
WFCommCheckDeadClient(c) ==
    /\ s.mon.pc = "dead" /\ c \in s.mon.pending
    /\ s' = [s EXCEPT !.dead[c].disconnected =
                  @ \/ (s.dead[c].reported /\ s.mon.reportAges[c] = 2),
                  !.mon.pending = @ \ {c}]

\* nvflare/apis/impl/wf_comm_server.py:1049-1051,1218-1227
\* S5: release dead-client lock and begin per-client deployment-policy reads; no snapshot lock is invented.
WFCommDeadCheckDone ==
    /\ s.mon.pc = "dead" /\ s.mon.pending = {}
    /\ s' = [s EXCEPT !.mon.pc = "policy", !.mon.pending = Clients, !.mon.deadView = {}]

\* nvflare/apis/impl/wf_comm_server.py:1218-1227
\* S5: policy samples disconnect status per client; recovery may interleave, so deadView is a cached observation.
WFCommReadPolicyClient(c) ==
    /\ s.mon.pc = "policy" /\ c \in s.mon.pending
    /\ s' = [s EXCEPT !.mon.pending = @ \ {c},
               !.mon.deadView = IF s.dead[c].disconnected THEN @ \cup {c} ELSE @]

\* nvflare/apis/impl/wf_comm_server.py:1229-1248,1051-1057; nvflare/private/fed/server/server_runner.py:252-256,607-611
\* S5: all dead, below min_sites or a required site dead panics and stops this monitor BEFORE check_tasks.
WFCommJobPolicyDecision ==
    /\ s.mon.pc = "policy" /\ s.mon.pending = {}
    /\ LET bad == s.mon.deadView /= {} /\
             (s.mon.deadView = Clients \/ Cardinality(Clients \ s.mon.deadView) < MinSites
              \/ s.mon.deadView \cap RequiredSites /= {})
       IN s' = [s EXCEPT !.mon.pc = IF bad THEN "stopped" ELSE "acquire",
                        !.wf.abort = @ \/ bad]

\* nvflare/apis/impl/wf_comm_server.py:1060-1068
\* S4/S5: acquire communicator and task locks; submission callback must have finished before monitor can inspect/remove.
WFCommMonitorAcquire ==
    /\ s.mon.pc = "acquire" /\ s.comm.kind = "free"
    /\ s' = [s EXCEPT !.mon.pc = "locked",
                  !.comm = [EmptyComm EXCEPT !.kind = "monitor", !.pc = "select"]]

\* nvflare/apis/impl/wf_comm_server.py:1067-1097; nvflare/apis/impl/bcast_manager.py:52-75
\* S4/S5: terminal status first, then ALL receipt markers, then dead-client lead time. No timeout=0 branch.
WFCommMonitorSelect(t) ==
    /\ s.comm.kind = "monitor" /\ s.comm.pc = "select" /\ s.task[t].standing
    /\ s' = [s EXCEPT !.comm.id = <<t,"">>,
        !.comm.pc = IF s.task[t].status /= "LIVE" THEN "remove"
                   ELSE IF Outstanding(t) = {} THEN "mark" ELSE "deadScan",
        !.comm.exit = IF Outstanding(t) = {} THEN "OK" ELSE "LIVE",
        !.comm.pending = IF s.task[t].age = 1 THEN Outstanding(t) ELSE {},
        !.comm.deadView = {}]

\* nvflare/apis/impl/wf_comm_server.py:1170-1185
\* S5: scan outstanding target; encountering any live target ends dead-client scan immediately.
WFCommReadTaskDeadClient(c) ==
    /\ s.comm.kind = "monitor" /\ s.comm.pc = "deadScan" /\ c \in s.comm.pending
    /\ s' = [s EXCEPT !.comm.pending =
          IF s.dead[c].disconnected THEN @ \ {c} ELSE {},
        !.comm.deadView = IF s.dead[c].disconnected THEN @ \cup {c} ELSE {},
        !.comm.exit = IF ~s.dead[c].disconnected THEN "LIVE"
                     ELSE IF s.comm.pending = {c} THEN "CLIENT_DEAD" ELSE @]

\* nvflare/apis/impl/wf_comm_server.py:1092-1098,1170-1187
\* S5: task CLIENT_DEAD needs nonempty outstanding set observed disconnected; a missing live client keeps standing.
WFCommTaskDeadCheckDone ==
    /\ s.comm.kind = "monitor" /\ s.comm.pc = "deadScan" /\ s.comm.pending = {}
    /\ s' = IF s.comm.exit = "CLIENT_DEAD"
            THEN [s EXCEPT !.comm.pc = "mark"]
            ELSE [s EXCEPT !.comm = EmptyComm, !.mon.pc = "idle"]

\* nvflare/apis/impl/wf_comm_server.py:1079-1084,1092-1097
\* S4/S5: record manager/dead-check result after observation; mark-only cancellation may interleave with this assignment.
WFCommMonitorMarkTerminal ==
    /\ s.comm.kind = "monitor" /\ s.comm.pc = "mark"
    /\ s' = [s EXCEPT !.task[s.comm.id[1]].status = s.comm.exit, !.comm.pc = "remove"]

\* nvflare/apis/impl/wf_comm_server.py:1100-1109,397-406
\* S2/S4: queue length becomes zero and received ClientTasks enter ordered finite history; communicator lock retained until exit cleanup.
WFCommMonitorRemove ==
    /\ s.comm.kind = "monitor" /\ s.comm.pc = "remove"
    /\ LET t == s.comm.id[1] IN
       s' = [s EXCEPT !.task[t].standing = FALSE,
          !.task[t].retiredStatus = s.task[t].status,
          !.task[t].retiredOutstanding = Outstanding(t),
          !.completed = Remember(t), !.comm.pc = "exitCleanup"]

\* nvflare/apis/impl/wf_comm_server.py:1116-1155
\* S4: nonblocking FedAvg task has no task_done_cb; delete broadcast copy AFTER removal. Version retained only as a trace/provenance ghost.
WFCommMonitorCleanup ==
    /\ s.comm.kind = "monitor" /\ s.comm.pc = "exitCleanup"
    /\ s' = [s EXCEPT !.task[s.comm.id[1]].cleaned = TRUE,
                     !.comm = EmptyComm, !.mon.pc = "idle"]

\* nvflare/apis/impl/wf_comm_server.py:1067-1070,1113-1114
\* S4/S5: empty standing queue; no callbacks or policy-independent retirement is invented.
WFCommMonitorNoTask ==
    /\ s.comm.kind = "monitor" /\ s.comm.pc = "select"
    /\ (\A t \in Tasks : ~s.task[t].standing)
    /\ s' = [s EXCEPT !.comm = EmptyComm, !.mon.pc = "idle"]

\* nvflare/app_common/workflows/fedavg.py:223-230; nvflare/apis/impl/wf_comm_server.py:786-792
\* S4: read queue length without communicator lock; status and abort are NOT checked when the queue is empty.
FedAvgPollStanding ==
    /\ s.wf.pc = "wait"
    /\ s' = [s EXCEPT !.wf.pc = IF \E t \in Tasks : s.task[t].standing
                                THEN "abortPoll" ELSE "aggregate"]

\* nvflare/app_common/workflows/fedavg.py:224-228
\* S4/S5: abort polling occurs only after a nonempty queue observation; no global abort guard on all actions.
FedAvgPollAbort ==
    /\ s.wf.pc = "abortPoll"
    /\ s' = [s EXCEPT !.wf.pc = IF s.wf.abort THEN "returned" ELSE "wait",
                     !.wf.outcome = IF s.wf.abort THEN "aborted" ELSE @]

\* nvflare/app_common/workflows/fedavg.py:230-233,345-351; nvflare/app_common/aggregators/weighted_aggregation_helper.py:242-265
\* S3: copy actual helper histories and stats into aggregate-result observation before get_result resets helpers.
FedAvgGetAggregationStats ==
    /\ s.wf.pc = "aggregate"
    /\ s' = [s EXCEPT !.scratch.stats = s.aggr.stats,
          !.scratch.paramHistory = s.aggr.paramHistory, !.wf.pc = "params"]

\* nvflare/app_common/aggregators/weighted_aggregation_helper.py:226-240; nvflare/app_common/workflows/fedavg.py:351
\* S3: aggregate successful key updates, then reset parameter helper. Normal positive-weight arithmetic preserves symbolic provenance.
WeightedGetParamResult ==
    /\ s.wf.pc = "params"
    /\ s' = [s EXCEPT !.scratch.params = s.aggr.applied,
          !.aggr.applied = [k \in Keys |-> <<>>], !.aggr.stats = [k \in Keys |-> <<>>],
          !.aggr.paramHistory = <<>>, !.wf.pc = "metrics"]

\* nvflare/app_common/workflows/fedavg.py:352-353; nvflare/app_common/aggregators/weighted_aggregation_helper.py:226-240
\* S3/S5: allMetrics false suppresses metric output and skips get_result entirely; do not conflate partial helper state with used metrics.
WeightedGetMetricResult ==
    /\ s.wf.pc = "metrics"
    /\ s' = [s EXCEPT !.scratch.metrics = IF s.aggr.allMetrics THEN s.aggr.metricApplied ELSE <<>>,
          !.scratch.metricStats = IF s.aggr.allMetrics THEN s.aggr.metricStats ELSE <<>>,
          !.scratch.metricHistory = IF s.aggr.allMetrics THEN s.aggr.metricHistory ELSE <<>>,
          !.scratch.allMetrics = s.aggr.allMetrics,
          !.aggr.metricApplied = IF s.aggr.allMetrics THEN <<>> ELSE @,
          !.aggr.metricStats = IF s.aggr.allMetrics THEN <<>> ELSE @,
          !.aggr.metricHistory = IF s.aggr.allMetrics THEN <<>> ELSE @, !.wf.pc = "build"]

\* nvflare/app_common/workflows/fedavg.py:355-365
\* S3: FLModel metadata uses callback received_count independently from helper stats.
FedAvgBuildAggregateResult ==
    /\ s.wf.pc = "build"
    /\ s' = [s EXCEPT !.scratch.count = s.aggr.receivedCount,
          !.scratch.counted = s.aggr.counted, !.wf.pc = "update"]

\* nvflare/app_common/workflows/fedavg.py:234-238; nvflare/app_common/workflows/base_fedavg.py:302-322; nvflare/app_common/utils/fl_model_utils.py:233-239
\* S3/S4: FULL result becomes global model; committed observation includes rejected partial updates if implementation retained them. No status/acceptance guard.
BaseFedAvgUpdateModel ==
    /\ s.wf.pc = "update"
    /\ s' = [s EXCEPT !.used[s.wf.round] = s.scratch, !.committed = @ \cup {s.wf.round},
          !.wf.sourceVersion = s.wf.round, !.wf.pc = "save"]

\* nvflare/app_common/workflows/fedavg.py:257-259,489-504; nvflare/app_common/workflows/base_model_controller.py:439-446
\* S3/S4: declared successful persistor/file save observation; no durability claim. No task-status guard.
FedAvgSaveModel ==
    /\ s.wf.pc = "save"
    /\ s' = [s EXCEPT !.saved = @ \cup {s.wf.round}, !.wf.pc = "advance"]

\* nvflare/app_common/workflows/fedavg.py:186,261-266; nvflare/private/fed/server/server_runner.py:151-183
\* S4: ordinary next loop or Finished FedAvg observation; aborted runner is still separately observable through wf.abort.
FedAvgAdvanceRound ==
    /\ s.wf.pc = "advance"
    /\ s' = [s EXCEPT !.wf.pc = IF s.wf.round < NumRounds THEN "start" ELSE "returned",
                     !.wf.outcome = IF s.wf.round = NumRounds THEN "normal" ELSE @]

\* nvflare/private/fed/server/server_runner.py:157-171
\* S2/S4: after control_flow return, close current_wf under runner lock before communicator finalization.
ServerRunnerCloseWorkflow ==
    /\ s.wf.pc = "returned" /\ RunnerLockFree
    /\ s' = [s EXCEPT !.wf.open = FALSE, !.wf.pc = "finalize"]

\* nvflare/apis/impl/wf_comm_server.py:829-895; nvflare/private/fed/server/server_runner.py:170-178
\* S2/S4/S5: finalization waits for communicator lock; synchronously drain remaining tasks and clear completed history; no rollback of accepted work.
WFCommFinalizeRun ==
    /\ s.wf.pc = "finalize" /\ s.comm.kind = "free" /\ s.mon.pc /= "dead"
    /\ s' = [s EXCEPT !.task = [t \in Tasks |-> [s.task[t] EXCEPT
             !.status = IF s.task[t].standing /\ @ = "LIVE" THEN "CANCELLED" ELSE @,
             !.retiredStatus = IF s.task[t].standing
                     THEN IF s.task[t].status = "LIVE" THEN "CANCELLED" ELSE s.task[t].status ELSE @,
             !.retiredOutstanding = IF s.task[t].standing THEN Outstanding(t) ELSE @,
             !.standing = FALSE, !.cleaned = s.task[t].scheduled]],
             !.completed = <<>>, !.mon.pc = "stopped", !.wf.pc = "finalized"]

\* nvflare/private/fed/server/server_runner.py:289-298,572-578; nvflare/apis/impl/wf_comm_server.py:1250-1259; nvflare/private/fed/client/client_runner.py:548-588
\* S1/S5: request activity clears dead state before the separate get-task lock acquisition; capture only task-relevant polls.
ServerRunnerTaskRequestActive(c) ==
    /\ s.wf.open /\ ~s.wf.abort /\ RunnerLockFree /\ s.mon.pc /= "dead" /\ c \in Selected
    /\ ClientCanPoll(c)
    /\ c \notin s.requested
    /\ (\E t \in Tasks : s.task[t].standing /\ ~s.ct[t][c].receipt)
    /\ s' = [s EXCEPT !.dead[c] = [reported |-> FALSE, age |-> 0, disconnected |-> FALSE],
                     !.requested = @ \cup {c}]

\* nvflare/private/fed/server/server_runner.py:385-395
\* S1/S4: acquire wf_lock before waiting for communicator; monitor may still own communicator.
ServerRunnerAcquireTaskRequest(c) ==
    /\ c \in s.requested /\ RunnerLockFree
    /\ s' = [s EXCEPT !.requested = @ \ {c},
          !.runner = [EmptyRunner EXCEPT !.kind = "request", !.pc = "commWait", !.client = c]]

\* nvflare/private/fed/server/server_runner.py:386-395; nvflare/apis/impl/wf_comm_server.py:220-272; nvflare/apis/impl/task_manager.py:61-70
\* S1/S4: stale task-relevant poll finds no eligible task after waiting; unmodeled no-op polling is not silently allowed to change state.
WFCommTaskUnavailable ==
    /\ s.runner.kind = "request" /\ s.comm.kind = "free"
    /\ ~(\E t \in Tasks : s.wf.open /\ s.task[t].standing /\ s.task[t].status = "LIVE"
                         /\ ~s.ct[t][s.runner.client].receipt
                         /\ (~s.ct[t][s.runner.client].assigned \/
                              (s.ct[t][s.runner.client].delivery = "failed" /\
                               s.ct[t][s.runner.client].result = "none")))
    /\ s' = [s EXCEPT !.runner = EmptyRunner]

\* nvflare/private/fed/server/server_runner.py:585-605,572-578; nvflare/apis/impl/wf_comm_server.py:1250-1259
\* S2/S5: task-check activity reporting releases wf_lock before the separate mapping lookup.
ServerRunnerCheckTaskActive(id, n) ==
    /\ n \in 1..Len(s.net[id[1]][id[2]]) /\ s.net[id[1]][id[2]][n] = "check"
    /\ RunnerLockFree /\ s.mon.pc /= "dead"
    /\ s' = [s EXCEPT !.net[id[1]][id[2]][n] = "checking",
          !.dead[id[2]] = IF s.wf.open THEN [reported |-> FALSE, age |-> 0, disconnected |-> FALSE] ELSE @]

\* nvflare/private/fed/server/server_runner.py:463-475,572-578; nvflare/apis/impl/wf_comm_server.py:1250-1259
\* S2/S5: admitted submission clears disconnect state while retaining caller wf_lock; dead-report checks may run independently before communicator is acquired.
ServerRunnerSubmissionActive ==
    /\ s.runner.kind = "submit" /\ s.runner.pc = "activity" /\ s.mon.pc /= "dead"
    /\ s' = [s EXCEPT !.dead[s.runner.id[2]] = [reported |-> FALSE, age |-> 0, disconnected |-> FALSE],
                     !.runner.pc = "commWait"]

\* nvflare/private/fed/server/server_runner.py:559-565; nvflare/apis/impl/wf_comm_server.py:434-451
\* S2/S3: acquire communicator after caller admission; a newly triggered abort does not retroactively revoke the admitted handler.
WFCommAcquireSubmission ==
    /\ s.runner.kind = "submit" /\ s.runner.pc = "commWait" /\ s.comm.kind = "free"
    /\ s' = [s EXCEPT !.comm = [EmptyComm EXCEPT !.kind = "submit", !.pc = "dispatch",
                   !.id = s.runner.id, !.attempt = s.runner.attempt], !.runner.pc = "busy"]

\* nvflare/private/fed/server/server_runner.py:463-470; nvflare/private/fed/server/server_commands.py:242-246
\* S2/S4: closed/done runner returns before activity or communicator dispatch; command ACK remains distinct.
ServerRunnerDropClosedSubmission ==
    /\ s.runner.kind = "submit" /\ s.runner.pc = "closed"
    /\ s' = [s EXCEPT !.net[s.runner.id[1]][s.runner.id[2]][s.runner.attempt] = "handled",
                     !.runner = EmptyRunner]

\* Environment and all implementation steps. Stuttering is supplied by Spec.
Next ==
    \/ FedAvgRoundStarted
    \/ FedAvgResetAggregation
    \/ WFCommScheduleTask
    \/ \E c \in Clients : WFCommProcessTaskRequest(c)
    \/ \E id \in Ids : WFCommResendTask(id)
    \/ BasePrepareTaskData
    \/ BasePrepareTaskDataFailure
    \/ WFCommProtectBroadcast
    \/ WFCommProtectBroadcastFailure
    \/ WFCommCheckCanSend
    \/ WFCommPublishClientTask
    \/ WFCommTaskTryAgain
    \/ \E id \in Ids : ServerRunnerFilterTask(id)
    \/ \E id \in Ids : ServerRunnerFilterFailure(id)
    \/ \E id \in Ids : WFCommHandleException(id)
    \/ \E id \in Ids : ClientReceiveTask(id)
    \/ \E id \in Ids : TaskDeliveryFailure(id)
    \/ \E id \in Ids : \E kind \in {"params","empty"} : \E mk \in MetricKinds : ClientProcessTask(id, kind, mk)
    \/ \E id \in Ids : ClientExecutionError(id)
    \/ \E id \in Ids : \E n \in 1..Len(s.net[id[1]][id[2]]) : ClientCheckTask(id, n)
    \/ \E id \in Ids : ClientRetryResult(id)
    \/ \E id \in Ids : \E n \in 1..Len(s.net[id[1]][id[2]]) : ServerRunnerProcessSubmission(id, n)
    \/ WFCommDispatchSubmission
    \/ BaseAcceptTrainResult
    \/ BaseConvertResult
    \/ BaseConvertResultFailure
    \/ FedAvgAggregateOneResult
    \/ WeightedAddParamStats
    \/ WeightedAddParamValue
    \/ WeightedParamFailure
    \/ WeightedAddParamHistory
    \/ FedAvgProcessMetrics
    \/ FedAvgMetricPreparationFailure
    \/ WeightedAddMetricStats
    \/ WeightedAddMetricValue
    \/ WeightedMetricFailure
    \/ WeightedAddMetricHistory
    \/ FedAvgIncrementReceived
    \/ BasePublishAcceptance
    \/ BaseClearTrainingResult
    \/ WFCommStampReceipt
    \/ BaseProcessUnknownResult
    \/ WFCommDropSubmission
    \/ \E id \in Ids : \E n \in 1..Len(s.net[id[1]][id[2]]) : ServerCommandDispatchAck(id, n)
    \/ \E id \in Ids : \E n \in 1..Len(s.net[id[1]][id[2]]) : ClientLoseDispatchAck(id, n)
    \/ \E t \in Tasks : WFCommCancelTask(t)
    \/ \E c \in Clients : WFCommReportDeadClient(c)
    \/ \E c \in Clients : WFCommClientIsActive(c)
    \/ ClockAdvance
    \/ WFCommMonitorBegin
    \/ \E c \in Clients : WFCommCheckDeadClient(c)
    \/ WFCommDeadCheckDone
    \/ \E c \in Clients : WFCommReadPolicyClient(c)
    \/ WFCommJobPolicyDecision
    \/ WFCommMonitorAcquire
    \/ \E t \in Tasks : WFCommMonitorSelect(t)
    \/ \E c \in Clients : WFCommReadTaskDeadClient(c)
    \/ WFCommTaskDeadCheckDone
    \/ WFCommMonitorMarkTerminal
    \/ WFCommMonitorRemove
    \/ WFCommMonitorCleanup
    \/ WFCommMonitorNoTask
    \/ FedAvgPollStanding
    \/ FedAvgPollAbort
    \/ FedAvgGetAggregationStats
    \/ WeightedGetParamResult
    \/ WeightedGetMetricResult
    \/ FedAvgBuildAggregateResult
    \/ BaseFedAvgUpdateModel
    \/ FedAvgSaveModel
    \/ FedAvgAdvanceRound
    \/ ServerRunnerCloseWorkflow
    \/ WFCommFinalizeRun
    \/ \E c \in Clients : ServerRunnerTaskRequestActive(c)
    \/ \E c \in Clients : ServerRunnerAcquireTaskRequest(c)
    \/ WFCommTaskUnavailable
    \/ \E id \in Ids : \E n \in 1..Len(s.net[id[1]][id[2]]) : ServerRunnerCheckTaskActive(id, n)
    \/ ServerRunnerSubmissionActive
    \/ WFCommAcquireSubmission
    \/ ServerRunnerDropClosedSubmission

Spec == Init /\ [][Next]_vars

\* Structural domains; histories preserve multiplicity (sets would hide double counting).
AggregateType(a) ==
    /\ a.task \in 0..NumRounds
    /\ a.applied \in [Keys -> Seq(Ids)] /\ a.stats \in [Keys -> Seq(Ids)]
    /\ a.paramHistory \in Seq(Ids) /\ a.metricApplied \in Seq(Ids)
    /\ a.metricStats \in Seq(Ids) /\ a.metricHistory \in Seq(Ids)
    /\ a.allMetrics \in BOOLEAN /\ a.receivedCount \in Nat
    /\ a.counted \in Seq(Ids) /\ a.failedClients \subseteq Selected
UsedType(u) ==
    /\ u.params \in [Keys -> Seq(Ids)] /\ u.stats \in [Keys -> Seq(Ids)]
    /\ u.paramHistory \in Seq(Ids) /\ u.metrics \in Seq(Ids)
    /\ u.metricStats \in Seq(Ids) /\ u.metricHistory \in Seq(Ids)
    /\ u.allMetrics \in BOOLEAN /\ u.count \in Nat /\ u.counted \in Seq(Ids)
TypeOK ==
    /\ s.wf.round \in 0..NumRounds /\ s.wf.pc \in WfPCs
    /\ s.wf.sourceVersion \in 0..NumRounds /\ s.wf.started \subseteq Tasks
    /\ s.wf.abort \in BOOLEAN /\ s.wf.open \in BOOLEAN
    /\ s.wf.outcome \in {"running","normal","aborted","error"}
    /\ DOMAIN s.task = Tasks /\ DOMAIN s.ct = Tasks /\ DOMAIN s.net = Tasks
    /\ \A t \in Tasks :
         /\ DOMAIN s.ct[t] = Clients /\ DOMAIN s.net[t] = Clients
         /\ \A b \in {s.task[t].scheduled,s.task[t].standing,s.task[t].cleaned} : b \in BOOLEAN
         /\ s.task[t].status \in Statuses /\ s.task[t].retiredStatus \in Statuses
         /\ s.task[t].sourceAtSchedule \in -1..NumRounds
         /\ s.task[t].broadcastVersion \in -1..NumRounds
         /\ s.task[t].assignedOrder \in Seq(Ids) /\ s.task[t].age \in 0..1
         /\ s.task[t].retiredOutstanding \subseteq Selected
         /\ \A c \in Clients :
              /\ s.ct[t][c].assigned \in BOOLEAN /\ s.ct[t][c].receipt \in BOOLEAN
              /\ s.ct[t][c].headerId \in Ids \cup {NoId}
              /\ s.ct[t][c].headerRound \in -1..(NumRounds-1)
              /\ s.ct[t][c].inputVersion \in -1..NumRounds
              /\ s.ct[t][c].delivery \in DeliveryStates
              /\ s.ct[t][c].result \in {"none","params","empty","error"}
              /\ s.ct[t][c].metricKind \in {"present","none","empty"}
              /\ s.ct[t][c].decision \in Decisions /\ s.ct[t][c].invocations \in Nat
              /\ s.net[t][c] \in Seq(AttemptStates)
    /\ s.comm.kind \in {"free","request","submit","monitor"}
    /\ s.comm.pc \in CommPCs
    /\ s.comm.id \in Ids \cup {NoId} \cup {<<t,"">> : t \in Tasks}
    /\ s.comm.attempt \in Nat /\ s.comm.key \in 1..(NumKeys+1)
    /\ s.comm.accepted \in BOOLEAN /\ s.comm.exit \in Statuses
    /\ s.comm.writeStatus \in BOOLEAN
    /\ s.comm.pending \subseteq Clients /\ s.comm.deadView \subseteq Clients
    /\ AggregateType(s.aggr) /\ UsedType(s.scratch)
    /\ DOMAIN s.used = Tasks /\ \A t \in Tasks : UsedType(s.used[t])
    /\ s.committed \subseteq Tasks /\ s.saved \subseteq Tasks
    /\ s.completed \in Seq(Ids) /\ s.unknownSeen \subseteq Ids
    /\ DOMAIN s.dead = Clients
    /\ \A c \in Clients : /\ s.dead[c].reported \in BOOLEAN
                          /\ s.dead[c].disconnected \in BOOLEAN /\ s.dead[c].age \in 0..2
    /\ s.mon.pc \in MonPCs /\ s.mon.pending \subseteq Clients /\ s.mon.deadView \subseteq Clients
    /\ s.mon.reportAges \in [Clients -> 0..2]
    /\ s.requested \subseteq Clients
    /\ s.runner.kind \in {"free","request","submit"}
    /\ s.runner.pc \in {"idle","activity","commWait","busy","closed"}
    /\ s.runner.client \in Clients \cup {""}
    /\ s.runner.id \in Ids \cup {NoId} /\ s.runner.attempt \in Nat

\* S1: wf_comm_server.py:305-370; shareable.py:157-173. Frozen version is
\* retained as an observation ghost after _broadcast_data is deleted.
ProtectedBroadcastInput == \A id \in Ids : CT(id).assigned =>
    /\ id[2] \in Selected /\ CT(id).headerId = id /\ CT(id).headerRound = id[1]-1
    /\ CT(id).inputVersion = s.task[id[1]].broadcastVersion
    /\ CT(id).inputVersion = s.task[id[1]].sourceAtSchedule

\* S2: wf_comm_server.py:448-521; unknown path base_model_controller.py:298-365.
AtMostOneConsumer == \A id \in Ids : CT(id).invocations <= 1
ReceiptAfterDecision == \A id \in Ids : CT(id).receipt => CT(id).decision /= "pending"

\* Brief section 5: identity/provenance at externally exposed GLOBAL_MODEL update.
UsedIds(u) == UNION {SeqSet(u.params[k]) : k \in Keys} \cup SeqSet(u.metrics)
CommittedRoundProvenance == \A t \in s.committed :
    /\ UsedIds(s.used[t]) \subseteq ClientIds(t)
    /\ \A id \in UsedIds(s.used[t]) : CT(id).assigned /\ CT(id).headerRound = t-1

\* S3 inclusion: all nonempty successful uniform FULL parameter keys; unit
\* positive weights. Omitted metrics disable metric output; empty metrics skip.
\* This is an invariant to TEST, never a guard on commit/failure actions.
CommittedAcceptanceConsistency == \A t \in s.committed :
    LET u == s.used[t]
        expectedMetrics == SelectSeq(u.counted, LAMBDA id : CT(id).metricKind = "present")
    IN /\ UsedIds(u) \subseteq AcceptedIds(t)
       /\ u.count = Len(u.counted) /\ SeqSet(u.counted) = AcceptedIds(t)
       /\ u.paramHistory = u.counted
       /\ \A k \in Keys : u.params[k] = u.counted /\ u.stats[k] = u.counted
       /\ IF u.allMetrics
          THEN /\ u.metrics = expectedMetrics /\ u.metricHistory = expectedMetrics
               /\ u.metricStats = expectedMetrics
          ELSE u.metrics = <<>>

\* S4: ordinary saved/next ROUND_STARTED/Finished FedAvg are the outcome
\* observations required by the brief. Task status logs alone do not satisfy it.
OrdinaryObserved(t) == t \in s.saved \/ (\E later \in s.wf.started : later > t)
                      \/ s.wf.outcome = "normal"
AbnormalTerminationVisible == \A t \in Tasks :
    (s.task[t].retiredStatus \in Abnormal /\ s.task[t].retiredOutstanding /= {}
     /\ OrdinaryObserved(t)) => AllowPartialCompletion

\* Structural invariants, separate from candidate assertions.
OneStandingTask == Cardinality({t \in Tasks : s.task[t].standing}) <= 1
CompletedHistoryBound == Len(s.completed) <= HistoryLimit
    /\ Cardinality(SeqSet(s.completed)) = Len(s.completed)
    /\ \A id \in SeqSet(s.completed) : CT(id).receipt /\ ~s.task[id[1]].standing
CallbackRoundIsolation == s.comm.kind = "submit" /\
    s.comm.pc \in {"prelim","convert","consumer","paramStats","paramValue",
                  "paramHistory","metrics","metricStats","metricValue","metricHistory",
                  "count","decision","cleanup","receipt"} =>
    /\ s.aggr.task = s.comm.id[1] /\ s.task[s.comm.id[1]].standing
    /\ s.wf.round = s.comm.id[1]
CallerLockDiscipline ==
    /\ (s.comm.kind = "request" => s.runner.kind = "request")
    /\ (s.comm.kind = "submit" => s.runner.kind = "submit")
SavedWasCommitted == s.saved \subseteq s.committed
CountMatchesSuccessfulReturns == s.aggr.receivedCount = Len(s.aggr.counted)

\* S5 progress is conditional, not a promise about missing live responses.
\* MonitorLive accounts for policy panic stopping the monitor. Stability below
\* excludes recovery making the dead-target condition disappear.
DrainCondition(t) == s.task[t].scheduled /\
    (s.task[t].status \in Abnormal \/ Outstanding(t) = {} \/
     (s.task[t].age = 1 /\ Outstanding(t) /= {} /\ Outstanding(t) \subseteq Disconnected))
Eligible(t) == s.task[t].standing /\ DrainCondition(t)
MonitorLive == s.mon.pc /= "stopped" /\ s.wf.pc /= "finalized"
CallbacksTerminate == [](s.runner.kind \in {"request","submit"} ~> s.runner.kind = "free")
EligibleTaskEventuallyDrains == \A t \in Tasks :
    (<>[](DrainCondition(t) /\ MonitorLive)) => <>[](~s.task[t].standing)
=============================================================================
