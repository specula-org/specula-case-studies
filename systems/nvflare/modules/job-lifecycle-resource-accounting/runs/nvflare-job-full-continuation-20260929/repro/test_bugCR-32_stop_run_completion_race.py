#!/usr/bin/env python3
"""Reproduce CR-32: accepted abort can publish FINISHED:COMPLETED.

This is a focused harness around the pinned NVFlare source. It uses real
JobCommandModule.abort_job, JobRunner.stop_run/_job_complete_process, and
ServerEngine abort/completion methods. The fake pieces are the child process,
admin connection, and minimal engine/job store needed to drive those methods.
"""

from __future__ import annotations

import sys
import tempfile
import threading
import time
from pathlib import Path
from types import SimpleNamespace


WORKTREE = Path(
    "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/"
    "gpt-continuation/nvflare-job/.specula-output/confirmation/CR-32/worktree"
)
sys.path.insert(0, str(WORKTREE))

from nvflare.apis.fl_constant import MachineStatus, RunProcessKey, SystemComponents  # noqa: E402
from nvflare.apis.fl_context import FLContextManager  # noqa: E402
from nvflare.apis.job_def import Job, JobMetaKey, RunStatus  # noqa: E402
from nvflare.private.fed.server.job_cmds import JobCommandModule  # noqa: E402
from nvflare.private.fed.server.job_runner import JobRunner  # noqa: E402
from nvflare.private.fed.server.server_engine import ServerEngine  # noqa: E402


JOB_ID = "cr32-job"


class QuietLogger:
    def debug(self, *_args, **_kwargs):
        pass

    def info(self, *_args, **_kwargs):
        pass

    def warning(self, *_args, **_kwargs):
        pass

    def error(self, *_args, **_kwargs):
        pass


class FakeWorkspace:
    def __init__(self, root: Path):
        self.root = root

    def get_run_dir(self, job_id: str) -> str:
        return str(self.root / "run" / job_id)

    def get_result_root(self, job_id: str) -> str:
        return str(self.root / "result" / job_id)

    def get_log_root(self, job_id: str) -> str:
        return str(self.root / "log" / job_id)

    def get_audit_root(self, job_id: str) -> str:
        return str(self.root / "audit" / job_id)


class ControlledProcess:
    def __init__(self):
        self._exit = threading.Event()
        self._return_code = None
        self.terminated = False

    def wait(self):
        if not self._exit.wait(timeout=10.0):
            raise TimeoutError("child process did not exit")

    def poll(self):
        return self._return_code if self._exit.is_set() else None

    def exit_cleanly(self):
        self._return_code = 0
        self._exit.set()

    def terminate(self):
        self.terminated = True
        if not self._exit.is_set():
            self._return_code = -15
            self._exit.set()


class FakeJobManager:
    def __init__(self, job: Job, events: list[str], hold_running_job_after_status: bool):
        self.job = job
        self.events = events
        self.hold_running_job_after_status = hold_running_job_after_status
        self.status_set = threading.Event()
        self.statuses: list[tuple[str, str]] = []

    def get_job(self, job_id, _fl_ctx):
        if job_id != self.job.job_id:
            raise RuntimeError(f"unexpected job id {job_id}")
        return self.job

    def set_status(self, job_id, status, _fl_ctx):
        status_value = status.value if isinstance(status, RunStatus) else str(status)
        self.statuses.append((job_id, status_value))
        self.job.meta[JobMetaKey.STATUS] = status_value
        self.events.append(f"completion_set_status:{status_value}")
        self.status_set.set()
        if self.hold_running_job_after_status:
            # Keep _job_complete_process inside set_status briefly so stop_run can
            # reach mark_run_aborted before the completion loop deletes running_jobs.
            time.sleep(0.35)

    def save_workspace(self, _job_id, _ws_dirs, _fl_ctx):
        return "/fake/job-store/workspace"


class FakeAdminServer:
    timeout = 1.0

    def __init__(self, engine):
        self.sai = engine

    def send_requests(self, requests, _fl_ctx, timeout_secs=None, optional=False):
        assert requests == {}
        return []


class FakeEngine:
    def __init__(
        self,
        root: Path,
        runner: JobRunner,
        job_manager: FakeJobManager,
        process: ControlledProcess,
        events: list[str],
        delay_abort_reply_until_completion_status: bool,
    ):
        self.root = root
        self.job_runner = runner
        self.job_def_manager = job_manager
        self.lock = threading.RLock()
        self.logger = QuietLogger()
        self.client_manager = SimpleNamespace(clients={})
        self.engine_info = SimpleNamespace(status=MachineStatus.STARTED)
        self.exception_run_processes = {}
        self.run_processes = {
            JOB_ID: {
                RunProcessKey.PARTICIPANTS: {},
                RunProcessKey.JOB_HANDLE: process,
            }
        }
        self._workspace = FakeWorkspace(root)
        self._ctx_manager = FLContextManager(engine=self, identity_name="server", job_id=JOB_ID)
        self.server = SimpleNamespace(admin_server=FakeAdminServer(self))
        self.process = process
        self.events = events
        self.delay_abort_reply_until_completion_status = delay_abort_reply_until_completion_status

    def new_context(self):
        return self._ctx_manager.new_context()

    def get_workspace(self):
        return self._workspace

    def get_component(self, component_id):
        if component_id == SystemComponents.JOB_MANAGER:
            return self.job_def_manager
        raise RuntimeError(f"unexpected component lookup: {component_id}")

    def validate_targets(self, client_sites):
        assert client_sites == []
        return [], []

    def remove_exception_process(self, job_id):
        self.exception_run_processes.pop(job_id, None)

    def abort_app_on_server(self, job_id):
        return ServerEngine.abort_app_on_server(self, job_id)

    def _remove_run_processes(self, job_id, job_handle=None, max_wait=10.0):
        return ServerEngine._remove_run_processes(self, job_id, job_handle, max_wait)

    def wait_for_complete(self, workspace, job_id, process):
        return ServerEngine.wait_for_complete(self, workspace, job_id, process)

    def send_command_to_child_runner_process(
        self, job_id, command_name, command_data, timeout=None, optional=False
    ):
        self.events.append(f"child_abort_rpc_entered:{command_name}")
        with self.lock:
            run_process = self.run_processes.get(job_id)
            if run_process is not None:
                run_process[RunProcessKey.PROCESS_FINISHED] = True
        self.process.exit_cleanly()
        self.events.append("child_process_exited_cleanly_before_abort_flag")

        if self.delay_abort_reply_until_completion_status:
            if not self.job_def_manager.status_set.wait(timeout=5.0):
                raise TimeoutError("completion did not publish status while abort RPC was in progress")
            self.events.append("abort_rpc_released_after_completion_status")
        return "OK"


class FakeConnection:
    def __init__(self, engine, job_id):
        self.app_ctx = engine
        self._props = {JobCommandModule.JOB_ID: job_id}
        self.strings = []
        self.successes = []
        self.errors = []

    def get_prop(self, key, default=None):
        return self._props.get(key, default)

    def append_string(self, message, meta=None):
        self.strings.append((message, meta))

    def append_success(self, data, meta=None):
        self.successes.append((data, meta))

    def append_error(self, error, meta=None):
        self.errors.append((error, meta))


def make_runner() -> JobRunner:
    runner = JobRunner(workspace_root="/tmp")
    runner.logger = QuietLogger()
    runner.log_info = lambda *_args, **_kwargs: None
    runner.log_warning = lambda *_args, **_kwargs: None
    runner.log_error = lambda *_args, **_kwargs: None
    runner.log_exception = lambda *_args, **_kwargs: None
    runner.log_debug = lambda *_args, **_kwargs: None
    runner._fire_job_lifecycle_event = lambda *_args, **_kwargs: None
    return runner


def wait_for_status(job_manager: FakeJobManager, runner: JobRunner, completion_thread: threading.Thread):
    if not job_manager.status_set.wait(timeout=6.0):
        raise TimeoutError("completion did not publish a terminal status")
    deadline = time.time() + 6.0
    while JOB_ID in runner.running_jobs and time.time() < deadline:
        time.sleep(0.02)
    runner.ask_to_stop = True
    completion_thread.join(timeout=3.0)


def run_case(name: str, delay_abort_reply_until_completion_status: bool):
    events: list[str] = []
    with tempfile.TemporaryDirectory(prefix=f"cr32-{name}-") as temp_dir:
        root = Path(temp_dir)
        job = Job(
            job_id=JOB_ID,
            resource_spec={},
            deploy_map={"server_app": ["server"]},
            meta={JobMetaKey.STATUS: RunStatus.RUNNING.value},
        )
        process = ControlledProcess()
        runner = make_runner()
        runner.running_jobs = {JOB_ID: job}
        runner._pending_client_outcomes = {}

        job_manager = FakeJobManager(
            job=job,
            events=events,
            hold_running_job_after_status=delay_abort_reply_until_completion_status,
        )
        engine = FakeEngine(
            root=root,
            runner=runner,
            job_manager=job_manager,
            process=process,
            events=events,
            delay_abort_reply_until_completion_status=delay_abort_reply_until_completion_status,
        )

        completion_thread = threading.Thread(target=runner._job_complete_process, args=(engine,), daemon=True)
        completion_thread.start()
        waiter_thread = threading.Thread(
            target=engine.wait_for_complete,
            args=(str(root), JOB_ID, process),
            daemon=True,
        )
        waiter_thread.start()

        conn = FakeConnection(engine=engine, job_id=JOB_ID)
        JobCommandModule().abort_job(conn, ["abort_job", JOB_ID])
        events.append(
            "admin_abort_returned:"
            + ("success" if conn.successes else "error")
            + f":job_run_aborted={job.run_aborted}"
        )

        wait_for_status(job_manager, runner, completion_thread)
        waiter_thread.join(timeout=3.0)

        return {
            "name": name,
            "status": job_manager.statuses[-1][1],
            "admin_success": bool(conn.successes),
            "admin_strings": [message for message, _meta in conn.strings],
            "admin_errors": [error for error, _meta in conn.errors],
            "job_run_aborted_after_admin_return": job.run_aborted,
            "running_after_completion": JOB_ID in runner.running_jobs,
            "events": events,
        }


def print_case(result):
    print(f"\n[{result['name']}]")
    print(f"admin_success={result['admin_success']}")
    print(f"admin_strings={result['admin_strings']}")
    print(f"admin_errors={result['admin_errors']}")
    print(f"final_status={result['status']}")
    print(f"job_run_aborted_after_admin_return={result['job_run_aborted_after_admin_return']}")
    print(f"running_after_completion={result['running_after_completion']}")
    print("event_order=" + " -> ".join(result["events"]))


def main() -> int:
    print("CR-32 reproduction: stop_run/completion race can publish completed after accepted abort")
    print(f"source={WORKTREE}")

    control = run_case(
        name="control_no_timing_delay",
        delay_abort_reply_until_completion_status=False,
    )
    race = run_case(
        name="timed_child_abort_rpc_delay",
        delay_abort_reply_until_completion_status=True,
    )

    print_case(control)
    print_case(race)

    assert control["admin_success"], "control abort command should succeed"
    assert control["status"] == RunStatus.FINISHED_ABORTED.value, (
        "control case should finish aborted when stop_run marks the job before completion"
    )

    assert race["admin_success"], "race abort command should still report success"
    assert race["job_run_aborted_after_admin_return"], "stop_run should eventually mark run_aborted"
    assert race["status"] == RunStatus.FINISHED_COMPLETED.value, (
        "bug expected: completion latched completed before stop_run marked aborted"
    )
    assert not race["running_after_completion"], "completion removes the running job, so no later loop revises status"

    print(
        "\nREPRODUCED: accepted abort_job returned success, but the terminal job status "
        f"was {race['status']} instead of {RunStatus.FINISHED_ABORTED.value}."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
