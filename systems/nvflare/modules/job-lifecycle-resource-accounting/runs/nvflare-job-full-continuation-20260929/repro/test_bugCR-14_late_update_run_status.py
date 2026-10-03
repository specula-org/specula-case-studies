#!/usr/bin/env python3
"""CR-14 reproduction: late UPDATE_RUN_STATUS(execution_error=True) is ignored.

This is a deterministic confirmation harness.  It uses the real
ServerEngine.wait_for_complete(), FederatedServer._listen_command() handling
for UPDATE_RUN_STATUS, and JobRunner._job_complete_process() publication path.
Only the process handle, job manager, and one-shot cell delivery timing are
faked so the on-time and delayed controls can be compared in one short run.
"""

from __future__ import annotations

import contextlib
import os
import sys
import tempfile
import threading
from types import SimpleNamespace


SOURCE = (
    "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/"
    "gpt-continuation/nvflare-job/.specula-output/confirmation/CR-14/worktree"
)
sys.path.insert(0, SOURCE)

from nvflare.apis.fl_constant import MachineStatus, RunProcessKey, ServerCommandNames
from nvflare.apis.job_def import RunStatus
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey, ReturnCode as F3ReturnCode
from nvflare.fuel.f3.message import Message
from nvflare.private.defs import CellMessageHeaderKeys
from nvflare.private.fed.server import job_runner as job_runner_mod
from nvflare.private.fed.server.fed_server import FederatedServer
from nvflare.private.fed.server.job_runner import JobRunner
from nvflare.private.fed.server.server_engine import ServerEngine


class FakeLogger:
    def __getattr__(self, name):
        def _log(*args, **kwargs):
            return None

        return _log


class FakeProcess:
    def __init__(self, return_code=0):
        self.return_code = return_code
        self.wait_called = False

    def wait(self):
        self.wait_called = True

    def poll(self):
        return self.return_code

    def terminate(self):
        pass


class FakeCompletionContext:
    def __init__(self):
        self.props = {}

    def set_prop(self, key, value, *args, **kwargs):
        self.props[key] = value


class FakeJobManager:
    def __init__(self):
        self.statuses = []

    def set_status(self, job_id, status, fl_ctx):
        self.statuses.append((job_id, status))


class FakeEngine:
    def __init__(self, run_processes, exception_run_processes):
        self.run_processes = run_processes
        self.exception_run_processes = exception_run_processes
        self.client_manager = SimpleNamespace(clients={})
        self.lock = threading.Lock()
        self.job_manager = FakeJobManager()
        self.removed_exception_processes = []

    def get_component(self, component_id):
        return self.job_manager

    def new_context(self):
        return contextlib.nullcontext(FakeCompletionContext())

    def remove_exception_process(self, job_id):
        self.removed_exception_processes.append(job_id)
        self.exception_run_processes.pop(job_id, None)


def make_wait_engine(job_id):
    run_process_info = {
        RunProcessKey.JOB_ID: job_id,
        RunProcessKey.PARTICIPANTS: {},
    }
    engine = ServerEngine.__new__(ServerEngine)
    engine.lock = threading.Lock()
    engine.run_processes = {job_id: run_process_info}
    engine.exception_run_processes = {}
    engine.engine_info = SimpleNamespace(status=MachineStatus.STARTED)
    engine.logger = FakeLogger()
    return engine, run_process_info


def send_update_run_status(engine, job_id, execution_error=True):
    parent_server = SimpleNamespace(engine=engine, lock=threading.Lock(), logger=FakeLogger())
    msg = Message(
        headers={
            CellMessageHeaderKeys.JOB_ID: job_id,
            MessageHeaderKey.TOPIC: ServerCommandNames.UPDATE_RUN_STATUS,
        },
        payload={"execution_error": execution_error},
    )
    reply = FederatedServer._listen_command(parent_server, msg)
    return reply.get_header(MessageHeaderKey.RETURN_CODE)


def publish_finished_status(job_id, exception_run_processes):
    runner = JobRunner(workspace_root=tempfile.mkdtemp(prefix="cr14-runner-"))
    runner.ask_to_stop = False
    runner.running_jobs = {job_id: SimpleNamespace(job_id=job_id, run_aborted=False)}
    runner._pending_client_outcomes = {}
    runner._client_outcome_deadlines = {}
    runner._save_workspace = lambda *args, **kwargs: None
    runner._fire_job_lifecycle_event = lambda *args, **kwargs: None
    runner.abort_client_run = lambda *args, **kwargs: None
    runner.log_info = lambda *args, **kwargs: None
    runner.log_debug = lambda *args, **kwargs: None
    runner.log_exception = lambda *args, **kwargs: None
    runner.logger = FakeLogger()

    engine = FakeEngine(run_processes={}, exception_run_processes=exception_run_processes)
    original_sleep = job_runner_mod.time.sleep

    def stop_after_one_pass(_seconds):
        runner.ask_to_stop = True

    job_runner_mod.time.sleep = stop_after_one_pass
    try:
        runner._job_complete_process(engine)
    finally:
        job_runner_mod.time.sleep = original_sleep

    assert engine.job_manager.statuses, "completion loop did not publish any status"
    return engine.job_manager.statuses[-1][1]


def run_case(case_name, delayed):
    job_id = f"job-{case_name}"
    wait_engine, run_process_info = make_wait_engine(job_id)
    process = FakeProcess(return_code=0)

    with tempfile.TemporaryDirectory(prefix="cr14-workspace-") as workspace:
        os.makedirs(os.path.join(workspace, job_id), exist_ok=True)
        if not delayed:
            reply = send_update_run_status(wait_engine, job_id, execution_error=True)
            assert reply == F3ReturnCode.OK
            wait_engine.wait_for_complete(workspace, job_id, process)
            late_reply = None
        else:
            wait_engine.wait_for_complete(workspace, job_id, process)
            late_reply = send_update_run_status(wait_engine, job_id, execution_error=True)
            assert late_reply == F3ReturnCode.OK

    published = publish_finished_status(job_id, dict(wait_engine.exception_run_processes))
    return {
        "case": case_name,
        "delayed": delayed,
        "process_wait_called": process.wait_called,
        "run_process_present_after_wait": job_id in wait_engine.run_processes,
        "exception_entry_after_wait": job_id in wait_engine.exception_run_processes,
        "exe_error_recorded": bool(
            wait_engine.exception_run_processes.get(job_id, {}).get(RunProcessKey.PROCESS_EXE_ERROR, False)
        ),
        "process_finished_recorded": bool(run_process_info.get(RunProcessKey.PROCESS_FINISHED, False)),
        "late_reply": late_reply,
        "published_status": published.value,
    }


def main():
    print("CR-14 late UPDATE_RUN_STATUS reproduction")
    print(f"nvflare_source={SOURCE}")
    print(
        "reachable_precondition=JobRunner._start_run -> "
        "ServerEngine.start_app_on_server/_start_runner_process inserts run_processes[job] "
        "and starts wait_for_complete; ServerAppRunner.finally sends UPDATE_RUN_STATUS."
    )

    on_time = run_case("on-time-control", delayed=False)
    delayed = run_case("delayed-status", delayed=True)

    for result in (on_time, delayed):
        print(
            "RESULT "
            f"case={result['case']} delayed={result['delayed']} "
            f"wait_called={result['process_wait_called']} "
            f"run_process_present_after_wait={result['run_process_present_after_wait']} "
            f"exception_entry_after_wait={result['exception_entry_after_wait']} "
            f"exe_error_recorded={result['exe_error_recorded']} "
            f"process_finished_recorded={result['process_finished_recorded']} "
            f"late_reply={result['late_reply']} "
            f"published_status={result['published_status']}"
        )

    assert on_time["published_status"] == RunStatus.FINISHED_EXECUTION_EXCEPTION.value
    assert on_time["exe_error_recorded"] is True
    assert delayed["late_reply"] == F3ReturnCode.OK
    assert delayed["exception_entry_after_wait"] is False
    assert delayed["exe_error_recorded"] is False
    assert delayed["process_finished_recorded"] is False
    assert delayed["published_status"] == RunStatus.FINISHED_COMPLETED.value

    print(
        "BUG_TRIGGERED late execution_error=True arrived after run_processes pop; "
        "handler returned OK but recorded no exception entry; completion published FINISHED:COMPLETED"
    )


if __name__ == "__main__":
    main()
