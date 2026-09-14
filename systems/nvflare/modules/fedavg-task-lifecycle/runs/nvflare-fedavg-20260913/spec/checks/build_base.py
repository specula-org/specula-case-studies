from pathlib import Path
import json
D=Path(__file__).resolve().parent.parent
parts=[r'''------------------------------ MODULE base ------------------------------
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
AttemptStates == {"check", "queued", "handled", "ack", "lost", "gone"}
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

EmptyComm == [kind |-> "free", pc |-> "idle", id |-> NoId, attempt |-> 0,
              key |-> 1, accepted |-> FALSE, exit |-> "LIVE", writeStatus |-> FALSE,
              pending |-> {}, deadView |-> {}]
EmptyAggregate(t) == [task |-> t, applied |-> [k \in Keys |-> <<>>],
    stats |-> [k \in Keys |-> <<>>], paramHistory |-> <<>>,
    metricApplied |-> <<>>, metricStats |-> <<>>, metricHistory |-> <<>>,
    allMetrics |-> TRUE, receivedCount |-> 0, counted |-> <<>>]
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
    comm |-> EmptyComm, aggr |-> EmptyAggregate(0), scratch |-> EmptyUsed,
    used |-> [t \in Tasks |-> EmptyUsed], committed |-> {}, saved |-> {},
    completed |-> <<>>, unknownSeen |-> {},
    dead |-> [c \in Clients |-> [reported |-> FALSE, age |-> 0, disconnected |-> FALSE]],
    mon |-> [pc |-> "idle", pending |-> {}, deadView |-> {}]]

CT(id) == s.ct[id[1]][id[2]]
Outstanding(t) == {c \in Selected : ~s.ct[t][c].receipt}
Disconnected == {c \in Clients : s.dead[c].disconnected}
RunnerLockFree == s.comm.kind \notin {"request", "submit"}
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
''']
actions=[]
def A(name,args,src,trigger,body,fault=None):
    sig=name+'('+', '.join(args)+')' if args else name
    parts.append('\n\\* '+src+'\n\\* '+trigger+'\n'+sig+' ==\n'+body.strip('\n')+'\n')
    actions.append(dict(name=name,args=args,source=src,trigger=trigger,fault=fault))
A('FedAvgRoundStarted',[], 'nvflare/app_common/workflows/fedavg.py:186-195',
  'S1/S4: enter loop and publish ROUND_STARTED; no abort or task-status guard here.',r'''
    /\ s.wf.pc = "start" /\ s.wf.round < NumRounds
    /\ s' = [s EXCEPT !.wf.round = @+1, !.wf.pc = "reset",
                     !.wf.started = @ \cup {s.wf.round+1}]
''')
A('FedAvgResetAggregation',[], 'nvflare/app_common/workflows/fedavg.py:197-212',
  'S3/S4: selected cohort fixed by configuration; reset helpers and callback count.',r'''
    /\ s.wf.pc = "reset"
    /\ s' = [s EXCEPT !.aggr = EmptyAggregate(s.wf.round),
                     !.scratch = EmptyUsed, !.wf.pc = "schedule"]
''')
A('WFCommScheduleTask',[], 'nvflare/app_common/workflows/base_model_controller.py:142-158,188-221; nvflare/apis/impl/wf_comm_server.py:531-575',
  'S1/S5: broadcast publication; snapshot is not yet made; source model stays separate.',r'''
    /\ s.wf.pc = "schedule"
    /\ ~s.task[s.wf.round].scheduled
    /\ s' = [s EXCEPT !.task[s.wf.round].scheduled = TRUE,
         !.task[s.wf.round].standing = TRUE, !.task[s.wf.round].status = "LIVE",
         !.task[s.wf.round].sourceAtSchedule = s.wf.sourceVersion, !.wf.pc = "wait"]
''')
A('WFCommProcessTaskRequest',['c'], 'nvflare/private/fed/server/server_runner.py:385-421; nvflare/apis/impl/wf_comm_server.py:209-283; nvflare/apis/impl/task_manager.py:61-70',
  'S1: admit first retrieval under runner/communicator locks; one active task; supported selected client.',r'''
    /\ s.wf.open /\ s.comm.kind = "free" /\ s.wf.round \in Tasks
    /\ s.task[s.wf.round].standing /\ s.task[s.wf.round].status = "LIVE"
    /\ c \in Selected /\ ~s.ct[s.wf.round][c].assigned
    /\ s.ct[s.wf.round][c].delivery = "none"
    /\ s' = [s EXCEPT !.comm = [EmptyComm EXCEPT !.kind = "request",
                               !.pc = "before", !.id = <<s.wf.round,c>>]]
''')
A('WFCommResendTask',['id'], 'nvflare/apis/impl/wf_comm_server.py:230-241,277-370',
  'S1/S2: retry after failed outbound delivery, preserving ClientTask ID; no duplicate retraining is assumed.',r'''
    /\ s.wf.open /\ s.comm.kind = "free" /\ LiveMap(id)
    /\ s.task[id[1]].status = "LIVE" /\ ~CT(id).receipt
    /\ CT(id).delivery = "failed" /\ CT(id).result = "none"
    /\ s' = [s EXCEPT !.comm = [EmptyComm EXCEPT !.kind = "request",
                                 !.pc = "before", !.id = id]]
''','resend')
A('BasePrepareTaskData',[], 'nvflare/app_common/workflows/base_model_controller.py:225-228; nvflare/apis/impl/wf_comm_server.py:281-298',
  'S1: BEFORE_TRAIN_TASK returns normally; no arbitrary shared input mutation.',r'''
    /\ s.comm.kind = "request" /\ s.comm.pc = "before"
    /\ s' = [s EXCEPT !.comm.pc = "snapshot"]
''')
A('BasePrepareTaskDataFailure',[], 'nvflare/apis/impl/wf_comm_server.py:281-314',
  'S4: declared before-send event-handler runtime error marks ERROR; deepcopy is still attempted.',r'''
    /\ BeforeSendFailure /\ s.comm.kind = "request" /\ s.comm.pc = "before"
    /\ s' = [s EXCEPT !.task[s.comm.id[1]].status = "ERROR", !.comm.pc = "snapshot"]
''','before')
A('WFCommProtectBroadcast',[], 'nvflare/apis/impl/wf_comm_server.py:305-324',
  'S1: first retrieval deep-copies task data once; subsequent retrievals reuse the protected version.',r'''
    /\ s.comm.kind = "request" /\ s.comm.pc = "snapshot"
    /\ s' = [s EXCEPT !.task[s.comm.id[1]].broadcastVersion =
             IF @ = -1 THEN s.task[s.comm.id[1]].sourceAtSchedule ELSE @,
             !.comm.pc = "canSend"]
''')
A('WFCommProtectBroadcastFailure',[], 'nvflare/apis/impl/wf_comm_server.py:313-324',
  'S4: ordinary deepcopy allocation failure; no unprotected send fallback.',r'''
    /\ AllocationFailure /\ s.comm.kind = "request" /\ s.comm.pc = "snapshot"
    /\ s.task[s.comm.id[1]].broadcastVersion = -1
    /\ s' = [s EXCEPT !.task[s.comm.id[1]].status = "ERROR", !.comm.pc = "canSend"]
''','snapshot')
A('WFCommCheckCanSend',[], 'nvflare/apis/impl/wf_comm_server.py:327-345; nvflare/app_common/workflows/base_model_controller.py:213-221',
  'S1/S4: selected Task has no after-send callback; final status check precedes task-map publication.',r'''
    /\ s.comm.kind = "request" /\ s.comm.pc = "canSend"
    /\ s' = [s EXCEPT !.comm.pc = IF s.task[s.comm.id[1]].status = "LIVE"
                                THEN "publish" ELSE "tryAgain"]
''')
A('WFCommPublishClientTask',[], 'nvflare/apis/impl/wf_comm_server.py:349-370; nvflare/apis/shareable.py:157-173; nvflare/private/fed/server/server_runner.py:411-421,325-331',
  'S1: copy per-client headers and publish the envelope; payload still awaits outer filtering/delivery. Release both locks.',r'''
    /\ s.comm.kind = "request" /\ s.comm.pc = "publish"
    /\ LET id == s.comm.id IN
       s' = [s EXCEPT !.task[id[1]].assignedOrder =
                   IF CT(id).assigned THEN @ ELSE Append(@,id),
            !.ct[id[1]][id[2]].assigned = TRUE,
            !.ct[id[1]][id[2]].headerId = id,
            !.ct[id[1]][id[2]].headerRound = id[1]-1,
            !.ct[id[1]][id[2]].inputVersion = s.task[id[1]].broadcastVersion,
            !.ct[id[1]][id[2]].delivery = "filter", !.comm = EmptyComm]
''')
A('WFCommTaskTryAgain',[], 'nvflare/apis/impl/wf_comm_server.py:340-345',
  'S4: failed preparation returns TRY_AGAIN without registering a new client task.',r'''
    /\ s.comm.kind = "request" /\ s.comm.pc = "tryAgain"
    /\ s' = [s EXCEPT !.comm = EmptyComm]
''')
A('ServerRunnerFilterTask',['id'], 'nvflare/private/fed/server/server_runner.py:329-371',
  'S1/S4: no filter or successful configured filter; modeled filters preserve logical model provenance.',r'''
    /\ CT(id).delivery = "filter"
    /\ s' = [s EXCEPT !.ct[id[1]][id[2]].delivery = "wire"]
''')
A('ServerRunnerFilterFailure',['id'], 'nvflare/private/fed/server/server_runner.py:333-350',
  'S4: configured outbound filter raises an ordinary runtime exception; cancellation is a later lock-taking step.',r'''
    /\ OutboundFilter /\ CT(id).delivery = "filter"
    /\ s' = [s EXCEPT !.ct[id[1]][id[2]].delivery = "filterFailed"]
''','filter')
A('WFCommHandleException',['id'], 'nvflare/private/fed/server/server_runner.py:350-356; nvflare/apis/impl/wf_comm_server.py:372-390,794-812',
  'S4: acquire runner wf_lock (not communicator lock); cancel only if client-task mapping still exists; no run abort.',r'''
    /\ CT(id).delivery = "filterFailed" /\ RunnerLockFree
    /\ s.comm.kind /= "monitor" \/ s.comm.pc = "exitCleanup"
    /\ s' = [s EXCEPT !.task[id[1]].status =
           IF s.wf.open /\ LiveMap(id) THEN "CANCELLED" ELSE @,
           !.ct[id[1]][id[2]].delivery = "failed"]
''')
# Parenthesize the disjunctive lock guard (TLA precedence otherwise changes the action).
parts[-1]=parts[-1].replace('/\\ s.comm.kind /= "monitor" \\/ s.comm.pc = "exitCleanup"','/\\ (s.comm.kind /= "monitor" \\/ s.comm.pc = "exitCleanup")')
A('ClientReceiveTask',['id'], 'nvflare/private/fed/client/client_runner.py:225-248; nvflare/private/fed/server/server_runner.py:371',
  'S1/S2: delivery and decode complete for this envelope; assignment alone promises neither.',r'''
    /\ CT(id).delivery = "wire"
    /\ s' = [s EXCEPT !.ct[id[1]][id[2]].delivery = "ready"]
''')
A('TaskDeliveryFailure',['id'], 'nvflare/private/fed/server/server_runner.py:371; nvflare/private/fed/client/client_runner.py:225-248',
  'S1/S4 payload interface: ordinary envelope delivery failure before execution; no byte/chunk model.',r'''
    /\ CT(id).delivery = "wire"
    /\ s' = [s EXCEPT !.ct[id[1]][id[2]].delivery = "failed"]
''','delivery')
A('ClientProcessTask',['id','kind','mk'], 'nvflare/private/fed/client/client_runner.py:225-248; nvflare/app_common/workflows/fedavg.py:268-273,306-326',
  'S2/S3: cooperative FULL reply, same task ID/cookie and round; one result per client-task; empty parameters can be deliberately skipped.',r'''
    /\ CT(id).delivery = "ready" /\ CT(id).result = "none"
    /\ kind \in (IF AllowEmpty THEN {"params","empty"} ELSE {"params"})
    /\ mk \in MetricKinds
    /\ s' = [s EXCEPT !.ct[id[1]][id[2]].result = kind,
                     !.ct[id[1]][id[2]].metricKind = mk,
                     !.net[id[1]][id[2]] = <<"check">>]
''')
A('ClientExecutionError',['id'], 'nvflare/private/fed/client/client_runner.py:225-248',
  'S5: ordinary executor exception produces a nonfatal-to-runner EXECUTION_EXCEPTION reply with original identity.',r'''
    /\ CT(id).delivery = "ready" /\ CT(id).result = "none"
    /\ s' = [s EXCEPT !.ct[id[1]][id[2]].result = "error",
                     !.net[id[1]][id[2]] = <<"check">>]
''','resultError')
A('ClientCheckTask',['id','n'], 'nvflare/private/fed/client/client_runner.py:615-630; nvflare/private/fed/server/server_runner.py:585-605',
  'S2: task-check precedes submission; terminal-but-still-mapped tasks return OK; delayed checked sends may arrive after retirement.',r'''
    /\ n \in 1..Len(s.net[id[1]][id[2]]) /\ s.net[id[1]][id[2]][n] = "check"
    /\ RunnerLockFree /\ (s.comm.kind /= "monitor" \/ s.comm.pc = "exitCleanup")
    /\ s' = [s EXCEPT !.net[id[1]][id[2]][n] =
                 IF s.wf.open /\ LiveMap(id) THEN "queued" ELSE "gone"]
''')
A('ClientRetryResult',['id'], 'nvflare/private/fed/client/client_runner.py:590-637',
  'S2: retry after ambiguous/lost reply; retain task identity, re-check mapping; the old queued dispatch may still finish.',r'''
    /\ s.net[id[1]][id[2]] /= <<>>
    /\ \E n \in 1..Len(s.net[id[1]][id[2]]) : s.net[id[1]][id[2]][n] = "lost"
    /\ s' = [s EXCEPT !.net[id[1]][id[2]] = Append(@,"check")]
''','retry')
A('ServerRunnerProcessSubmission',['id','n'], 'nvflare/private/fed/server/server_runner.py:514-565; nvflare/private/fed/server/server_commands.py:232-246; nvflare/apis/impl/wf_comm_server.py:434-451',
  'S2/S3: acquire runner and communicator locks; queued Shareable is decoded; no incoming content filter in this suite.',r'''
    /\ n \in 1..Len(s.net[id[1]][id[2]]) /\ s.net[id[1]][id[2]][n] = "queued"
    /\ s.comm.kind = "free"
    /\ s' = [s EXCEPT !.comm = [EmptyComm EXCEPT !.kind = "submit",
                   !.pc = IF s.wf.open THEN "dispatch" ELSE "drop", !.id = id, !.attempt = n]]
''')
A('WFCommDispatchSubmission',[], 'nvflare/apis/impl/wf_comm_server.py:448-499',
  'S2: live terminal/receipt guards and finite-history guard retained; unknown route has no aggregation callback.',r'''
    /\ s.comm.kind = "submit" /\ s.comm.pc = "dispatch"
    /\ LET id == s.comm.id IN
       s' = [s EXCEPT !.comm.pc =
             IF LiveMap(id)
             THEN IF s.task[id[1]].status /= "LIVE" \/ CT(id).receipt
                  THEN "drop" ELSE "prelim"
             ELSE IF id \in SeqSet(s.completed) THEN "drop" ELSE "unknown",
           !.completed = IF ~LiveMap(id) /\ id \in SeqSet(s.completed)
                         THEN Touch(@,id) ELSE @]
''')
A('BaseAcceptTrainResult',[], 'nvflare/app_common/workflows/base_model_controller.py:251-273,329-365; nvflare/app_common/utils/error_handling_utils.py:51-61; nvflare/private/fed/server/server_runner.py:252-256,607-611',
  'S3/S5: default all-selected dynamic tolerance is zero; non-OK sets panic unless resilient; conversion/consumer exceptions do not use this helper.',r'''
    /\ s.comm.kind = "submit" /\ s.comm.pc = "prelim"
    /\ LET bad == CT(s.comm.id).result = "error" IN
       s' = [s EXCEPT !.comm.pc = IF bad THEN "decision" ELSE "convert",
          !.wf.abort = @ \/ (bad /\ ErrorMode /= "resilient"),
          !.aggr.failedClients = IF bad /\ ErrorMode = "dynamic"
                                THEN @ \cup {s.comm.id[2]} ELSE @]
''')
# failedClients is current round task context, reset with helpers.
parts[0]=parts[0].replace('allMetrics |-> TRUE, receivedCount |-> 0, counted |-> <<>>]', 'allMetrics |-> TRUE, receivedCount |-> 0, counted |-> <<>>, failedClients |-> {}]')
A('BaseConvertResult',[], 'nvflare/app_common/workflows/base_model_controller.py:272-284',
  'S3: successful FLModel conversion; consumer invocation begins only afterward.',r'''
    /\ s.comm.kind = "submit" /\ s.comm.pc = "convert"
    /\ s' = [s EXCEPT !.comm.pc = "consumer",
                     !.ct[s.comm.id[1]][s.comm.id[2]].invocations = @+1]
''')
A('BaseConvertResultFailure',[], 'nvflare/app_common/workflows/base_model_controller.py:272-278',
  'S3: declared ordinary conversion allocation/interface failure; no consumer and no tolerance-helper panic.',r'''
    /\ ConversionFailure /\ s.comm.kind = "submit" /\ s.comm.pc = "convert"
    /\ s' = [s EXCEPT !.comm.pc = "decision"]
''','conversion')
A('FedAvgAggregateOneResult',[], 'nvflare/app_common/workflows/fedavg.py:268-304',
  'S3: empty params returns False; otherwise enter built-in helper with valid uniform keys and positive symbolic unit weights.',r'''
    /\ s.comm.kind = "submit" /\ s.comm.pc = "consumer"
    /\ s' = [s EXCEPT !.comm.pc = IF CT(s.comm.id).result = "empty"
                                           THEN "decision" ELSE "paramStats", !.comm.key = 1]
''')
A('WeightedAddParamStats',[], 'nvflare/app_common/aggregators/weighted_aggregation_helper.py:162-175',
  'S3: helper lock retained throughout add; per-key count precedes lazy materialization.',r'''
    /\ s.comm.kind = "submit" /\ s.comm.pc = "paramStats"
    /\ s.comm.key \in Keys
    /\ s' = [s EXCEPT !.aggr.stats[s.comm.key] = Append(@,s.comm.id), !.comm.pc = "paramValue"]
''')
A('WeightedAddParamValue',[], 'nvflare/app_common/aggregators/weighted_aggregation_helper.py:173-216',
  'S3: successful materialization and arithmetic apply one key; source values are not mutated; provenance represents total and weight together.',r'''
    /\ s.comm.kind = "submit" /\ s.comm.pc = "paramValue"
    /\ s' = [s EXCEPT !.aggr.applied[s.comm.key] = Append(@,s.comm.id),
               !.comm.key = @+1, !.comm.pc = IF s.comm.key = NumKeys
                                                    THEN "paramHistory" ELSE "paramStats"]
''')
A('WeightedParamFailure',[], 'nvflare/app_common/aggregators/weighted_aggregation_helper.py:173-216; nvflare/app_opt/pt/lazy_tensor_dict.py:77-80; nvflare/app_common/workflows/base_model_controller.py:281-286',
  'S3: declared lazy disk I/O or ordinary allocation failure before this key value update; prior key updates and stats survive; callback catch returns rejected.',r'''
    /\ (LazyOffload \/ AllocationFailure)
    /\ s.comm.kind = "submit" /\ s.comm.pc = "paramValue"
    /\ s' = [s EXCEPT !.comm.pc = "decision"]
''','param')
A('WeightedAddParamHistory',[], 'nvflare/app_common/aggregators/weighted_aggregation_helper.py:218-224; nvflare/app_common/workflows/fedavg.py:299-310',
  'S3: history appended only after every parameter key; helper lock then releases.',r'''
    /\ s.comm.kind = "submit" /\ s.comm.pc = "paramHistory"
    /\ s' = [s EXCEPT !.aggr.paramHistory = Append(@,s.comm.id), !.comm.pc = "metrics"]
''')
A('FedAvgProcessMetrics',[], 'nvflare/app_common/workflows/fedavg.py:306-326',
  'S3/S5: missing metrics disables round-level metrics; empty metrics skips this contribution; present metric enters helper only while allMetrics is true.',r'''
    /\ s.comm.kind = "submit" /\ s.comm.pc = "metrics"
    /\ LET mk == CT(s.comm.id).metricKind IN
       s' = [s EXCEPT !.aggr.allMetrics = @ /\ mk /= "none",
              !.comm.pc = IF s.aggr.allMetrics /\ mk = "present"
                          THEN "metricStats" ELSE "count"]
''')
A('FedAvgMetricPreparationFailure',[], 'nvflare/app_common/workflows/fedavg.py:312-320; nvflare/app_common/workflows/base_model_controller.py:281-286',
  'S3: ordinary metric-filter allocation failure AFTER completed parameter history, before count increment.',r'''
    /\ AllocationFailure /\ s.comm.kind = "submit" /\ s.comm.pc = "metrics"
    /\ s.aggr.allMetrics /\ CT(s.comm.id).metricKind = "present"
    /\ s' = [s EXCEPT !.comm.pc = "decision"]
''','metricPrep')
A('WeightedAddMetricStats',[], 'nvflare/app_common/workflows/fedavg.py:321-326; nvflare/app_common/aggregators/weighted_aggregation_helper.py:162-175',
  'S3: one symbolic aggregatable metric key; stats precede arithmetic.',r'''
    /\ s.comm.kind = "submit" /\ s.comm.pc = "metricStats"
    /\ s' = [s EXCEPT !.aggr.metricStats = Append(@,s.comm.id), !.comm.pc = "metricValue"]
''')
A('WeightedAddMetricValue',[], 'nvflare/app_common/aggregators/weighted_aggregation_helper.py:177-216',
  'S3: successful metric key arithmetic; history and FedAvg callback count remain separate.',r'''
    /\ s.comm.kind = "submit" /\ s.comm.pc = "metricValue"
    /\ s' = [s EXCEPT !.aggr.metricApplied = Append(@,s.comm.id), !.comm.pc = "metricHistory"]
''')
A('WeightedMetricFailure',[], 'nvflare/app_common/aggregators/weighted_aggregation_helper.py:177-216; nvflare/app_common/workflows/base_model_controller.py:281-286',
  'S3: ordinary metric arithmetic allocation failure before the metric value update; parameter contribution is not rolled back.',r'''
    /\ AllocationFailure /\ s.comm.kind = "submit" /\ s.comm.pc = "metricValue"
    /\ s' = [s EXCEPT !.comm.pc = "decision"]
''','metric')
A('WeightedAddMetricHistory',[], 'nvflare/app_common/aggregators/weighted_aggregation_helper.py:218-224; nvflare/app_common/workflows/fedavg.py:328-330',
  'S3: finish metric helper; count increment occurs in next step.',r'''
    /\ s.comm.kind = "submit" /\ s.comm.pc = "metricHistory"
    /\ s' = [s EXCEPT !.aggr.metricHistory = Append(@,s.comm.id), !.comm.pc = "count"]
''')
A('FedAvgIncrementReceived',[], 'nvflare/app_common/workflows/fedavg.py:328-330; nvflare/app_common/workflows/base_model_controller.py:281-284',
  'S3: callback returns True after count increment; definitive event still not published.',r'''
    /\ s.comm.kind = "submit" /\ s.comm.pc = "count"
    /\ s' = [s EXCEPT !.aggr.receivedCount = @+1, !.aggr.counted = Append(@,s.comm.id),
                     !.comm.accepted = TRUE, !.comm.pc = "decision"]
''')
A('BasePublishAcceptance',[], 'nvflare/app_common/workflows/base_model_controller.py:267-291',
  'S3: current consumer-first accepted decision is retained; reject on conversion/consumer exception or empty skip.',r'''
    /\ s.comm.kind = "submit" /\ s.comm.pc = "decision"
    /\ s' = [s EXCEPT !.ct[s.comm.id[1]][s.comm.id[2]].decision =
                 IF s.comm.accepted THEN "accepted" ELSE "rejected", !.comm.pc = "cleanup"]
''')
A('BaseClearTrainingResult',[], 'nvflare/app_common/workflows/base_model_controller.py:292-294',
  'S3/S4: finally clears context/result references; no helper rollback. PC records cleanup, without retaining model data.',r'''
    /\ s.comm.kind = "submit" /\ s.comm.pc = "cleanup"
    /\ s' = [s EXCEPT !.comm.pc = "receipt"]
''')
A('WFCommStampReceipt',[], 'nvflare/apis/impl/wf_comm_server.py:504-521; nvflare/private/fed/server/server_runner.py:559-565',
  'S2/S3/S4: receipt after the callback, even if mark-only cancellation interleaved; release locks and complete server dispatch.',r'''
    /\ s.comm.kind = "submit" /\ s.comm.pc = "receipt"
    /\ s' = [s EXCEPT !.ct[s.comm.id[1]][s.comm.id[2]].receipt = TRUE,
        !.net[s.comm.id[1]][s.comm.id[2]][s.comm.attempt] = "handled", !.comm = EmptyComm]
''')
A('BaseProcessUnknownResult',[], 'nvflare/apis/impl/wf_comm_server.py:454-473; nvflare/app_common/workflows/base_model_controller.py:298-365',
  'S2: unknown train result calls only preliminary acceptance with errors ignored; NO callback, count, history or acceptance event.',r'''
    /\ s.comm.kind = "submit" /\ s.comm.pc = "unknown"
    /\ s' = [s EXCEPT !.unknownSeen = @ \cup {s.comm.id}, !.comm.pc = "drop"]
''')
A('WFCommDropSubmission',[], 'nvflare/apis/impl/wf_comm_server.py:454-495; nvflare/private/fed/server/server_runner.py:516-518; nvflare/private/fed/server/server_commands.py:242-246',
  'S2: duplicate/terminal/unknown/closed-workflow dispatch finishes without a contribution; command still returns non-None.',r'''
    /\ s.comm.kind = "submit" /\ s.comm.pc = "drop"
    /\ s' = [s EXCEPT !.net[s.comm.id[1]][s.comm.id[2]][s.comm.attempt] = "handled", !.comm = EmptyComm]
''')
A('ServerCommandDispatchAck',['id','n'], 'nvflare/private/fed/server/server_command_agent.py:96-110; nvflare/private/fed/client/client_runner.py:628-637',
  'S2: successful delivery of transport OK acknowledges command dispatch, including semantic drops.',r'''
    /\ n \in 1..Len(s.net[id[1]][id[2]]) /\ s.net[id[1]][id[2]][n] = "handled"
    /\ s' = [s EXCEPT !.net[id[1]][id[2]][n] = "ack"]
''')
A('ClientLoseDispatchAck',['id','n'], 'nvflare/private/fed/client/client_runner.py:628-637; nvflare/private/fed/server/server_command_agent.py:96-110',
  'S2 payload interface: server handled result but client observed timeout/lost reply; no rollback of receipt/acceptance.',r'''
    /\ n \in 1..Len(s.net[id[1]][id[2]]) /\ s.net[id[1]][id[2]][n] = "handled"
    /\ s' = [s EXCEPT !.net[id[1]][id[2]][n] = "lost"]
''','ackLoss')
A('WFCommCancelTask',['t'], 'nvflare/apis/impl/wf_comm_server.py:794-827',
  'S4: supported direct cancellation is mark-only and takes no communicator/callback lock; admitted work can finish.',r'''
    /\ s.task[t].standing /\ s.task[t].status = "LIVE"
    /\ s' = [s EXCEPT !.task[t].status = "CANCELLED"]
''','cancel')
A('WFCommReportDeadClient',['c'], 'nvflare/apis/impl/wf_comm_server.py:175-186,79-82',
  'S5: first ordinary dead-client report starts grace; dead-client lock excludes monitor observation loop.',r'''
    /\ s.wf.open /\ s.mon.pc /= "dead" /\ ~s.dead[c].reported
    /\ s' = [s EXCEPT !.dead[c] = [reported |-> TRUE, age |-> 0, disconnected |-> FALSE]]
''','dead')
A('WFCommClientIsActive',['c'], 'nvflare/private/fed/server/server_runner.py:572-587; nvflare/apis/impl/wf_comm_server.py:1250-1259',
  'S5: supported activity/heartbeat clears reported and disconnected state under runner and dead-client locks.',r'''
    /\ s.wf.open /\ RunnerLockFree /\ s.mon.pc /= "dead" /\ s.dead[c].reported
    /\ s' = [s EXCEPT !.dead[c] = [reported |-> FALSE, age |-> 0, disconnected |-> FALSE]]
''')
A('ClockAdvance',[], 'nvflare/apis/impl/wf_comm_server.py:1035-1040,1161-1168',
  'S5 environment clock: one 30-second tick, saturating at task lead=30s and report grace=60s. No task timeout. This is a declared time-grid abstraction.',r'''
    /\ s.wf.pc /= "finalized"
    /\ s' = [s EXCEPT !.task = [t \in Tasks |-> [s.task[t] EXCEPT !.age =
          IF s.task[t].scheduled THEN 1 ELSE @]],
        !.dead = [c \in Clients |-> [s.dead[c] EXCEPT !.age =
          IF s.dead[c].reported /\ s.dead[c].age < 2 THEN @+1 ELSE @]]]
''')
A('WFCommMonitorBegin',[], 'nvflare/apis/impl/wf_comm_server.py:1046-1049,1024-1030',
  'S5: live monitor starts dead-client observation, holding the dead-client lock through this loop.',r'''
    /\ s.mon.pc = "idle" /\ s.wf.pc /= "finalized"
    /\ s' = [s EXCEPT !.mon.pc = "dead", !.mon.pending = Clients]
''')
A('WFCommCheckDeadClient',['c'], 'nvflare/apis/impl/wf_comm_server.py:1029-1044',
  'S5: process one report; only grace-expired reported clients become disconnected.',r'''
    /\ s.mon.pc = "dead" /\ c \in s.mon.pending
    /\ s' = [s EXCEPT !.dead[c].disconnected =
                  @ \/ (s.dead[c].reported /\ s.dead[c].age = 2),
                  !.mon.pending = @ \ {c}]
''')
A('WFCommDeadCheckDone',[], 'nvflare/apis/impl/wf_comm_server.py:1049-1051,1218-1227',
  'S5: release dead-client lock and begin per-client deployment-policy reads; no snapshot lock is invented.',r'''
    /\ s.mon.pc = "dead" /\ s.mon.pending = {}
    /\ s' = [s EXCEPT !.mon.pc = "policy", !.mon.pending = Clients, !.mon.deadView = {}]
''')
A('WFCommReadPolicyClient',['c'], 'nvflare/apis/impl/wf_comm_server.py:1218-1227',
  'S5: policy samples disconnect status per client; recovery may interleave, so deadView is a cached observation.',r'''
    /\ s.mon.pc = "policy" /\ c \in s.mon.pending
    /\ s' = [s EXCEPT !.mon.pending = @ \ {c},
               !.mon.deadView = IF s.dead[c].disconnected THEN @ \cup {c} ELSE @]
''')
A('WFCommJobPolicyDecision',[], 'nvflare/apis/impl/wf_comm_server.py:1229-1248,1051-1057; nvflare/private/fed/server/server_runner.py:252-256,607-611',
  'S5: all dead, below min_sites or a required site dead panics and stops this monitor BEFORE check_tasks.',r'''
    /\ s.mon.pc = "policy" /\ s.mon.pending = {}
    /\ LET bad == s.mon.deadView /= {} /\
             (s.mon.deadView = Clients \/ Cardinality(Clients \ s.mon.deadView) < MinSites
              \/ s.mon.deadView \cap RequiredSites /= {})
       IN s' = [s EXCEPT !.mon.pc = IF bad THEN "stopped" ELSE "acquire",
                        !.wf.abort = @ \/ bad]
''')
A('WFCommMonitorAcquire',[], 'nvflare/apis/impl/wf_comm_server.py:1060-1068',
  'S4/S5: acquire communicator and task locks; submission callback must have finished before monitor can inspect/remove.',r'''
    /\ s.mon.pc = "acquire" /\ s.comm.kind = "free"
    /\ s' = [s EXCEPT !.mon.pc = "locked",
                  !.comm = [EmptyComm EXCEPT !.kind = "monitor", !.pc = "select"]]
''')
A('WFCommMonitorSelect',['t'], 'nvflare/apis/impl/wf_comm_server.py:1067-1097; nvflare/apis/impl/bcast_manager.py:52-75',
  'S4/S5: terminal status first, then ALL receipt markers, then dead-client lead time. No timeout=0 branch.',r'''
    /\ s.comm.kind = "monitor" /\ s.comm.pc = "select" /\ s.task[t].standing
    /\ s' = [s EXCEPT !.comm.id = <<t,"">>,
        !.comm.pc = IF s.task[t].status /= "LIVE" THEN "remove"
                   ELSE IF Outstanding(t) = {} THEN "mark" ELSE "deadScan",
        !.comm.exit = IF Outstanding(t) = {} THEN "OK" ELSE "LIVE",
        !.comm.pending = IF s.task[t].age = 1 THEN Outstanding(t) ELSE {},
        !.comm.deadView = {}]
''')
A('WFCommReadTaskDeadClient',['c'], 'nvflare/apis/impl/wf_comm_server.py:1170-1185',
  'S5: scan outstanding target; encountering any live target ends dead-client scan immediately.',r'''
    /\ s.comm.kind = "monitor" /\ s.comm.pc = "deadScan" /\ c \in s.comm.pending
    /\ s' = [s EXCEPT !.comm.pending =
          IF s.dead[c].disconnected THEN @ \ {c} ELSE {},
        !.comm.deadView = IF s.dead[c].disconnected THEN @ \cup {c} ELSE {},
        !.comm.exit = IF ~s.dead[c].disconnected THEN "LIVE"
                     ELSE IF s.comm.pending = {c} THEN "CLIENT_DEAD" ELSE @]
''')
A('WFCommTaskDeadCheckDone',[], 'nvflare/apis/impl/wf_comm_server.py:1092-1098,1170-1187',
  'S5: task CLIENT_DEAD needs nonempty outstanding set observed disconnected; a missing live client keeps standing.',r'''
    /\ s.comm.kind = "monitor" /\ s.comm.pc = "deadScan" /\ s.comm.pending = {}
    /\ s' = IF s.comm.exit = "CLIENT_DEAD"
            THEN [s EXCEPT !.comm.pc = "mark"]
            ELSE [s EXCEPT !.comm = EmptyComm, !.mon.pc = "idle"]
''')
A('WFCommMonitorMarkTerminal',[], 'nvflare/apis/impl/wf_comm_server.py:1079-1084,1092-1097',
  'S4/S5: record manager/dead-check result after observation; mark-only cancellation may interleave with this assignment.',r'''
    /\ s.comm.kind = "monitor" /\ s.comm.pc = "mark"
    /\ s' = [s EXCEPT !.task[s.comm.id[1]].status = s.comm.exit, !.comm.pc = "remove"]
''')
A('WFCommMonitorRemove',[], 'nvflare/apis/impl/wf_comm_server.py:1100-1109,397-406',
  'S2/S4: queue length becomes zero and received ClientTasks enter ordered finite history; communicator lock retained until exit cleanup.',r'''
    /\ s.comm.kind = "monitor" /\ s.comm.pc = "remove"
    /\ LET t == s.comm.id[1] IN
       s' = [s EXCEPT !.task[t].standing = FALSE,
          !.task[t].retiredStatus = s.task[t].status,
          !.task[t].retiredOutstanding = Outstanding(t),
          !.completed = Remember(t), !.comm.pc = "exitCleanup"]
''')
A('WFCommMonitorCleanup',[], 'nvflare/apis/impl/wf_comm_server.py:1116-1155',
  'S4: nonblocking FedAvg task has no task_done_cb; delete broadcast copy AFTER removal. Version retained only as a trace/provenance ghost.',r'''
    /\ s.comm.kind = "monitor" /\ s.comm.pc = "exitCleanup"
    /\ s' = [s EXCEPT !.task[s.comm.id[1]].cleaned = TRUE,
                     !.comm = EmptyComm, !.mon.pc = "idle"]
''')
A('WFCommMonitorNoTask',[], 'nvflare/apis/impl/wf_comm_server.py:1067-1070,1113-1114',
  'S4/S5: empty standing queue; no callbacks or policy-independent retirement is invented.',r'''
    /\ s.comm.kind = "monitor" /\ s.comm.pc = "select"
    /\ (\A t \in Tasks : ~s.task[t].standing)
    /\ s' = [s EXCEPT !.comm = EmptyComm, !.mon.pc = "idle"]
''')
A('FedAvgPollStanding',[], 'nvflare/app_common/workflows/fedavg.py:223-230; nvflare/apis/impl/wf_comm_server.py:786-792',
  'S4: read queue length without communicator lock; status and abort are NOT checked when the queue is empty.',r'''
    /\ s.wf.pc = "wait"
    /\ s' = [s EXCEPT !.wf.pc = IF \E t \in Tasks : s.task[t].standing
                                THEN "abortPoll" ELSE "aggregate"]
''')
A('FedAvgPollAbort',[], 'nvflare/app_common/workflows/fedavg.py:224-228',
  'S4/S5: abort polling occurs only after a nonempty queue observation; no global abort guard on all actions.',r'''
    /\ s.wf.pc = "abortPoll"
    /\ s' = [s EXCEPT !.wf.pc = IF s.wf.abort THEN "returned" ELSE "wait",
                     !.wf.outcome = IF s.wf.abort THEN "aborted" ELSE @]
''')
A('FedAvgGetAggregationStats',[], 'nvflare/app_common/workflows/fedavg.py:230-233,345-351; nvflare/app_common/aggregators/weighted_aggregation_helper.py:242-265',
  'S3: copy actual helper histories and stats into aggregate-result observation before get_result resets helpers.',r'''
    /\ s.wf.pc = "aggregate"
    /\ s' = [s EXCEPT !.scratch.stats = s.aggr.stats,
          !.scratch.paramHistory = s.aggr.paramHistory, !.wf.pc = "params"]
''')
A('WeightedGetParamResult',[], 'nvflare/app_common/aggregators/weighted_aggregation_helper.py:226-240; nvflare/app_common/workflows/fedavg.py:351',
  'S3: aggregate successful key updates, then reset parameter helper. Normal positive-weight arithmetic preserves symbolic provenance.',r'''
    /\ s.wf.pc = "params"
    /\ s' = [s EXCEPT !.scratch.params = s.aggr.applied,
          !.aggr.applied = [k \in Keys |-> <<>>], !.aggr.stats = [k \in Keys |-> <<>>],
          !.aggr.paramHistory = <<>>, !.wf.pc = "metrics"]
''')
A('WeightedGetMetricResult',[], 'nvflare/app_common/workflows/fedavg.py:352-353; nvflare/app_common/aggregators/weighted_aggregation_helper.py:226-240',
  'S3/S5: allMetrics false suppresses metric output and skips get_result entirely; do not conflate partial helper state with used metrics.',r'''
    /\ s.wf.pc = "metrics"
    /\ s' = [s EXCEPT !.scratch.metrics = IF s.aggr.allMetrics THEN s.aggr.metricApplied ELSE <<>>,
          !.scratch.metricStats = IF s.aggr.allMetrics THEN s.aggr.metricStats ELSE <<>>,
          !.scratch.metricHistory = IF s.aggr.allMetrics THEN s.aggr.metricHistory ELSE <<>>,
          !.scratch.allMetrics = s.aggr.allMetrics,
          !.aggr.metricApplied = IF s.aggr.allMetrics THEN <<>> ELSE @,
          !.aggr.metricStats = IF s.aggr.allMetrics THEN <<>> ELSE @,
          !.aggr.metricHistory = IF s.aggr.allMetrics THEN <<>> ELSE @, !.wf.pc = "build"]
''')
A('FedAvgBuildAggregateResult',[], 'nvflare/app_common/workflows/fedavg.py:355-365',
  'S3: FLModel metadata uses callback received_count independently from helper stats.',r'''
    /\ s.wf.pc = "build"
    /\ s' = [s EXCEPT !.scratch.count = s.aggr.receivedCount,
          !.scratch.counted = s.aggr.counted, !.wf.pc = "update"]
''')
A('BaseFedAvgUpdateModel',[], 'nvflare/app_common/workflows/fedavg.py:234-238; nvflare/app_common/workflows/base_fedavg.py:302-322; nvflare/app_common/utils/fl_model_utils.py:233-239',
  'S3/S4: FULL result becomes global model; committed observation includes rejected partial updates if implementation retained them. No status/acceptance guard.',r'''
    /\ s.wf.pc = "update"
    /\ s' = [s EXCEPT !.used[s.wf.round] = s.scratch, !.committed = @ \cup {s.wf.round},
          !.wf.sourceVersion = s.wf.round, !.wf.pc = "save"]
''')
A('FedAvgSaveModel',[], 'nvflare/app_common/workflows/fedavg.py:257-259,489-504; nvflare/app_common/workflows/base_model_controller.py:439-446',
  'S3/S4: declared successful persistor/file save observation; no durability claim. No task-status guard.',r'''
    /\ s.wf.pc = "save"
    /\ s' = [s EXCEPT !.saved = @ \cup {s.wf.round}, !.wf.pc = "advance"]
''')
A('FedAvgAdvanceRound',[], 'nvflare/app_common/workflows/fedavg.py:186,261-266; nvflare/private/fed/server/server_runner.py:151-183',
  'S4: ordinary next loop or Finished FedAvg observation; aborted runner is still separately observable through wf.abort.',r'''
    /\ s.wf.pc = "advance"
    /\ s' = [s EXCEPT !.wf.pc = IF s.wf.round < NumRounds THEN "start" ELSE "returned",
                     !.wf.outcome = IF s.wf.round = NumRounds THEN "normal" ELSE @]
''')
A('ServerRunnerCloseWorkflow',[], 'nvflare/private/fed/server/server_runner.py:157-171',
  'S2/S4: after control_flow return, close current_wf under runner lock before communicator finalization.',r'''
    /\ s.wf.pc = "returned" /\ RunnerLockFree
    /\ s' = [s EXCEPT !.wf.open = FALSE, !.wf.pc = "finalize"]
''')
A('WFCommFinalizeRun',[], 'nvflare/apis/impl/wf_comm_server.py:829-895; nvflare/private/fed/server/server_runner.py:170-178',
  'S2/S4/S5: finalization waits for communicator lock; synchronously drain remaining tasks and clear completed history; no rollback of accepted work.',r'''
    /\ s.wf.pc = "finalize" /\ s.comm.kind = "free" /\ s.mon.pc /= "dead"
    /\ s' = [s EXCEPT !.task = [t \in Tasks |-> [s.task[t] EXCEPT
             !.status = IF s.task[t].standing /\ @ = "LIVE" THEN "CANCELLED" ELSE @,
             !.retiredStatus = IF s.task[t].standing
                     THEN IF s.task[t].status = "LIVE" THEN "CANCELLED" ELSE s.task[t].status ELSE @,
             !.retiredOutstanding = IF s.task[t].standing THEN Outstanding(t) ELSE @,
             !.standing = FALSE, !.cleaned = s.task[t].scheduled]],
             !.completed = <<>>, !.mon.pc = "stopped", !.wf.pc = "finalized"]
''')
# Preserve caller-side wf_lock acquisition, activity reporting and wait-for-comm windows.
parts[0]=parts[0].replace('"check", "queued",', '"check", "checking", "queued",')
parts[0]=parts[0].replace('EmptyComm ==', 'EmptyRunner == [kind |-> "free", pc |-> "idle", client |-> "", id |-> NoId, attempt |-> 0]\nEmptyComm ==')
parts[0]=parts[0].replace('comm |-> EmptyComm, aggr |->', 'comm |-> EmptyComm, runner |-> EmptyRunner, requested |-> {}, aggr |->')
parts[0]=parts[0].replace('mon |-> [pc |-> "idle", pending |-> {}, deadView |-> {}]', 'mon |-> [pc |-> "idle", pending |-> {}, deadView |-> {}, reportAges |-> [c \\in Clients |-> 0]]')
parts[0]=parts[0].replace('RunnerLockFree == s.comm.kind \\notin {"request", "submit"}', 'RunnerLockFree == s.runner.kind = "free"')
def edit_action(name, fn, source=None, trigger=None, fault='keep'):
 for i,piece in enumerate(parts):
  if '\n'+name+'(' in piece or '\n'+name+' ==' in piece: parts[i]=fn(piece)
 for a in actions:
  if a['name']==name:
   if source: a['source']=source
   if trigger:a['trigger']=trigger
   if fault!='keep':a['fault']=fault
edit_action('WFCommScheduleTask',lambda x:x.replace('/\\ s.wf.pc = "schedule"','/\\ s.wf.pc = "schedule"\n    /\\ (s.comm.kind /= "monitor" \\/ s.comm.pc = "exitCleanup")'))
edit_action('WFCommProcessTaskRequest',lambda x:x.replace('/\\ s.wf.open /\\ s.comm.kind = "free" /\\ s.wf.round \\in Tasks',
 '/\\ s.wf.open /\\ s.comm.kind = "free" /\\ s.wf.round \\in Tasks\n    /\\ s.runner.kind = "request" /\\ s.runner.pc = "commWait" /\\ s.runner.client = c'))
edit_action('WFCommResendTask',lambda x:x.replace('/\\ s.wf.open /\\ s.comm.kind = "free" /\\ LiveMap(id)',
 '/\\ s.wf.open /\\ s.comm.kind = "free" /\\ LiveMap(id)\n    /\\ s.runner.kind = "request" /\\ s.runner.pc = "commWait" /\\ s.runner.client = id[2]'),fault=None)
for name in ['WFCommPublishClientTask','WFCommTaskTryAgain','WFCommStampReceipt','WFCommDropSubmission']:
 edit_action(name,lambda x:x.replace('!.comm = EmptyComm]', '!.comm = EmptyComm, !.runner = EmptyRunner]'))
edit_action('ClientRetryResult',lambda x:x,fault=None)
edit_action('ClientCheckTask',lambda x:x.replace('s.net[id[1]][id[2]][n] = "check"','s.net[id[1]][id[2]][n] = "checking"'))
# Replace ingress action: caller wf_lock spans activity reporting and communicator wait.
for i,piece in enumerate(parts):
 if '\nServerRunnerProcessSubmission(' in piece:
  parts[i]=r'''
\* nvflare/private/fed/server/server_runner.py:460-475.
\* S2/S4: runner admission is checked once under wf_lock; abort sets status=done.
ServerRunnerProcessSubmission(id, n) ==
    /\ n \in 1..Len(s.net[id[1]][id[2]]) /\ s.net[id[1]][id[2]][n] = "queued"
    /\ RunnerLockFree
    /\ s' = [s EXCEPT !.runner = [EmptyRunner EXCEPT !.kind = "submit",
              !.pc = IF s.wf.open /\ ~s.wf.abort THEN "activity" ELSE "closed",
              !.id = id, !.attempt = n]]
'''
  break
for a in actions:
 if a['name']=='ServerRunnerProcessSubmission':
  a['source']='nvflare/private/fed/server/server_runner.py:460-475'
  a['trigger']='S2/S4: acquire caller wf_lock and check runner admission once; abort has set runner status=done.'
edit_action('WFCommMonitorBegin',lambda x:x.replace('!.mon.pending = Clients]', '!.mon.pending = Clients,\n              !.mon.reportAges = [c \\in Clients |-> s.dead[c].age]]'))
edit_action('WFCommCheckDeadClient',lambda x:x.replace('s.dead[c].age = 2','s.mon.reportAges[c] = 2'))
A('ServerRunnerTaskRequestActive',['c'], 'nvflare/private/fed/server/server_runner.py:289-298,572-578; nvflare/apis/impl/wf_comm_server.py:1250-1259; nvflare/private/fed/client/client_runner.py:548-588',
  'S1/S5: request activity clears dead state before the separate get-task lock acquisition; capture only task-relevant polls.',r'''
    /\ s.wf.open /\ ~s.wf.abort /\ RunnerLockFree /\ s.mon.pc /= "dead" /\ c \in Selected
    /\ ClientCanPoll(c)
    /\ c \notin s.requested
    /\ (\E t \in Tasks : s.task[t].standing /\ ~s.ct[t][c].receipt)
    /\ s' = [s EXCEPT !.dead[c] = [reported |-> FALSE, age |-> 0, disconnected |-> FALSE],
                     !.requested = @ \cup {c}]
''')
A('ServerRunnerAcquireTaskRequest',['c'], 'nvflare/private/fed/server/server_runner.py:385-395',
  'S1/S4: acquire wf_lock before waiting for communicator; monitor may still own communicator.',r'''
    /\ c \in s.requested /\ RunnerLockFree
    /\ s' = [s EXCEPT !.requested = @ \ {c},
          !.runner = [EmptyRunner EXCEPT !.kind = "request", !.pc = "commWait", !.client = c]]
''')
A('WFCommTaskUnavailable',[], 'nvflare/private/fed/server/server_runner.py:386-395; nvflare/apis/impl/wf_comm_server.py:220-272; nvflare/apis/impl/task_manager.py:61-70',
  'S1/S4: stale task-relevant poll finds no eligible task after waiting; unmodeled no-op polling is not silently allowed to change state.',r'''
    /\ s.runner.kind = "request" /\ s.comm.kind = "free"
    /\ ~(\E t \in Tasks : s.wf.open /\ s.task[t].standing /\ s.task[t].status = "LIVE"
                         /\ ~s.ct[t][s.runner.client].receipt
                         /\ (~s.ct[t][s.runner.client].assigned \/
                              (s.ct[t][s.runner.client].delivery = "failed" /\
                               s.ct[t][s.runner.client].result = "none")))
    /\ s' = [s EXCEPT !.runner = EmptyRunner]
''')
A('ServerRunnerCheckTaskActive',['id','n'], 'nvflare/private/fed/server/server_runner.py:585-605,572-578; nvflare/apis/impl/wf_comm_server.py:1250-1259',
  'S2/S5: task-check activity reporting releases wf_lock before the separate mapping lookup.',r'''
    /\ n \in 1..Len(s.net[id[1]][id[2]]) /\ s.net[id[1]][id[2]][n] = "check"
    /\ RunnerLockFree /\ s.mon.pc /= "dead"
    /\ s' = [s EXCEPT !.net[id[1]][id[2]][n] = "checking",
          !.dead[id[2]] = IF s.wf.open THEN [reported |-> FALSE, age |-> 0, disconnected |-> FALSE] ELSE @]
''')
A('ServerRunnerSubmissionActive',[], 'nvflare/private/fed/server/server_runner.py:463-475,572-578; nvflare/apis/impl/wf_comm_server.py:1250-1259',
  'S2/S5: admitted submission clears disconnect state while retaining caller wf_lock; dead-report checks may run independently before communicator is acquired.',r'''
    /\ s.runner.kind = "submit" /\ s.runner.pc = "activity" /\ s.mon.pc /= "dead"
    /\ s' = [s EXCEPT !.dead[s.runner.id[2]] = [reported |-> FALSE, age |-> 0, disconnected |-> FALSE],
                     !.runner.pc = "commWait"]
''')
A('WFCommAcquireSubmission',[], 'nvflare/private/fed/server/server_runner.py:559-565; nvflare/apis/impl/wf_comm_server.py:434-451',
  'S2/S3: acquire communicator after caller admission; a newly triggered abort does not retroactively revoke the admitted handler.',r'''
    /\ s.runner.kind = "submit" /\ s.runner.pc = "commWait" /\ s.comm.kind = "free"
    /\ s' = [s EXCEPT !.comm = [EmptyComm EXCEPT !.kind = "submit", !.pc = "dispatch",
                   !.id = s.runner.id, !.attempt = s.runner.attempt], !.runner.pc = "busy"]
''')
A('ServerRunnerDropClosedSubmission',[], 'nvflare/private/fed/server/server_runner.py:463-470; nvflare/private/fed/server/server_commands.py:242-246',
  'S2/S4: closed/done runner returns before activity or communicator dispatch; command ACK remains distinct.',r'''
    /\ s.runner.kind = "submit" /\ s.runner.pc = "closed"
    /\ s' = [s EXCEPT !.net[s.runner.id[1]][s.runner.id[2]][s.runner.attempt] = "handled",
                     !.runner = EmptyRunner]
''')

# Emit disjunction; domains are part of cooperative/finite environment, not correctness restrictions.
dom={'c':'Clients','id':'Ids','n':'1..Len(s.net[id[1]][id[2]])','kind':'{"params","empty"}','mk':'MetricKinds','t':'Tasks'}
def call(a):
    exp=a['name']+('('+', '.join(a['args'])+')' if a['args'] else '')
    for arg in reversed(a['args']): exp='\\E '+arg+' \\in '+dom[arg]+' : '+exp
    return exp
parts.append('\n\\* Environment and all implementation steps. Stuttering is supplied by Spec.\nNext ==\n    \\/ '+'\n    \\/ '.join(call(a) for a in actions)+'\n\nSpec == Init /\\ [][Next]_vars\n')
parts.append(r'''
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
''')
# Retry only the last lost attempt, never fabricate retries after success.
parts=[p.replace('\\E n \\in 1..Len(s.net[id[1]][id[2]]) : s.net[id[1]][id[2]][n] = "lost"',
                 's.net[id[1]][id[2]][Len(s.net[id[1]][id[2]])] = "lost"') for p in parts]
(D/'base.tla').write_text(''.join(parts))
(D/'checks/action-map.json').write_text(json.dumps(actions,indent=2)+'\n')
(D/'base.cfg').write_text('''INIT Init
NEXT Next
CHECK_DEADLOCK FALSE
CONSTANTS
    Clients = {"c1", "c2"}
    Selected = {"c1", "c2"}
    NumRounds = 2
    NumKeys = 2
    HistoryLimit = 4
    ErrorMode = "dynamic"
    OutboundFilter = FALSE
    LazyOffload = FALSE
    AllocationFailure = FALSE
    ConversionFailure = FALSE
    BeforeSendFailure = FALSE
    AllowEmpty = TRUE
    MetricKinds = {"present", "none", "empty"}
    MinSites = 2
    RequiredSites = {}
    AllowPartialCompletion = FALSE
INVARIANTS
    TypeOK
    ProtectedBroadcastInput
    AtMostOneConsumer
    ReceiptAfterDecision
    CommittedRoundProvenance
    OneStandingTask
    CompletedHistoryBound
    CallbackRoundIsolation
    SavedWasCommitted
    CountMatchesSuccessfulReturns
\\* Candidate assertions are enabled individually in MC_hunt_*.cfg.
\\* CommittedAcceptanceConsistency
\\* AbnormalTerminationVisible
\\* Base is unbounded for retry injections; use MC.cfg for finite exploration.
''')
print(f'Wrote base.tla/base.cfg with {len(actions)} actions')
