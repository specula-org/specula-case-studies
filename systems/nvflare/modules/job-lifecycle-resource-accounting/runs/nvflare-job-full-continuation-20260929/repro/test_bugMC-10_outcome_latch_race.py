#!/usr/bin/env python3
"""Reproduce MC-10: accepted client failure loses to a stale completion latch.

Escalation: Level 2 precondition construction plus Level 1 timing control.
The precondition is the normal post-SJ-exit state:
  _start_run/JobRunner.run has put the job in running_jobs and registered a
  pending client outcome; ServerEngine.wait_for_complete has removed the SJ
  from run_processes after a clean exit.
"""

import logging
import sys
import threading
from contextlib import contextmanager
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

SOURCE_ROOT = Path(
    "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/"
    "gpt-continuation/nvflare-job/.specula-output/confirmation/MC-10/worktree"
)
sys.path.insert(0, str(SOURCE_ROOT))

from nvflare.apis.fl_constant import FLContextKey, RunProcessKey, SystemComponents
from nvflare.apis.job_def import RunStatus
from nvflare.fuel.common.exit_codes import ProcessExitCode
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey
from nvflare.private.defs import CellMessageHeaderKeys, JobFailureMsgKey, new_cell_message
from nvflare.private.fed.server.fed_server import FederatedServer
from nvflare.private.fed.server.job_runner import JobRunner


JOB_ID = "job-mc10"
CLIENT = "site-1"
TOKEN = "token-1"


class FakeFLContext:
    def __init__(self, engine):
        self._engine = engine
        self.props = {}

    def get_engine(self):
        return self._engine

    def set_prop(self, key, value, *args, **kwargs):
        self.props[key] = value


class FakeJobManager:
    def __init__(self):
        self.status_history = []

    def set_status(self, job_id, status, fl_ctx):
        value = status.value if hasattr(status, "value") else status
        self.status_history.append((job_id, value))
        print(f"PUBLISH_STATUS job={job_id} status={value}")


class FakeEngine:
    def __init__(self, runner, job_manager):
        self.lock = threading.RLock()
        self.run_processes = {}
        self.exception_run_processes = {}
        self.client_manager = SimpleNamespace(clients={})
        self.job_runner = runner
        self._job_manager = job_manager
        self.removed_exception_processes = []

    def get_component(self, component_id):
        if component_id == SystemComponents.JOB_MANAGER:
            return self._job_manager
        raise AssertionError(f"unexpected component lookup: {component_id!r}")

    @contextmanager
    def new_context(self):
        yield FakeFLContext(self)

    def remove_exception_process(self, job_id):
        self.removed_exception_processes.append(job_id)
        self.exception_run_processes.pop(job_id, None)


def build_server(engine):
    server = FederatedServer.__new__(FederatedServer)
    server.engine = engine
    server.logger = logging.getLogger("mc10.server")
    server.client_manager = SimpleNamespace(
        clients={TOKEN: SimpleNamespace(name=CLIENT)},
        is_from_authorized_client=lambda token: token == TOKEN,
    )
    return server


def main():
    logging.basicConfig(level=logging.CRITICAL)

    print("ESCALATION_LEVEL=2+1")
    print("LEVEL_0=not run: full local deployment race was replaced by the reachable post-SJ-exit state")
    print("LEVEL_1=timing assistance: report handler paused after pending check; completion paused after status latch")
    print(
        "LEVEL_2_PRECONDITION="
        "_start_run registers pending client outcomes, JobRunner.run inserts running_jobs, "
        "ServerEngine.wait_for_complete removes run_processes after clean SJ exit"
    )

    runner = JobRunner(workspace_root="/tmp")
    runner.logger = logging.getLogger("mc10.runner")
    runner.log_info = MagicMock()
    runner.log_debug = MagicMock()
    runner.log_warning = MagicMock()
    runner.abort_client_run = MagicMock()
    runner.fire_event_with_data = MagicMock()
    runner.client_outcome_wait_timeout = 0.0
    runner.ask_to_stop = False

    job = SimpleNamespace(job_id=JOB_ID, run_aborted=False, meta={})
    runner.running_jobs = {JOB_ID: job}
    runner._pending_client_outcomes = {JOB_ID: {CLIENT}}
    runner._client_outcome_deadlines = {}

    job_manager = FakeJobManager()
    engine = FakeEngine(runner, job_manager)
    server = build_server(engine)

    report_checked_pending = threading.Event()
    allow_report_to_fail_run = threading.Event()
    completion_latched_status = threading.Event()
    allow_completion_to_publish = threading.Event()

    original_is_pending = runner.is_client_outcome_pending

    def delayed_pending_check(job_id, client_name):
        result = original_is_pending(job_id, client_name)
        if result:
            print(f"REPORT_PENDING_CHECK job={job_id} client={client_name} result={result}")
            report_checked_pending.set()
            if not allow_report_to_fail_run.wait(5.0):
                raise TimeoutError("test did not release report after pending check")
        return result

    runner.is_client_outcome_pending = delayed_pending_check

    def save_workspace_after_latch(fl_ctx, finished_state, job_id):
        print(f"COMPLETION_LATCHED job={job_id} status={finished_state.status.value}")
        completion_latched_status.set()
        if not allow_completion_to_publish.wait(5.0):
            raise TimeoutError("test did not release completion publish")

    runner._save_workspace = MagicMock(side_effect=save_workspace_after_latch)

    request = new_cell_message(
        {
            CellMessageHeaderKeys.TOKEN: TOKEN,
            MessageHeaderKey.ORIGIN: CLIENT,
        },
        {
            JobFailureMsgKey.JOB_ID: JOB_ID,
            JobFailureMsgKey.CODE: ProcessExitCode.INFRASTRUCTURE_ERROR,
            JobFailureMsgKey.REASON: "simulated client infrastructure failure",
        },
    )

    def report_failure():
        reply = server.process_job_failure(request)
        print(f"REPORT_REPLY rc={reply.get_header(MessageHeaderKey.RETURN_CODE)}")

    def complete_job_once():
        def stop_after_one_pass(_seconds):
            runner.ask_to_stop = True

        with patch(
            "nvflare.private.fed.server.job_runner.time",
            **{"monotonic.return_value": 100.0, "sleep.side_effect": stop_after_one_pass},
        ):
            runner._job_complete_process(engine)

    report_thread = threading.Thread(target=report_failure, name="client-report")
    report_thread.start()
    if not report_checked_pending.wait(5.0):
        raise TimeoutError("report did not pass pending check")

    completion_thread = threading.Thread(target=complete_job_once, name="job-completion")
    completion_thread.start()
    if not completion_latched_status.wait(5.0):
        raise TimeoutError("completion did not latch status")

    allow_report_to_fail_run.set()
    report_thread.join(5.0)
    if report_thread.is_alive():
        raise TimeoutError("report thread did not finish")

    recorded = engine.exception_run_processes.get(JOB_ID)
    recorded_code = None if recorded is None else recorded.get(RunProcessKey.PROCESS_RETURN_CODE)
    print(f"FAIL_RUN_RECORDED job={JOB_ID} code={recorded_code}")

    allow_completion_to_publish.set()
    completion_thread.join(5.0)
    if completion_thread.is_alive():
        raise TimeoutError("completion thread did not finish")

    final_status = job_manager.status_history[-1][1] if job_manager.status_history else None
    expected = RunStatus.FINISHED_ABNORMAL.value
    actual = final_status
    print(f"EXPECTED_STATUS_IF_FAILURE_WINS={expected}")
    print(f"ACTUAL_PUBLISHED_STATUS={actual}")
    print(f"EXCEPTION_RECORD_AFTER_COMPLETION={engine.exception_run_processes.get(JOB_ID)}")
    print(f"REMOVED_EXCEPTION_PROCESSES={engine.removed_exception_processes}")

    bug_triggered = recorded_code == ProcessExitCode.INFRASTRUCTURE_ERROR and actual == RunStatus.FINISHED_COMPLETED.value
    print(f"BUG_TRIGGERED={str(bug_triggered).lower()}")
    if not bug_triggered:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
