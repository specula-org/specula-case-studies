# Copyright (c) 2026, NVIDIA CORPORATION. All rights reserved.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy at http://www.apache.org/licenses/LICENSE-2.0
# Distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND.
"""Observation ledgers for real NVFlare boundary hooks; never executes TLA actions.

PCs, identities, versions and successful-mutation provenance are ghosts. Values
with runtime counterparts are read or cross-checked at their capture boundary.
The scheduler pauses outside the writer lock and never changes protocol locks.
"""
import copy
import hashlib
import json
import os
from pathlib import Path
import queue
import threading
import time

ACTIVE = None
NO_ID = [0, ""]


def runner_empty():
    return dict(kind="free", pc="idle", client="", id=NO_ID.copy(), attempt=0)


def comm_empty():
    return dict(
        kind="free",
        pc="idle",
        id=NO_ID.copy(),
        attempt=0,
        key=1,
        accepted=False,
        exit="LIVE",
        writeStatus=False,
        pending=[],
        deadView=[],
    )


def aggregate_empty(t):
    return dict(
        task=t,
        applied=[[], []],
        stats=[[], []],
        paramHistory=[],
        metricApplied=[],
        metricStats=[],
        metricHistory=[],
        allMetrics=True,
        receivedCount=0,
        counted=[],
        failedClients=[],
    )


def used_empty():
    return dict(
        params=[[], []],
        stats=[[], []],
        paramHistory=[],
        metrics=[],
        metricStats=[],
        metricHistory=[],
        allMetrics=True,
        count=0,
        counted=[],
    )


def client_empty():
    return dict(
        assigned=False,
        headerId=NO_ID.copy(),
        headerRound=-1,
        inputVersion=-1,
        delivery="none",
        result="none",
        metricKind="none",
        receipt=False,
        decision="pending",
        invocations=0,
    )


def task_empty():
    return dict(
        scheduled=False,
        standing=False,
        status="NEW",
        sourceAtSchedule=-1,
        broadcastVersion=-1,
        assignedOrder=[],
        age=0,
        cleaned=False,
        retiredStatus="NEW",
        retiredOutstanding=[],
    )


def dead_empty():
    return dict(reported=False, age=0, disconnected=False)


class ObservationError(BaseException):
    """Must not be swallowed by production's ordinary runtime error handling."""


def hook(name, context):
    if ACTIVE is not None:
        try:
            ACTIVE.observe(name, context)
        except Exception as exc:
            ACTIVE.errors.append(f"{name}: {exc!r}")
            raise ObservationError(f"{name}: {exc!r}") from exc


def pause(name, context):
    if ACTIVE is not None:
        ACTIVE.pause(name)


def fault(name, context):
    if ACTIVE is not None:
        ACTIVE.fault(name, context)


def poll_standing(controller, value):
    hook("FedAvgPollStanding", dict(self=controller, value=value))
    return value


def poll_abort(controller, value):
    hook("FedAvgPollAbort", dict(self=controller, value=value))
    return value


class Observer:
    def __init__(self, path, config, controller, communicator, server, clock):
        self.path = Path(path)
        self.file = self.path.open("w")
        self.lock = threading.Lock()
        self.config = config
        self.controller, self.communicator, self.server, self.clock = controller, communicator, server, clock
        self.clients = config["Clients"]
        n = config["NumRounds"]
        self.s = dict(
            wf=dict(round=0, pc="start", sourceVersion=0, started=[], abort=False, outcome="running", open=True),
            task=[task_empty() for _ in range(n)],
            ct=[{c: client_empty() for c in self.clients} for _ in range(n)],
            net=[{c: [] for c in self.clients} for _ in range(n)],
            comm=comm_empty(),
            runner=runner_empty(),
            requested=[],
            aggr=aggregate_empty(0),
            scratch=used_empty(),
            used=[used_empty() for _ in range(n)],
            committed=[],
            saved=[],
            completed=[],
            unknownSeen=[],
            dead={c: dead_empty() for c in self.clients},
            mon=dict(pc="idle", pending=[], deadView=[], reportAges={c: 0 for c in self.clients}),
        )
        self.seq = 0
        self.tasks, self.ids, self.ct_refs = {}, {}, {}
        self.gates = {n: queue.Queue() for n in ["round_wait", "monitor", "poll_sleep", "callback"]}
        self.releases = []
        self.stopping = False
        self.errors = []
        self.event_counts = {}
        self.faults = {}
        self.pause_event = None
        self.last_dead = None
        self.started = False
        self.model_hashes = {}
        self.version_hashes = {0: self.params_hash(controller.model)}
        self.result_values = {}

    def begin(self):
        assert not self.communicator._tasks and not self.communicator._client_task_map
        assert not self.communicator._completed_client_task_map
        assert not self.server.abort_signal.triggered
        assert self.server.current_wf is not None
        assert self.controller.start_round == 0 and self.controller.current_round is None
        assert self.controller._received_count == 0
        self.write(
            dict(
                tag="specula-meta",
                schema=1,
                sourceHead="53ba7ee567468ea7971dad4faccef13c6cb35dc2",
                origin="implementation",
                config=self.config,
                initial=self.s,
            )
        )
        self.started = True

    def write(self, record):
        record = dict(record, ts=time.monotonic_ns())
        self.file.write(json.dumps(record, separators=(",", ":"), sort_keys=True) + "\n")
        self.file.flush()

    def diagnostic(self, **data):
        with self.lock:
            self.write(dict(tag="observation", **{k: v for k, v in data.items() if v is not None}))

    def pause(self, name):
        if self.stopping:
            return
        event = threading.Event()
        self.releases.append(event)
        self.gates[name].put(event)
        if not event.wait(45):
            self.errors.append(f"scheduler gate timed out: {name}")
            raise ObservationError(f"scheduler gate timed out: {name}")

    def wait(self, name):
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            assert not self.errors, self.errors
            try:
                return self.gates[name].get(timeout=0.1)
            except queue.Empty:
                pass
        raise AssertionError("scheduler wait timeout: " + name)

    def close(self):
        self.file.close()

    def normalized(self, raw):
        return self.ids[raw].copy()

    def register(self, ct):
        t = self.controller.current_round + 1
        value = [t, ct.client.name]
        if ct.id in self.ids:
            assert self.ids[ct.id] == value
        else:
            assert value not in list(self.ids.values()), "ClientTask mapping is not injective"
            self.ids[ct.id] = value
            self.ct_refs[ct.id] = ct
        assert ct.task is self.tasks[t] and ct.task.name == "train"
        return value.copy()

    def task_status(self, task):
        return task.completion_status.name if task.completion_status is not None else "LIVE"

    def active(self):
        return self.s["comm"]["id"]

    def ct(self, id):
        return self.s["ct"][id[0] - 1][id[1]]

    def attempts(self, id):
        return self.s["net"][id[0] - 1][id[1]]

    def outstanding(self, t):
        return [c for c in self.config["Selected"] if not self.s["ct"][t - 1][c]["receipt"]]

    def dead_read(self, c):
        d = self.communicator._dead_clients.get(c)
        return (
            dead_empty()
            if d is None
            else dict(
                reported=True,
                age=min(2, int((self.clock.time() - d.report_time) // 30)),
                disconnected=bool(d.disconnect_time),
            )
        )

    def emit_locked(self, name, args=(), nid="server"):
        self.seq += 1
        self.event_counts[name] = self.event_counts.get(name, 0) + 1
        self.write(dict(tag="trace", event=dict(name=name, nid=nid, args=list(args), seq=self.seq, state=self.s)))

    def fault(self, name, L):
        if not self.started or not self.faults:
            return
        id = self.active()
        if name == "before_send":
            id = self.register(L["client_task"])
        key = L.get("k")
        selector = (name, tuple(id), key)
        if self.faults.pop(selector, False):
            self.diagnostic(
                fault=name, id=id, key=key, exception="MemoryError" if name != "before_send" else "RuntimeError"
            )
            if name == "before_send":
                raise RuntimeError("ordinary before-send handler fixture failure")
            raise MemoryError("ordinary allocation failure fixture at " + name)

    def observe(self, name, L):
        if name == "poll_sleep":
            self.pause("poll_sleep")
            return
        if not self.started:
            if name == "bootstrap":
                self.begin()
                return
            else:
                return
        original_name = name
        with self.lock:
            s, wf, a, m = self.s, self.s["wf"], self.s["aggr"], self.s["mon"]
            q, r = s["comm"], s["runner"]
            ctl, comm = self.controller, self.communicator
            args, nid = [], "server"
            if name == "FedAvgRoundStarted":
                wf["round"] = ctl.current_round + 1
                assert L["model"].current_round == ctl.current_round
                wf["started"].append(wf["round"])
                wf["pc"] = "reset"
            elif name == "FedAvgResetAggregation":
                assert not ctl._aggr_helper.total and not ctl._aggr_metrics_helper.total and ctl._received_count == 0
                s["aggr"] = aggregate_empty(wf["round"])
                s["scratch"] = used_empty()
                wf["pc"] = "schedule"
            elif name == "WFCommScheduleTask":
                task = L["task"]
                t = ctl.current_round + 1
                self.tasks[t] = task
                assert task.timeout == 0 and set(task.targets) == set(self.config["Selected"])
                assert task.is_standing and task in comm._tasks
                st = s["task"][t - 1]
                st.update(
                    scheduled=task.schedule_time is not None,
                    standing=task.is_standing,
                    status=self.task_status(task),
                    sourceAtSchedule=self.observed_version(task.data, wf["sourceVersion"]),
                )
                self.model_hashes[t] = self.payload_hash(task.data)
                wf["pc"] = "wait"
            elif name == "ServerRunnerTaskRequestActive":
                c = L["client"].name
                args = [c]
                s["dead"][c] = self.dead_read(c)
                s["requested"].append(c)
            elif name == "ServerRunnerAcquireTaskRequest":
                c = L["client"].name
                args = [c]
                s["requested"].remove(c)
                s["runner"] = dict(runner_empty(), kind="request", pc="commWait", client=c)
            elif name == "request_selected":
                ct = L["client_task_to_send"]
                id = self.register(ct)
                s["comm"] = dict(comm_empty(), kind="request", pc="before", id=id)
                name = "WFCommResendTask" if L["resend_task"] else "WFCommProcessTaskRequest"
                args = [id] if L["resend_task"] else [ct.client.name]
            elif name == "BasePrepareTaskData":
                q["pc"] = "snapshot"
            elif name == "BasePrepareTaskDataFailure":
                if q["pc"] != "before":
                    return
                assert L["task"].exception is not None
                s["task"][self.active()[0] - 1]["status"] = self.task_status(L["task"])
                q["pc"] = "snapshot"
            elif name == "protect":
                task = L["task"]
                t = self.active()[0]
                if hasattr(task, "_broadcast_data"):
                    s["task"][t - 1]["broadcastVersion"] = self.observed_version(
                        task._broadcast_data, s["task"][t - 1]["sourceAtSchedule"]
                    )
                    name = "WFCommProtectBroadcast"
                else:
                    s["task"][t - 1]["status"] = self.task_status(task)
                    name = "WFCommProtectBroadcastFailure"
                q["pc"] = "canSend"
            elif name == "WFCommCheckCanSend":
                q["pc"] = "publish" if L["can_send_task"] else "tryAgain"
            elif name == "request_return_empty":
                name = "WFCommTaskTryAgain" if q["pc"] == "tryAgain" else "WFCommTaskUnavailable"
                s["comm"] = comm_empty()
                s["runner"] = runner_empty()
            elif name == "WFCommPublishClientTask":
                from nvflare.apis.shareable import ReservedHeaderKey as RH
                from nvflare.app_common.app_constant import AppConstants as AC

                id = self.normalized(L["task_id"])
                t, c = id
                data = L["task_data"]
                ct = self.ct(id)
                assert data.get_header(RH.TASK_ID) == L["task_id"] and data.get_header(RH.TASK_NAME) == "train"
                assert data.get_cookie(RH.WORKFLOW) == self.server.current_wf.id
                ct.update(
                    assigned=L["task_id"] in comm._client_task_map,
                    headerId=id,
                    headerRound=data.get_header(AC.CURRENT_ROUND),
                    inputVersion=self.observed_version(data, s["task"][t - 1]["broadcastVersion"]),
                    delivery="filter",
                )
                s["task"][t - 1]["assignedOrder"] = [self.normalized(x.id) for x in self.tasks[t].client_tasks]
                s["comm"] = comm_empty()
                s["runner"] = runner_empty()
            elif name in [
                "ServerRunnerFilterTask",
                "ServerRunnerFilterFailure",
                "WFCommHandleException",
                "TaskDeliveryFailure",
            ]:
                id = self.normalized(L["task_id"])
                args = [id]
                self.ct(id)["delivery"] = {
                    "ServerRunnerFilterTask": "wire",
                    "ServerRunnerFilterFailure": "filterFailed",
                    "WFCommHandleException": "failed",
                    "TaskDeliveryFailure": "failed",
                }[name]
                if name == "WFCommHandleException":
                    s["task"][id[0] - 1]["status"] = self.task_status(self.tasks[id[0]])
                if name == "TaskDeliveryFailure":
                    nid = "transport"
            elif name == "ClientReceiveTask":
                id = self.normalized(L["task"].task_id)
                args = [id]
                nid = id[1]
                assert self.payload_hash(L["task"].data) == self.model_hashes[id[0]]
                self.ct(id)["delivery"] = "ready"
            elif name == "client_processed":
                from nvflare.app_common.utils.fl_model_utils import FLModelUtils
                from nvflare.apis.fl_constant import ReturnCode
                from nvflare.apis.shareable import ReservedHeaderKey as RH

                task, reply = L["task"], L["reply"]
                id = self.normalized(task.task_id)
                assert reply.get_header(RH.TASK_ID) == task.task_id
                assert reply.get_cookie_jar() == task.data.get_cookie_jar()
                args = [id]
                nid = id[1]
                if reply.get_return_code() != ReturnCode.OK:
                    self.ct(id)["result"] = "error"
                    name = "ClientExecutionError"
                else:
                    model = FLModelUtils.from_shareable(reply)
                    kind = "params" if model.params else "empty"
                    mk = "none" if model.metrics is None else "present" if model.metrics else "empty"
                    self.ct(id).update(result=kind, metricKind=mk)
                    args += [kind, mk]
                    name = "ClientProcessTask"
                    self.result_values[tuple(id)] = model
                s["net"][id[0] - 1][id[1]] = ["check"]
            elif name in ["ServerRunnerCheckTaskActive", "ClientCheckTask", "ClientRetryResult", "dispatch_ack"]:
                raw = L.get("task_id")
                if raw is None:
                    raw = L["request"].get_header("__task_id__")
                id = self.normalized(raw)
                attempts = self.attempts(id)
                if name == "ClientRetryResult":
                    attempts.append("check")
                    args = [id]
                    nid = id[1]
                elif name == "ServerRunnerCheckTaskActive":
                    attempts[-1] = "checking"
                    s["dead"][id[1]] = self.dead_read(id[1])
                    args = [id, len(attempts)]
                elif name == "ClientCheckTask":
                    attempts[-1] = "queued" if L["_st_check_reply"].get_return_code() == "OK" else "gone"
                    args = [id, len(attempts)]
                else:
                    assert attempts[-1] == "handled"
                    attempts[-1] = "ack" if L["reply_sent"] else "lost"
                    name = "ServerCommandDispatchAck" if L["reply_sent"] else "ClientLoseDispatchAck"
                    args = [id, len(attempts)]
                    nid = id[1]
            elif name == "ServerRunnerProcessSubmission":
                id = self.normalized(L["task_id"])
                n = len(self.attempts(id))
                args = [id, n]
                s["runner"] = dict(
                    runner_empty(),
                    kind="submit",
                    pc="activity" if self.server.status == "started" and self.server.current_wf else "closed",
                    id=id,
                    attempt=n,
                )
            elif name == "ServerRunnerSubmissionActive":
                s["dead"][r["id"][1]] = self.dead_read(r["id"][1])
                r["pc"] = "commWait"
            elif name == "WFCommAcquireSubmission":
                s["comm"] = dict(comm_empty(), kind="submit", pc="dispatch", id=r["id"].copy(), attempt=r["attempt"])
                r["pc"] = "busy"
            elif name in ["dispatch_missing", "dispatch_live"]:
                name = "WFCommDispatchSubmission"
                ct = L["client_task"]
                if ct is None:
                    q["pc"] = "drop" if L["completed_client_task"] else "unknown"
                else:
                    assert ct.client.name == L["client"].name and ct.task.name == L["task_name"]
                    q["pc"] = (
                        "drop"
                        if ct.task.completion_status is not None or ct.result_received_time is not None
                        else "prelim"
                    )
                s["completed"] = [self.normalized(x) for x in comm._completed_client_task_map]
            elif name == "BaseAcceptTrainResult":
                wf["abort"] = self.server.abort_signal.triggered
                a["failedClients"] = sorted(ctl._current_failed_clients)
                q["pc"] = "convert" if L["preliminarily_accepted"] else "decision"
            elif name == "BaseConvertResult":
                assert L["result_model"].meta["client_name"] == self.active()[1]
                self.ct(self.active())["invocations"] += 1
                q["pc"] = "consumer"
            elif name == "BaseConvertResultFailure":
                q["pc"] = "decision"
            elif name == "FedAvgAggregateOneResult":
                q["pc"] = "paramStats" if L["result"].params else "decision"
                q["key"] = 1
            elif name in ["helper_stats", "helper_value", "helper_history"]:
                helper = L["self"]
                metric = helper is ctl._aggr_metrics_helper
                assert metric or helper is ctl._aggr_helper
                id = self.active().copy()
                k = L.get("k")
                if name == "helper_stats":
                    ledger = a["metricStats"] if metric else a["stats"][["w1", "w2"].index(k)]
                    ledger.append(id)
                    assert helper.key_contribution_counts[k] == len(ledger)
                    q["pc"] = "metricValue" if metric else "paramValue"
                    name = "WeightedAddMetricStats" if metric else "WeightedAddParamStats"
                elif name == "helper_value":
                    ledger = a["metricApplied"] if metric else a["applied"][["w1", "w2"].index(k)]
                    ledger.append(id)
                    assert helper.counts[k] == len(ledger)
                    values = [
                        (self.result_values[tuple(x)].metrics if metric else self.result_values[tuple(x)].params)[k]
                        for x in ledger
                    ]
                    assert float(helper.total[k]) == sum(float(x) for x in values)
                    if metric:
                        q["pc"] = "metricHistory"
                    else:
                        q["key"] = ["w1", "w2"].index(k) + 2
                        q["pc"] = "paramHistory" if k == "w2" else "paramStats"
                    name = "WeightedAddMetricValue" if metric else "WeightedAddParamValue"
                else:
                    history = [[x["round"] + 1, x["contributor_name"]] for x in helper.history]
                    a["metricHistory" if metric else "paramHistory"] = history
                    q["pc"] = "count" if metric else "metrics"
                    name = "WeightedAddMetricHistory" if metric else "WeightedAddParamHistory"
            elif name == "FedAvgProcessMetrics":
                a["allMetrics"] = ctl._all_metrics
                q["pc"] = "metricStats" if L.get("aggregatable") and ctl._all_metrics else "count"
            elif name == "consumer_failure":
                assert isinstance(L["e"], MemoryError), type(L["e"])
                name = {
                    "paramValue": "WeightedParamFailure",
                    "metrics": "FedAvgMetricPreparationFailure",
                    "metricValue": "WeightedMetricFailure",
                }[q["pc"]]
                q["pc"] = "decision"
            elif name == "consumer_return":
                if L["accepted"] is False:
                    return
                name = "FedAvgIncrementReceived"
                a["receivedCount"] = ctl._received_count
                a["counted"].append(self.active().copy())
                assert a["receivedCount"] == len(a["counted"])
                q["accepted"] = True
                q["pc"] = "decision"
            elif name == "BasePublishAcceptance":
                from nvflare.app_common.app_constant import AppConstants

                accepted = L["fl_ctx"].get_prop(AppConstants.AGGREGATION_ACCEPTED)
                self.ct(self.active())["decision"] = "accepted" if accepted else "rejected"
                assert accepted == L["accepted"] == q["accepted"]
                q["pc"] = "cleanup"
            elif name == "BaseClearTrainingResult":
                assert L["client_task"].result is None
                q["pc"] = "receipt"
            elif name == "receipt_observed":
                assert L["client_task"].result_received_time is not None
                return  # grouped emission follows the actual runner and communicator unlocks
            elif name == "BaseProcessUnknownResult":
                id = self.active().copy()
                if id not in s["unknownSeen"]:
                    s["unknownSeen"].append(id)
                q["pc"] = "drop"
            elif name == "submission_return":
                id = self.active().copy()
                if q["pc"] == "receipt":
                    assert self.ct_refs[L["task_id"]].result_received_time is not None
                    self.ct(id)["receipt"] = True
                    name = "WFCommStampReceipt"
                else:
                    assert q["pc"] == "drop", q
                    name = "WFCommDropSubmission"
                self.attempts(id)[q["attempt"] - 1] = "handled"
                s["comm"] = comm_empty()
                s["runner"] = runner_empty()
            elif name == "ServerRunnerDropClosedSubmission":
                self.attempts(r["id"])[r["attempt"] - 1] = "handled"
                s["runner"] = runner_empty()
            elif name == "WFCommCancelTask":
                task = L["task"]
                t = next(t for t, x in self.tasks.items() if x is task)
                # handle_exception has its own combined event and is outside an admitted request scope.
                if any(x["delivery"] == "filterFailed" for x in s["ct"][t - 1].values()):
                    return
                s["task"][t - 1]["status"] = self.task_status(task)
                args = [t]
            elif name in ["WFCommReportDeadClient", "WFCommClientIsActive"]:
                c = L.get("client_name") or L["fl_ctx"].get_peer_context().get_identity_name()
                args = [c]
                if name == "WFCommClientIsActive" and not s["dead"][c]["reported"]:
                    return
                s["dead"][c] = self.dead_read(c)
            elif name == "ClockAdvance":
                nid = "clock"
                for t, task in self.tasks.items():
                    s["task"][t - 1]["age"] = min(1, int((self.clock.time() - task.schedule_time) // 30))
                for c in self.clients:
                    s["dead"][c] = self.dead_read(c)
            elif name == "monitor_begin":
                name = "WFCommMonitorBegin"
                m.update(
                    pc="dead", pending=self.clients.copy(), reportAges={c: s["dead"][c]["age"] for c in self.clients}
                )
                self.last_dead = None
            elif name == "dead_next":
                if self.last_dead is not None:
                    self.emit_dead(self.last_dead)
                self.last_dead = L["client_name"]
                return
            elif name == "monitor_dead_end":
                # Explicit observations for both visited reports and absent watch-list entries.
                if self.last_dead is not None:
                    self.emit_dead(self.last_dead)
                    self.last_dead = None
                for c in m["pending"].copy():
                    self.emit_dead(c)
                m.update(pc="policy", pending=self.clients.copy(), deadView=[])
                name = "WFCommDeadCheckDone"
            elif name == "WFCommReadPolicyClient":
                c = L["client"].name
                args = [c]
                m["pending"].remove(c)
                if L["_st_dead_time"]:
                    m["deadView"].append(c)
            elif name in ["policy_result", "WFCommJobPolicyDecision"]:
                if name == "policy_result" and L["should_abort_job"]:
                    return
                name = "WFCommJobPolicyDecision"
                wf["abort"] = self.server.abort_signal.triggered
                m["pc"] = "stopped" if L["should_abort_job"] else "acquire"
            elif name == "WFCommMonitorAcquire":
                s["comm"] = dict(comm_empty(), kind="monitor", pc="select")
                m["pc"] = "locked"
            elif name in ["WFCommMonitorSelect", "monitor_terminal_selected"]:
                task = L["task"]
                t = next(t for t, x in self.tasks.items() if x is task)
                args = [t]
                q["id"] = [t, ""]
                q["exit"] = "OK" if not self.outstanding(t) else "LIVE"
                q["pending"] = self.outstanding(t) if s["task"][t - 1]["age"] else []
                q["deadView"] = []
                q["pc"] = "remove" if task.completion_status is not None else "mark" if L["should_exit"] else "deadScan"
                name = "WFCommMonitorSelect"
            elif name == "WFCommReadTaskDeadClient":
                c = L["target"]
                args = [c]
                if L["_st_dead_time"]:
                    q["pending"].remove(c)
                    q["deadView"].append(c)
                    if not q["pending"]:
                        q["exit"] = "CLIENT_DEAD"
                else:
                    q.update(pending=[], deadView=[], exit="LIVE")
            elif name == "WFCommTaskDeadCheckDone":
                if L["dead_clients"]:
                    q["pc"] = "mark"
                else:
                    # Grouped return emission deferred until communicator lock releases.
                    return
            elif name == "WFCommMonitorMarkTerminal":
                s["task"][q["id"][0] - 1]["status"] = self.task_status(L["task"])
                q["pc"] = "remove"
            elif name == "WFCommMonitorRemove":
                task = L["exit_task"]
                t = q["id"][0]
                s["task"][t - 1].update(
                    standing=task.is_standing,
                    retiredStatus=self.task_status(task),
                    retiredOutstanding=self.outstanding(t),
                )
                s["completed"] = [self.normalized(x) for x in comm._completed_client_task_map]
                q["pc"] = "exitCleanup"
            elif name == "monitor_return":
                if q["pc"] == "exitCleanup":
                    t = q["id"][0]
                    assert not hasattr(self.tasks[t], "_broadcast_data")
                    s["task"][t - 1]["cleaned"] = True
                    name = "WFCommMonitorCleanup"
                elif q["pc"] == "deadScan":
                    name = "WFCommTaskDeadCheckDone"
                else:
                    assert q["pc"] == "select"
                    name = "WFCommMonitorNoTask"
                s["comm"] = comm_empty()
                m["pc"] = "idle"
            elif name == "FedAvgPollStanding":
                assert L["value"] == len(comm._tasks)
                wf["pc"] = "abortPoll" if L["value"] else "aggregate"
            elif name == "FedAvgPollAbort":
                assert L["value"] == self.server.abort_signal.triggered
                wf["pc"] = "returned" if L["value"] else "wait"
                if L["value"]:
                    wf["outcome"] = "aborted"
            elif name == "FedAvgGetAggregationStats":
                assert L["aggr_stats"]["accepted_contributions"] == len(a["paramHistory"])
                s["scratch"]["stats"] = copy.deepcopy(a["stats"])
                s["scratch"]["paramHistory"] = copy.deepcopy(a["paramHistory"])
                wf["pc"] = "params"
            elif name == "WeightedGetParamResult":
                assert not ctl._aggr_helper.total and not ctl._aggr_helper.history
                s["scratch"]["params"] = copy.deepcopy(a["applied"])
                a.update(applied=[[], []], stats=[[], []], paramHistory=[])
                wf["pc"] = "metrics"
            elif name == "WeightedGetMetricResult":
                sc = s["scratch"]
                sc["allMetrics"] = ctl._all_metrics
                if ctl._all_metrics:
                    sc.update(
                        metrics=copy.deepcopy(a["metricApplied"]),
                        metricStats=copy.deepcopy(a["metricStats"]),
                        metricHistory=copy.deepcopy(a["metricHistory"]),
                    )
                    assert not ctl._aggr_metrics_helper.total
                    a.update(metricApplied=[], metricStats=[], metricHistory=[])
                else:
                    assert L["aggr_metrics"] is None
                wf["pc"] = "build"
            elif name == "FedAvgBuildAggregateResult":
                sc = s["scratch"]
                sc["count"] = L["_st_result"].meta["nr_aggregated"]
                sc["counted"] = copy.deepcopy(a["counted"])
                wf["pc"] = "update"
            elif name == "BaseFedAvgUpdateModel":
                from nvflare.app_common.app_constant import AppConstants

                assert ctl.fl_ctx.get_prop(AppConstants.GLOBAL_MODEL)["weights"] is L["model"].params
                s["used"][wf["round"] - 1] = copy.deepcopy(s["scratch"])
                s["committed"].append(wf["round"])
                wf["sourceVersion"] = wf["round"]
                wf["pc"] = "save"
                self.version_hashes[wf["sourceVersion"]] = self.params_hash(L["model"].params)
            elif name == "FedAvgSaveModel":
                from nvflare.fuel.utils import fobs

                path = Path(ctl.get_run_dir()) / ctl.save_filename
                assert path.is_file() and fobs.loadf(str(path)).params == L["model"].params
                saved = Path(os.environ["HARNESS_REPORT_DIR"]) / "models" / self.path.stem / f'round-{wf["round"]}.fobs'
                saved.parent.mkdir(parents=True, exist_ok=True)
                saved.write_bytes(path.read_bytes())
                self.write(
                    dict(
                        tag="observation",
                        savePath=str(path),
                        preservedSave=str(saved),
                        sha256=hashlib.sha256(saved.read_bytes()).hexdigest(),
                    )
                )
                s["saved"].append(wf["round"])
                wf["pc"] = "advance"
            elif name == "FedAvgAdvanceRound":
                wf["pc"] = "start" if ctl.current_round + 1 < ctl.num_rounds else "returned"
                if wf["pc"] == "returned":
                    wf["outcome"] = "normal"
            elif name == "ServerRunnerCloseWorkflow":
                assert self.server.current_wf is None
                wf.update(open=False, pc="finalize")
            elif name == "WFCommFinalizeRun":
                assert comm._all_done and not comm._tasks and not comm._completed_client_task_map
                for t, task in self.tasks.items():
                    st = s["task"][t - 1]
                    if st["standing"]:
                        st.update(retiredStatus=self.task_status(task), retiredOutstanding=self.outstanding(t))
                    st.update(
                        status=self.task_status(task),
                        standing=task.is_standing,
                        cleaned=not hasattr(task, "_broadcast_data"),
                    )
                s["completed"] = []
                m["pc"] = "stopped"
                wf["pc"] = "finalized"
            else:
                raise AssertionError(f"unhandled observer hook {name}")
            self.emit_locked(name, args, nid)
        if self.pause_event == name:
            self.pause_event = None
            self.pause("callback")

    def emit_dead(self, c):
        self.s["dead"][c] = self.dead_read(c)
        self.s["mon"]["pending"].remove(c)
        self.emit_locked("WFCommCheckDeadClient", [c])

    @staticmethod
    def payload_hash(data):
        from nvflare.app_common.utils.fl_model_utils import FLModelUtils

        model = FLModelUtils.from_shareable(data)
        return Observer.params_hash(model.params)

    @staticmethod
    def params_hash(params):
        payload = {k: float(v) for k, v in params.items()}
        return hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()

    def observed_version(self, data, expected):
        digest = self.payload_hash(data)
        self.write(dict(tag="observation", payloadSha256=digest, expectedVersion=expected))
        if self.version_hashes.get(expected) == digest:
            return expected
        for version, known in self.version_hashes.items():
            if known == digest:
                return version
        # Preserve unexpected content as an explicit out-of-model version. Replay
        # must reject it; never overwrite the observation with the expected label.
        return self.config["NumRounds"] + 1
