#!/usr/bin/env python3
"""Reproduce CR-6: live dictionary iteration in NVFlare lifecycle paths.

This is a deterministic harness around the pinned product code.  It keeps the
product methods at the cited sites intact and fakes only network/process edges
or timing so the concurrent dictionary mutation lands in the vulnerable window.
"""

import json
import os
import sys
import threading
import time
import traceback
from types import SimpleNamespace


SOURCE = "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/nvflare-job/.specula-output/confirmation/CR-6/worktree"
sys.path.insert(0, SOURCE)

import nvflare  # noqa: E402

assert os.path.realpath(nvflare.__file__).startswith(SOURCE), nvflare.__file__

from nvflare.apis.client import Client  # noqa: E402
from nvflare.apis.fl_constant import FLContextKey, RunProcessKey  # noqa: E402
from nvflare.private.fed.server.client_manager import ClientManager  # noqa: E402
from nvflare.private.fed.server.fed_server import FederatedServer  # noqa: E402
from nvflare.private.fed.server.job_runner import JobRunner  # noqa: E402
from nvflare.private.fed.server.server_engine import ServerEngine  # noqa: E402
from nvflare.private.fed.server.training_cmds import TrainingCommandModule  # noqa: E402


class NoopLogger:
    def debug(self, *args, **kwargs):
        pass

    def info(self, *args, **kwargs):
        pass

    def warning(self, *args, **kwargs):
        pass

    def error(self, *args, **kwargs):
        pass


class FakeFLContext:
    def __init__(self, engine):
        self._engine = engine
        self.props = {}

    def get_engine(self):
        return self._engine

    def set_prop(self, key, value, *args, **kwargs):
        self.props[key] = value


class FakeConn:
    def __init__(self, engine):
        self.app_ctx = engine
        self.out = []
        self.meta = []

    def append_error(self, msg, meta=None):
        self.out.append(("error", msg, meta))

    def append_success(self, msg, meta=None):
        self.out.append(("success", msg, meta))

    def append_string(self, msg, meta=None):
        self.out.append(("string", msg, meta))

    def append_shutdown(self, msg, meta=None):
        self.out.append(("shutdown", msg, meta))

    def update_meta(self, meta):
        self.meta.append(meta)

    def get_prop(self, name, default=None):
        return default


class MutateDuringItems(dict):
    """A dict whose first live iteration triggers a real remove_client call."""

    def __init__(self, *args, manager, victim_token, **kwargs):
        super().__init__(*args, **kwargs)
        self.manager = manager
        self.victim_token = victim_token
        self.fired = False

    def items(self):
        iterator = super().items()
        for item in iterator:
            if not self.fired:
                self.fired = True
                self.manager.remove_client(self.victim_token)
            yield item


class StaleAfterScan(dict):
    """A dict scan that makes the collected token stale before logout."""

    def __init__(self, *args, manager, victim_token, **kwargs):
        super().__init__(*args, **kwargs)
        self.manager = manager
        self.victim_token = victim_token
        self.fired = False

    def items(self):
        for item in list(super().items()):
            yield item
        if not self.fired:
            self.fired = True
            self.manager.remove_client(self.victim_token)


class MutateRunningJobs(dict):
    """A running_jobs map that loses another job while shutdown iterates."""

    def __init__(self, *args, victim_job_id, **kwargs):
        super().__init__(*args, **kwargs)
        self.victim_job_id = victim_job_id
        self.fired = False

    def items(self):
        iterator = super().items()
        for item in iterator:
            if not self.fired:
                self.fired = True
                self.pop(self.victim_job_id, None)
            yield item


def make_client(name, token, stale=False):
    c = Client(name, token)
    if stale:
        c.last_connect_time = 0.0
    return c


def make_server():
    server = FederatedServer.__new__(FederatedServer)
    server.logger = NoopLogger()
    server.client_manager = ClientManager(project_name="project", min_num_clients=1, max_num_clients=1000)
    server.heart_beat_timeout = 1.0
    server.tokens = {}
    server.admin_server = None
    server.shutdown = False
    return server


def cleanup_thread_result(server, timeout=2.0):
    result = {}

    def target():
        try:
            server.client_cleanup()
            result["returned"] = True
        except BaseException as e:
            result["exception"] = f"{type(e).__name__}: {e}"
            result["traceback_last"] = traceback.format_exc().strip().splitlines()[-1]

    t = threading.Thread(target=target, name="FederatedServer.client_cleanup")
    t.start()
    t.join(timeout)
    if t.is_alive():
        server.shutdown = True
        t.join(1.0)
        result["still_alive"] = t.is_alive()
    else:
        result["thread_alive_after_exception"] = False
    return result


def scenario_client_cleanup_live_client_map():
    server = make_server()
    server.heart_beat_timeout = 10**9
    a = make_client("site-a", "tok-a")
    b = make_client("site-b", "tok-b")
    server.client_manager.clients = MutateDuringItems(
        {a.token: a, b.token: b}, manager=server.client_manager, victim_token=b.token
    )
    server.client_manager.name_to_clients = {a.name: a, b.name: b}
    result = cleanup_thread_result(server)
    return result


def scenario_stale_logout_token():
    server = make_server()
    c = make_client("site-stale", "tok-stale", stale=True)
    server.client_manager.clients = StaleAfterScan(
        {c.token: c}, manager=server.client_manager, victim_token=c.token
    )
    server.client_manager.name_to_clients = {c.name: c}
    server.tokens = {c.token: object()}
    server.engine = SimpleNamespace(
        job_runner=SimpleNamespace(get_client_outcome_jobs=lambda _client_name: []),
        run_processes={},
        exception_run_processes={},
    )
    result = cleanup_thread_result(server)
    return result


def scenario_notify_dead_client_live_run_processes():
    server = make_server()
    c = make_client("site-dead", "tok-dead")
    server.client_manager.clients = {c.token: c}
    server.client_manager.name_to_clients = {c.name: c}
    server.tokens = {c.token: object()}
    notify_entered = threading.Event()
    may_return = threading.Event()

    class Engine:
        def __init__(self):
            self.job_runner = SimpleNamespace(get_client_outcome_jobs=lambda _client_name: [])
            self.run_processes = {
                "job-1": {RunProcessKey.PARTICIPANTS: {c.token: c}},
                "job-2": {RunProcessKey.PARTICIPANTS: {c.token: c}},
            }
            self.exception_run_processes = {}

        def notify_dead_job(self, job_id, client_name, reason):
            notify_entered.set()
            may_return.wait(1.0)

    engine = Engine()
    server.engine = engine

    def concurrent_waiter_cleanup():
        notify_entered.wait(1.0)
        engine.run_processes.pop("job-2", None)
        may_return.set()

    mutator = threading.Thread(target=concurrent_waiter_cleanup, name="wait_for_complete-pop")
    mutator.start()
    try:
        server.logout_client(c.token)
        outcome = {"exception": None}
    except BaseException as e:
        outcome = {"exception": f"{type(e).__name__}: {e}"}
    mutator.join(1.0)
    outcome["remaining_run_processes"] = sorted(engine.run_processes)
    return outcome


def scenario_stop_all_runs_live_run_processes():
    runner = JobRunner(workspace_root="/tmp")
    runner.log_info = lambda *args, **kwargs: None
    runner.log_error = lambda *args, **kwargs: None
    runner.log_debug = lambda *args, **kwargs: None
    runner.abort_client_run = lambda *args, **kwargs: None
    jobs = {
        "job-1": SimpleNamespace(job_id="job-1", run_aborted=False),
        "job-2": SimpleNamespace(job_id="job-2", run_aborted=False),
    }
    runner.running_jobs = dict(jobs)

    class Engine:
        def __init__(self):
            self.client_manager = SimpleNamespace(clients={})
            self.server = SimpleNamespace(admin_server=None)
            self.run_processes = {
                "job-1": {RunProcessKey.PARTICIPANTS: {}},
                "job-2": {RunProcessKey.PARTICIPANTS: {}},
            }

        def abort_app_on_server(self, job_id):
            self.run_processes.pop(job_id, None)
            return ""

    engine = Engine()
    try:
        runner.stop_all_runs(FakeFLContext(engine))
        outcome = {"exception": None}
    except BaseException as e:
        outcome = {"exception": f"{type(e).__name__}: {e}"}
    outcome["ask_to_stop"] = runner.ask_to_stop
    outcome["run_aborted"] = {jid: job.run_aborted for jid, job in jobs.items()}
    outcome["remaining_run_processes"] = sorted(engine.run_processes)
    return outcome


def scenario_training_shutdown_running_jobs_iteration():
    engine = ServerEngine.__new__(ServerEngine)
    engine.get_clients = lambda: []
    engine.has_relays = lambda: False
    engine.job_runner = SimpleNamespace()
    jobs = {
        "job-1": SimpleNamespace(job_id="job-1", run_aborted=True),
        "job-2": SimpleNamespace(job_id="job-2", run_aborted=True),
    }
    engine.job_runner.running_jobs = MutateRunningJobs(jobs, victim_job_id="job-2")
    module = TrainingCommandModule()
    module._shutdown_app_on_server = lambda _conn: ""
    module._shutdown_app_on_clients = lambda _conn: True
    try:
        module.shutdown(FakeConn(engine), ["shutdown", "server"])
        outcome = {"exception": None}
    except BaseException as e:
        outcome = {"exception": f"{type(e).__name__}: {e}"}
    outcome["remaining_running_jobs"] = sorted(engine.job_runner.running_jobs)
    return outcome


def main():
    cases = {
        "cleanup_live_client_map": scenario_client_cleanup_live_client_map(),
        "cleanup_stale_logout_token": scenario_stale_logout_token(),
        "notify_dead_client_live_run_processes": scenario_notify_dead_client_live_run_processes(),
        "stop_all_runs_live_run_processes": scenario_stop_all_runs_live_run_processes(),
        "training_shutdown_running_jobs_iteration": scenario_training_shutdown_running_jobs_iteration(),
    }

    expected_fragments = {
        "cleanup_live_client_map": "RuntimeError: dictionary changed size during iteration",
        "cleanup_stale_logout_token": "AttributeError: 'NoneType' object has no attribute 'name'",
        "notify_dead_client_live_run_processes": "RuntimeError: dictionary changed size during iteration",
        "stop_all_runs_live_run_processes": "RuntimeError: dictionary changed size during iteration",
        "training_shutdown_running_jobs_iteration": "RuntimeError: dictionary changed size during iteration",
    }
    failures = {}
    for name, fragment in expected_fragments.items():
        got = cases[name].get("exception")
        if fragment not in str(got):
            failures[name] = {"expected": fragment, "got": got, "case": cases[name]}

    if cases["stop_all_runs_live_run_processes"].get("ask_to_stop") is not False:
        failures["stop_all_runs_ask_to_stop"] = cases["stop_all_runs_live_run_processes"]
    if cases["stop_all_runs_live_run_processes"]["run_aborted"].get("job-2") is not False:
        failures["stop_all_runs_second_job_not_aborted"] = cases["stop_all_runs_live_run_processes"]

    print("SOURCE", SOURCE)
    print("NVFLARE", os.path.realpath(nvflare.__file__))
    print(json.dumps(cases, indent=2, sort_keys=True))
    if failures:
        print("BUG NOT REPRODUCED")
        print(json.dumps(failures, indent=2, sort_keys=True))
        return 1
    print("BUG REPRODUCED: live dictionary iteration raises in lifecycle services")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
