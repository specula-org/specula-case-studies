#!/usr/bin/env python3
"""Reproduce CR-33 against real NVFlare server lifecycle handlers.

The harness keeps only network/process/storage edges minimal.  Product code
exercised:
  * FederatedServer._listen_command(UPDATE_RUN_STATUS)
  * ServerEngine.wait_for_complete
  * FederatedServer.process_job_failure -> JobRunner.fail_run
  * JobRunner._job_complete_process

Level 0 runs the same message sequence with no timing control.  Level 1 pauses
the UPDATE_RUN_STATUS handler after it has retained run_process_info from
engine.run_processes and before it assigns exception_run_processes[job].
"""

from __future__ import annotations

import inspect
import json
import logging
import os
import sys
import tempfile
import threading
from contextlib import nullcontext
from dataclasses import dataclass
from types import SimpleNamespace
from unittest.mock import MagicMock, patch


SOURCE = (
    "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/"
    "gpt-continuation/nvflare-job/.specula-output/confirmation/CR-33/worktree"
)
sys.path.insert(0, SOURCE)

import nvflare  # noqa: E402
from nvflare.apis.client import Client  # noqa: E402
from nvflare.apis.fl_constant import FLContextKey, RunProcessKey, ServerCommandNames, SystemComponents  # noqa: E402
from nvflare.apis.job_def import RunStatus  # noqa: E402
from nvflare.fuel.common.exit_codes import ProcessExitCode  # noqa: E402
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey  # noqa: E402
from nvflare.private.defs import CellMessageHeaderKeys, JobFailureMsgKey, new_cell_message  # noqa: E402
from nvflare.private.fed.server.fed_server import FederatedServer  # noqa: E402
from nvflare.private.fed.server.job_runner import JobRunner  # noqa: E402
from nvflare.private.fed.server.server_engine import ServerEngine  # noqa: E402
from nvflare.private.fed.server.server_engine_internal_spec import EngineInfo  # noqa: E402


assert os.path.realpath(nvflare.__file__).startswith(os.path.realpath(SOURCE)), nvflare.__file__


JOB_ID = "job-cr33"
TOKEN = "token-site-1"
CLIENT_NAME = "site-1"


class FakeProcess:
    def wait(self):
        return None

    def poll(self):
        return 0


class MiniContext:
    def __init__(self, engine):
        self._engine = engine
        self.props = {}

    def get_engine(self):
        return self._engine

    def set_prop(self, key, value, *args, **kwargs):
        self.props[key] = value

    def get_prop(self, key, default=None):
        return self.props.get(key, default)


class MiniClientManager:
    def __init__(self):
        c = Client(CLIENT_NAME, TOKEN)
        c.set_fqcn(CLIENT_NAME)
        self.clients = {TOKEN: c}

    def is_from_authorized_client(self, token):
        return token in self.clients


@dataclass
class CaseResult:
    label: str
    retained_update_paused: bool
    expected_status_from_fail_run: str
    exception_entry_after_fail_run: dict
    exception_entry_after_update: dict
    final_status_published: str
    replacement_happened: bool
    bug_triggered: bool


def update_pause_line() -> int:
    lines, start = inspect.getsourcelines(FederatedServer._listen_command)
    for offset, line in enumerate(lines):
        if "if run_process_info is not None:" in line:
            return start + offset
    raise RuntimeError("could not locate UPDATE_RUN_STATUS pause line")


def make_env(tmpdir):
    engine = ServerEngine.__new__(ServerEngine)
    engine.lock = threading.Lock()
    engine.run_processes = {
        JOB_ID: {
            RunProcessKey.PARTICIPANTS: {},
            RunProcessKey.JOB_ID: JOB_ID,
        }
    }
    engine.exception_run_processes = {}
    engine.engine_info = EngineInfo()
    engine.logger = logging.getLogger("cr33.engine")
    engine.client_manager = MiniClientManager()

    runner = JobRunner(workspace_root=tmpdir)
    runner.log_info = lambda *args, **kwargs: None
    runner.log_debug = lambda *args, **kwargs: None
    runner.log_error = lambda *args, **kwargs: None
    runner.log_exception = lambda *args, **kwargs: None
    runner._save_workspace = lambda *args, **kwargs: None
    runner._fire_job_lifecycle_event = lambda *args, **kwargs: None
    runner.abort_client_run = lambda *args, **kwargs: None
    runner.running_jobs = {JOB_ID: SimpleNamespace(job_id=JOB_ID, run_aborted=False)}
    runner._pending_client_outcomes = {JOB_ID: {CLIENT_NAME}}
    runner._client_outcome_deadlines = {}
    runner._finished_job_states = {}
    runner.ask_to_stop = False

    engine.job_runner = runner
    job_manager = MagicMock()
    published = []

    def set_status(job_id, status, fl_ctx):
        published.append(status.value if hasattr(status, "value") else str(status))

    job_manager.set_status.side_effect = set_status
    engine.get_component = lambda cid: job_manager if cid == SystemComponents.JOB_MANAGER else None
    engine.new_context = lambda: nullcontext(MiniContext(engine))
    engine.abort_app_on_server = lambda job_id: ""

    server = FederatedServer.__new__(FederatedServer)
    server.lock = threading.Lock()
    server.engine = engine
    server.client_manager = engine.client_manager
    server.logger = logging.getLogger("cr33.server")

    return server, engine, runner, published


def update_message():
    msg = new_cell_message(
        {
            CellMessageHeaderKeys.JOB_ID: JOB_ID,
            MessageHeaderKey.TOPIC: ServerCommandNames.UPDATE_RUN_STATUS,
        },
        {"execution_error": True},
    )
    return msg


def failure_report_message():
    return new_cell_message(
        {
            CellMessageHeaderKeys.TOKEN: TOKEN,
            MessageHeaderKey.ORIGIN: CLIENT_NAME,
        },
        {
            JobFailureMsgKey.JOB_ID: JOB_ID,
            JobFailureMsgKey.CODE: ProcessExitCode.INFRASTRUCTURE_ERROR,
            JobFailureMsgKey.REASON: "client infrastructure failure",
        },
    )


def run_completion_once(runner, engine):
    def stop_after_sleep(_seconds):
        runner.ask_to_stop = True

    with patch("nvflare.private.fed.server.job_runner.time.sleep", side_effect=stop_after_sleep):
        runner._job_complete_process(engine)


def run_case(label: str, pause_update: bool) -> CaseResult:
    with tempfile.TemporaryDirectory(prefix="cr33-") as tmpdir:
        server, engine, runner, published = make_env(tmpdir)
        old_live_info = engine.run_processes[JOB_ID]
        pause_line = update_pause_line()
        paused = threading.Event()
        release = threading.Event()

        def tracer(frame, event, arg):
            if (
                pause_update
                and event == "line"
                and frame.f_code is FederatedServer._listen_command.__code__
                and frame.f_lineno == pause_line
            ):
                paused.set()
                release.wait(timeout=10.0)
            return tracer

        def run_update():
            if pause_update:
                sys.settrace(tracer)
            try:
                server._listen_command(update_message())
            finally:
                sys.settrace(None)

        update_thread = threading.Thread(target=run_update, name=f"{label}-update")
        update_thread.start()

        if pause_update:
            if not paused.wait(timeout=5.0):
                raise RuntimeError("UPDATE_RUN_STATUS handler did not reach pause point")
        else:
            update_thread.join(timeout=5.0)
            if update_thread.is_alive():
                raise RuntimeError("Level 0 update thread did not finish")

        engine.wait_for_complete(tmpdir, JOB_ID, FakeProcess())
        assert JOB_ID not in engine.run_processes

        server.process_job_failure(failure_report_message())
        after_fail = engine.exception_run_processes[JOB_ID]
        expected = runner._classify_finished_job_status(after_fail).value

        if pause_update:
            release.set()
            update_thread.join(timeout=5.0)
            if update_thread.is_alive():
                raise RuntimeError("paused UPDATE_RUN_STATUS thread did not finish")

        after_update = engine.exception_run_processes[JOB_ID]
        run_completion_once(runner, engine)
        final_status = published[-1] if published else "<not-published>"

        replacement = after_update is old_live_info and after_fail is not old_live_info
        bug = expected == RunStatus.FINISHED_ABNORMAL.value and final_status == RunStatus.FINISHED_EXECUTION_EXCEPTION.value

        return CaseResult(
            label=label,
            retained_update_paused=pause_update and paused.is_set(),
            expected_status_from_fail_run=expected,
            exception_entry_after_fail_run={
                "object": "new_failure_record" if after_fail is not old_live_info else "old_live_run_process",
                "process_return_code": after_fail.get(RunProcessKey.PROCESS_RETURN_CODE),
                "process_finished": after_fail.get(RunProcessKey.PROCESS_FINISHED),
                "process_exe_error": after_fail.get(RunProcessKey.PROCESS_EXE_ERROR),
            },
            exception_entry_after_update={
                "object": "old_live_run_process" if after_update is old_live_info else "new_failure_record",
                "process_return_code": after_update.get(RunProcessKey.PROCESS_RETURN_CODE),
                "process_finished": after_update.get(RunProcessKey.PROCESS_FINISHED),
                "process_exe_error": after_update.get(RunProcessKey.PROCESS_EXE_ERROR),
            },
            final_status_published=final_status,
            replacement_happened=replacement,
            bug_triggered=bug,
        )


def main():
    logging.basicConfig(level=logging.CRITICAL)
    print(f"nvflare_import={nvflare.__file__}")
    print(f"pause_line={update_pause_line()}")

    level0 = run_case("level0_no_timing", pause_update=False)
    level1 = run_case("level1_timing_pause", pause_update=True)

    print("LEVEL0 " + json.dumps(level0.__dict__, sort_keys=True))
    print("LEVEL1 " + json.dumps(level1.__dict__, sort_keys=True))

    if not level1.bug_triggered:
        raise SystemExit("CR-33 NOT TRIGGERED")

    print(
        "CR33_TRIGGERED retained UPDATE_RUN_STATUS object replaced the "
        "INFRASTRUCTURE_ERROR failure record; completion published "
        f"{level1.final_status_published} instead of {level1.expected_status_from_fail_run}"
    )


if __name__ == "__main__":
    main()
