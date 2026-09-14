# Copyright (c) 2026, NVIDIA CORPORATION. All rights reserved.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy at http://www.apache.org/licenses/LICENSE-2.0
# Distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND.
"""pytest scenarios using real FedAvg, both runners and WFCommServer.

The engine fixture substitutes local delivery for Cell RPC; it never implements
task management or aggregation. FakeClock is reused from upstream controller tests.
"""
import json
import os
from pathlib import Path
import threading
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

from nvflare import _specula_trace as st
from nvflare.apis.client import Client
from nvflare.apis.executor import Executor
from nvflare.apis.filter import Filter
from nvflare.apis.fl_constant import FLContextKey, ReservedKey, ReturnCode
from nvflare.apis.fl_context import FLContext
from nvflare.apis.impl.wf_comm_server import WFCommServer
from nvflare.apis.server_engine_spec import ServerEngineSpec
from nvflare.apis.shareable import ReservedHeaderKey, Shareable
from nvflare.apis.workspace import Workspace
from nvflare.app_common.abstract.fl_model import FLModel
from nvflare.app_common.app_constant import AppConstants
from nvflare.app_common.utils.fl_model_utils import FLModelUtils
from nvflare.app_common.workflows.fedavg import FedAvg
from nvflare.fuel.utils import fobs
from nvflare.private.fed.client.client_engine_executor_spec import TaskAssignment
from nvflare.private.fed.client.client_runner import ClientRunner, ClientRunnerConfig, TaskRouter
from nvflare.private.fed.server.server_runner import ServerRunner, ServerRunnerConfig
from nvflare.private.fed.utils.fed_utils import fobs_initialize
from tests.unit_test.apis.impl.controller_test import FakeClock, _TIME_PATCHED_MODULES

SCENARIOS = [
    "normal_staggered",
    "empty_params",
    "absent_metrics",
    "empty_metrics",
    "conversion_failure",
    "partial_param_allocation",
    "metric_preparation_failure",
    "metric_value_failure",
    "lost_ack_live",
    "lost_ack_retired",
    "late_evicted_retry",
    "filter_cancellation",
    "admitted_callback_cancel",
    "before_send_error",
    "dynamic_error",
    "resilient_error",
    "dead_permitted",
    "dead_panic",
    "delivery_retry",
    "protect_allocation_failure",
    "closed_submission",
    "request_retired_while_waiting",
    "missing_live_recovery",
    "late_retained_retry",
]


class TrainingExecutor(Executor):
    def __init__(self, suite, client):
        super().__init__()
        self.suite = suite
        self.client = client

    def execute(self, task_name, shareable, fl_ctx, abort_signal):
        model = FLModelUtils.from_shareable(shareable)
        scenario, c = self.suite.scenario, self.client
        if c == "c1" and scenario in ["dynamic_error", "resilient_error"]:
            raise RuntimeError("ordinary local training execution failure")
        if c == "c2" and scenario == "closed_submission":
            raise RuntimeError("ordinary local training execution failure")
        params = {"w1": float(int(c[1:]) * 2), "w2": float(int(c[1:]) * 4)}
        if c == "c1" and scenario == "empty_params":
            params = {}
        metrics = {"loss": float(int(c[1:]))}
        if c == "c2" and scenario == "absent_metrics":
            metrics = None
        if c == "c2" and scenario == "empty_metrics":
            metrics = {}
        return FLModelUtils.to_shareable(FLModel(params=params, metrics=metrics, current_round=model.current_round))


class OrdinaryFilterFailure(Filter):
    def process(self, shareable, fl_ctx):
        if fl_ctx.get_peer_context().get_identity_name() == "c2":
            raise RuntimeError("ordinary outbound filter runtime failure")
        return shareable


class Suite:
    def __init__(self, scenario, directory, monkeypatch):
        self.scenario = scenario
        self.directory = directory
        self.errors = []
        self.clock = FakeClock()
        for module in _TIME_PATCHED_MODULES:
            monkeypatch.setattr(module, "time", SimpleNamespace(time=self.clock.time, sleep=self.clock.sleep))
        self.clients = [Client("c1", "local-c1"), Client("c2", "local-c2")]
        n = 2 if scenario in ["normal_staggered", "late_evicted_retry", "late_retained_retry"] else 1
        self.config = dict(
            Clients=["c1", "c2"],
            Selected=["c1", "c2"],
            NumRounds=n,
            NumKeys=2,
            HistoryLimit=1 if scenario == "late_evicted_retry" else 10000,
            ErrorMode="resilient" if scenario == "resilient_error" else "dynamic",
            OutboundFilter=scenario == "filter_cancellation",
            LazyOffload=False,
            AllocationFailure=scenario
            in [
                "partial_param_allocation",
                "metric_preparation_failure",
                "metric_value_failure",
                "protect_allocation_failure",
            ],
            ConversionFailure=scenario == "conversion_failure",
            BeforeSendFailure=scenario == "before_send_error",
            AllowEmpty=scenario == "empty_params",
            MetricKinds=["present", "none", "empty"],
            MinSites=1 if scenario == "dead_permitted" else 2,
            RequiredSites=[],
            AllowPartialCompletion=False,
        )
        if self.config["HistoryLimit"] != 10000:
            import nvflare.apis.impl.wf_comm_server as module

            monkeypatch.setattr(module, "_COMPLETED_CLIENT_TASK_CACHE_SIZE", self.config["HistoryLimit"])
        self.job_id = "local-fedavg"
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "startup").mkdir(exist_ok=True)
        (directory / "local").mkdir(exist_ok=True)
        self.workspace = Workspace(str(directory), "server")
        Path(self.workspace.get_run_dir(self.job_id)).mkdir(parents=True, exist_ok=True)
        self.engine = Mock(spec=ServerEngineSpec)
        self.engine.get_clients.return_value = self.clients
        self.engine.get_component.return_value = None
        self.engine.get_workspace.return_value = self.workspace
        self.engine.get_cell = lambda: None
        self.engine.new_context.side_effect = lambda: self.context("server")
        self.engine.fire_event.side_effect = self.fire_event
        self.controller = FedAvg(
            num_clients=2,
            num_rounds=n,
            model={"w1": 0.0, "w2": 0.0},
            persistor_id="",
            save_filename="model.fobs",
            task_check_period=0.001,
            ignore_result_error=True if scenario == "resilient_error" else None,
            enable_tensor_disk_offload=False,
        )
        self.comm = WFCommServer(task_check_period=0.001)
        self.controller.set_communicator(self.comm)
        filters = {"train/out": [OrdinaryFilterFailure()]} if self.config["OutboundFilter"] else {}
        self.server = ServerRunner(
            ServerRunnerConfig(
                60, 0.001, [SimpleNamespace(id="fedavg", controller=self.controller)], filters, {}, [], {}
            ),
            self.job_id,
            self.engine,
        )
        self.server.status = "started"
        self.observer = st.Observer(
            Path(os.environ["TRACE_DIR"]) / f"{scenario}.ndjson",
            self.config,
            self.controller,
            self.comm,
            self.server,
            self.clock,
        )
        st.ACTIVE = self.observer
        self.runners, self.results, self.assignments = {}, {}, {}
        self.losses = (
            1 if scenario in ["lost_ack_live", "lost_ack_retired", "late_evicted_retry", "late_retained_retry"] else 0
        )
        self.send_gate = None
        self.send_entered = threading.Event()
        self.delay_attempt = (
            2
            if scenario in ["late_evicted_retry", "late_retained_retry"]
            else 1 if scenario == "closed_submission" else None
        )
        self.transport_sends = 0
        for client in self.clients:
            engine = Mock()
            engine.fire_event.side_effect = lambda *args: None
            engine.send_aux_request.side_effect = self.aux(client.name)
            engine.send_task_result.side_effect = self.send_adapter(client.name)
            router = TaskRouter()
            router.add_executor(["train"], TrainingExecutor(self, client.name))
            runner = ClientRunner({}, ClientRunnerConfig(router, {}, {}), self.job_id, engine)
            runner.task_check_interval = 0.001
            self.runners[client.name] = runner
        fault_points = {
            "conversion_failure": ("conversion", None),
            "partial_param_allocation": ("helper_value", "w2"),
            "metric_preparation_failure": ("metric_preparation", None),
            "metric_value_failure": ("helper_value", "loss"),
            "before_send_error": ("before_send", None),
            "protect_allocation_failure": ("protect", None),
        }
        if scenario in fault_points:
            point, key = fault_points[scenario]
            self.observer.faults[(point, (1, "c1"), key)] = True
        fobs_initialize()
        self.thread = self.thread_for(self.server._execute_run)
        self.round_gate = self.observer.wait("round_wait")
        self.monitor_gate = self.observer.wait("monitor")

    def context(self, name, peer=None):
        ctx = FLContext()
        ctx.set_prop(ReservedKey.ENGINE, self.engine, private=True, sticky=False)
        ctx.set_prop(ReservedKey.IDENTITY_NAME, name, private=False, sticky=False)
        ctx.set_prop(ReservedKey.RUN_NUM, self.job_id, private=False, sticky=False)
        ctx.set_prop(
            FLContextKey.JOB_META,
            {"name": "trace-job", "min_clients": self.config["MinSites"], "required_clients": []},
            private=True,
            sticky=False,
        )
        if peer is not None:
            ctx.set_peer_context(self.context(peer))
        return ctx

    def fire_event(self, event, ctx):
        self.server.handle_event(event, ctx)

    def thread_for(self, fn):
        def run():
            try:
                fn()
            except BaseException as exc:
                self.errors.append(repr(exc))
                self.observer.errors.append(repr(exc))

        thread = threading.Thread(target=run, daemon=True)
        thread.start()
        return thread

    def aux(self, client):
        def call(targets, topic, request, **kwargs):
            reply = self.server._handle_task_check(topic, request, self.context("server", client))
            return {targets[0]: reply}

        return call

    def send_adapter(self, client):
        def call(result, fl_ctx, timeout):
            self.transport_sends += 1
            if self.delay_attempt == self.transport_sends:
                self.send_entered.set()
                assert self.send_gate.wait(30)
            # FOBS roundtrip exercises decode; no remote streaming guarantee is inferred.
            decoded = fobs.loads(fobs.dumps(result))
            task_id = decoded.get_header(ReservedHeaderKey.TASK_ID)
            self.server.process_submission(
                self.clients[int(client[1:]) - 1], "train", task_id, decoded, self.context("server", client)
            )
            if client == "c1" and self.losses:
                self.losses -= 1
                if self.scenario == "lost_ack_retired":
                    self.comm.cancel_task(self.observer.tasks[1], fl_ctx=self.context("server"))
                    self.monitor()
                return False
            return True

        return call

    def retrieve(self, client, drop=False):
        name, raw, data = self.server.process_task_request(
            self.clients[int(client[1:]) - 1], self.context("server", client)
        )
        if name != "train":
            return None
        assert raw and isinstance(data, Shareable)
        if drop:
            st.hook("TaskDeliveryFailure", {"task_id": raw})
            return None
        decoded = fobs.loads(fobs.dumps(data))
        assignment = TaskAssignment(name, raw, decoded)
        self.assignments[client] = assignment
        ctx = self.context(client, "server")
        result = self.runners[client]._process_task(assignment, ctx)
        self.results[client] = result
        return result

    def submit(self, client):
        return self.runners[client]._send_task_result(
            self.results[client], self.assignments[client].task_id, self.context(client, "server")
        )

    def monitor(self, panic=False):
        self.monitor_gate.set()
        if panic:
            self.comm._task_monitor.join(10)
            assert not self.comm._task_monitor.is_alive()
        else:
            self.monitor_gate = self.observer.wait("monitor")
        assert not self.observer.errors and not self.errors

    def finish_round(self, final=True):
        self.monitor()
        self.round_gate.set()
        if final:
            self.thread.join(10)
            assert not self.thread.is_alive(), self.errors
        else:
            self.round_gate = self.observer.wait("round_wait")
        assert not self.errors and not self.observer.errors

    def stop(self):
        self.observer.stopping = True
        for event in self.observer.releases:
            event.set()
        self.comm._all_done = True
        self.thread.join(3)
        self.comm._task_monitor.join(3)
        st.ACTIVE = None
        self.observer.close()


@pytest.mark.parametrize("scenario", SCENARIOS)
def test_trace(scenario, tmp_path, monkeypatch):
    suite = Suite(scenario, tmp_path / scenario, monkeypatch)
    try:
        if scenario == "normal_staggered":
            for t in [1, 2]:
                suite.retrieve("c1")
                assert suite.submit("c1")
                suite.retrieve("c2")
                assert suite.submit("c2")
                suite.finish_round(final=t == 2)
        elif scenario in ["before_send_error", "protect_allocation_failure"]:
            assert suite.retrieve("c1") is None
            suite.finish_round()
        elif scenario == "filter_cancellation":
            suite.retrieve("c1")
            suite.submit("c1")
            assert suite.retrieve("c2") is None
            suite.finish_round()
        elif scenario == "admitted_callback_cancel":
            suite.retrieve("c1")
            suite.observer.pause_event = "WeightedAddParamStats"
            thread = suite.thread_for(lambda: suite.submit("c1"))
            gate = suite.observer.wait("callback")
            assert suite.comm._controller_lock.locked()
            suite.comm.cancel_task(suite.observer.tasks[1], fl_ctx=suite.context("server"))
            gate.set()
            thread.join(10)
            assert not thread.is_alive()
            suite.finish_round()
        elif scenario == "dynamic_error":
            suite.retrieve("c1")
            suite.submit("c1")
            assert suite.server.abort_signal.triggered
            suite.round_gate.set()
            suite.thread.join(10)
            assert not suite.thread.is_alive()
        elif scenario in ["dead_permitted", "dead_panic"]:
            suite.retrieve("c1")
            suite.submit("c1")
            suite.server.handle_dead_job("c2", suite.context("server"))
            for _ in range(2):
                suite.clock.advance(30)
                st.hook("ClockAdvance", {})
            suite.monitor(panic=scenario == "dead_panic")
            suite.round_gate.set()
            suite.thread.join(10)
            assert not suite.thread.is_alive()
        elif scenario == "lost_ack_retired":
            suite.retrieve("c1")
            assert suite.submit("c1") is False
            suite.round_gate.set()
            suite.thread.join(10)
            assert not suite.thread.is_alive()
        elif scenario == "closed_submission":
            suite.retrieve("c1")
            suite.send_gate = threading.Event()
            thread = suite.thread_for(lambda: suite.submit("c1"))
            assert suite.send_entered.wait(10)
            suite.retrieve("c2")
            suite.submit("c2")
            assert suite.server.abort_signal.triggered
            suite.round_gate.set()
            suite.thread.join(10)
            assert not suite.thread.is_alive()
            suite.send_gate.set()
            thread.join(10)
            assert not thread.is_alive()
        elif scenario == "request_retired_while_waiting":
            suite.retrieve("c1")
            suite.submit("c1")
            suite.observer.pause_event = "ServerRunnerTaskRequestActive"
            thread = suite.thread_for(lambda: suite.retrieve("c2"))
            gate = suite.observer.wait("callback")
            suite.comm.cancel_task(suite.observer.tasks[1], fl_ctx=suite.context("server"))
            suite.monitor()
            gate.set()
            thread.join(10)
            assert not thread.is_alive()
            suite.finish_round()
        elif scenario == "missing_live_recovery":
            suite.retrieve("c1")
            suite.submit("c1")
            suite.server.handle_dead_job("c2", suite.context("server"))
            suite.clock.advance(30)
            st.hook("ClockAdvance", {})
            suite.monitor()
            assert suite.comm.get_num_standing_tasks() == 1
            suite.round_gate.set()
            suite.round_gate = suite.observer.wait("poll_sleep")
            suite.server._handle_job_heartbeat("", Shareable(), suite.context("server", "c2"))
            suite.retrieve("c2")
            suite.submit("c2")
            suite.finish_round()
        elif scenario in ["late_evicted_retry", "late_retained_retry"]:
            suite.retrieve("c1")
            suite.send_gate = threading.Event()
            thread = suite.thread_for(lambda: suite.submit("c1"))
            assert suite.send_entered.wait(10)
            suite.retrieve("c2")
            suite.submit("c2")
            suite.finish_round(final=False)
            suite.send_gate.set()
            thread.join(10)
            assert not thread.is_alive()
            for c in ["c1", "c2"]:
                suite.retrieve(c)
                suite.submit(c)
            suite.finish_round()
        else:
            if scenario == "delivery_retry":
                suite.retrieve("c1", drop=True)
            for c in ["c1", "c2"]:
                suite.retrieve(c)
                suite.submit(c)
            suite.finish_round()
        assert not suite.errors and not suite.observer.errors
        assert suite.observer.s["wf"]["pc"] == "finalized"
        receipt = dict(
            scenario=scenario,
            events=suite.observer.seq,
            eventTypes=suite.observer.event_counts,
            config=suite.config,
            outcome=suite.observer.s["wf"]["outcome"],
            abort=suite.observer.s["wf"]["abort"],
            finalState=suite.observer.s,
            identityMap=suite.observer.ids,
            inputHashes=suite.observer.model_hashes,
            runtimeErrors=suite.errors,
            observerErrors=suite.observer.errors,
        )
        report_dir = Path(os.environ["HARNESS_REPORT_DIR"])
        report_dir.mkdir(exist_ok=True, parents=True)
        (report_dir / f"{scenario}.json").write_text(json.dumps(receipt, indent=2) + "\n")
    finally:
        suite.stop()
