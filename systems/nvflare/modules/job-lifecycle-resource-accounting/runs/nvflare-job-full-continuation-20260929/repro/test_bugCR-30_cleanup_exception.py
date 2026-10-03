#!/usr/bin/env python3
"""CR-30 confirmation probe.

This exercises the real JobRunner abort cleanup path and separates reachable
default behavior from a deliberately injected non-RuntimeError producer.
"""

from types import SimpleNamespace

from nvflare.apis.client import Client
from nvflare.apis.event_type import EventType
from nvflare.apis.fl_component import FLComponent
from nvflare.apis.fl_constant import FLContextKey, RunProcessKey
from nvflare.apis.fl_context import FLContextManager
from nvflare.apis.utils.event import fire_event_to_components
from nvflare.fuel.common.exit_codes import ProcessExitCode
from nvflare.private.fed.server.job_runner import JobRunner


class FakeClientManager:
    def __init__(self, clients):
        self.clients = {c.token: c for c in clients}
        self.name_to_clients = {c.name: c for c in clients}

    def get_all_clients_from_inputs(self, inputs):
        clients = []
        invalid = []
        for item in inputs:
            client = self.clients.get(item) or self.name_to_clients.get(item)
            if client:
                clients.append(client)
            else:
                invalid.append(item)
        return clients, invalid


class FakeSAI:
    def __init__(self, engine):
        self._ctx_mgr = FLContextManager(engine=engine, identity_name="server", job_id="")
        self.fired_events = []

    def new_context(self):
        return self._ctx_mgr.new_context()

    def fire_event(self, event_type, fl_ctx):
        self.fired_events.append(event_type)


class FakeAdminServer:
    timeout = 0.01

    def __init__(self, engine, mode):
        self.sai = FakeSAI(engine)
        self.mode = mode
        self.calls = []

    def send_requests(self, requests, fl_ctx, timeout_secs=2.0, optional=False):
        self.calls.append(
            {
                "tokens": sorted(requests.keys()),
                "timeout_secs": timeout_secs,
                "optional": optional,
            }
        )
        if self.mode == "raise-value-error":
            raise ValueError("synthetic non-RuntimeError fanout failure")
        return []


class FakeEngine:
    def __init__(self, clients, admin_mode="return-empty"):
        self.client_manager = FakeClientManager(clients)
        self.run_processes = {}
        self.exception_run_processes = {}
        self.server = SimpleNamespace(admin_server=FakeAdminServer(self, admin_mode))

    def validate_targets(self, client_sites):
        return self.client_manager.get_all_clients_from_inputs(client_sites)

    def new_context(self):
        return FLContextManager(engine=self, identity_name="server", job_id="").new_context()


class RaisingComponent(FLComponent):
    def handle_event(self, event_type, fl_ctx):
        if event_type == EventType.BEFORE_SEND_ADMIN_COMMAND:
            raise ValueError("component event failure")


def make_runner():
    runner = JobRunner(workspace_root="/tmp")
    logs = []
    runner.log_debug = lambda fl_ctx, msg, **kwargs: logs.append("DEBUG: " + msg)
    runner.log_info = lambda fl_ctx, msg, **kwargs: logs.append("INFO: " + msg)
    runner.log_error = lambda fl_ctx, msg, **kwargs: logs.append("ERROR: " + msg)
    return runner, logs


def main():
    print("CR-30 cleanup fanout confirmation probe")

    runner, logs = make_runner()

    level0_engine = FakeEngine(clients=[], admin_mode="return-empty")
    with level0_engine.new_context() as fl_ctx:
        runner.abort_client_run("job-empty", [], fl_ctx)
    assert level0_engine.server.admin_server.calls == [
        {"tokens": [], "timeout_secs": 2.0, "optional": True}
    ]
    print("Level 0: empty/default optional abort fanout returned normally; no exception escaped.")

    level1_engine = FakeEngine(clients=[], admin_mode="return-empty")
    with level1_engine.new_context() as fl_ctx:
        runner.abort_client_run("job-disconnected", ["site-1"], fl_ctx)
    assert level1_engine.server.admin_server.calls == []
    assert any("unknown clients" in entry for entry in logs)
    print("Level 1: disconnected/invalid target raised RuntimeError inside _send_to_clients and was caught.")

    event_engine = FakeEngine(clients=[], admin_mode="return-empty")
    with event_engine.new_context() as fl_ctx:
        fire_event_to_components(EventType.BEFORE_SEND_ADMIN_COMMAND, [RaisingComponent()], fl_ctx)
        exceptions = fl_ctx.get_prop(FLContextKey.EXCEPTIONS)
    assert exceptions
    assert any(isinstance(error, ValueError) for error in exceptions.values())
    print("Event path: a non-RuntimeError component handler failure was recorded in FLContext, not propagated.")

    client = Client("site-1", "token-1")
    injected_engine = FakeEngine(clients=[client], admin_mode="raise-value-error")
    injected_engine.exception_run_processes = {
        "job-injected": {
            RunProcessKey.PARTICIPANTS: {"token-1": client},
            RunProcessKey.PROCESS_RETURN_CODE: ProcessExitCode.EXCEPTION,
        }
    }
    job = SimpleNamespace(job_id="job-injected")
    with injected_engine.new_context() as fl_ctx:
        try:
            runner._get_finished_job_status(injected_engine, job, fl_ctx)
        except ValueError as exc:
            print(f"Level 2: injected admin_server.send_requests ValueError escaped: {type(exc).__name__}: {exc}")
        else:
            raise AssertionError("injected non-RuntimeError did not escape")

    print("Level 3: no source patch used; forcing a default producer to emit this exception would create the symptom.")
    print("RESULT: FALSE_POSITIVE_UNREACHABLE_NON_RUNTIME_FANOUT")


if __name__ == "__main__":
    main()
