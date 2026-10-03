#!/usr/bin/env python3
"""Reproduce MC-9: admin abort reports success while completion publishes COMPLETED.

This is a timing-assisted reproduction against the real NVFlare JobRunner and
JobCommandModule.abort_job path.  It starts from the normal RUNNING job shape
created by JobRunner.run(), then controls only the interleaving between:

1. abort_job -> JobRunner.stop_run -> _stop_run -> abort_app_on_server
2. JobRunner._job_complete_process
3. stop_run -> mark_run_aborted
"""

import os
import sys
import tempfile
import threading
import time
import traceback
from contextlib import contextmanager
from types import SimpleNamespace


SOURCE = (
    "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/"
    "gpt-continuation/nvflare-job/.specula-output/confirmation/MC-9/worktree"
)
sys.path.insert(0, SOURCE)

from nvflare.apis.fl_constant import FLContextKey, RunProcessKey, SystemComponents
from nvflare.apis.job_def import JobMetaKey
from nvflare.apis.job_def_manager_spec import RunStatus
from nvflare.fuel.hci.proto import MetaStatusValue
from nvflare.private.fed.server.job_cmds import JobCommandModule
from nvflare.private.fed.server.job_runner import JobRunner


JOB_ID = "job-1"


class FakeFLContext:
    def __init__(self, engine):
        self._engine = engine
        self._props = {}

    def get_engine(self):
        return self._engine

    def set_prop(self, key, value, *args, **kwargs):
        self._props[key] = value

    def get_prop(self, key, default=None):
        return self._props.get(key, default)

    def get_identity_name(self):
        return "server"

    def get_job_id(self, default=None):
        return self._props.get(FLContextKey.CURRENT_JOB_ID, default)

    def get_peer_context(self):
        return None

    def get_workspace(self):
        raise AssertionError("workspace should not be used in this focused repro")


class FakeJobManager:
    def __init__(self, job, status_started, status_published, release_status_return):
        self.job = job
        self.status_started = status_started
        self.status_published = status_published
        self.release_status_return = release_status_return
        self.status_calls = []

    def get_job(self, job_id, fl_ctx=None, jid=None):
        if jid is not None:
            job_id = jid
        assert job_id == self.job.job_id
        return self.job

    def set_status(self, job_id, status, fl_ctx):
        self.status_started.set()
        self.status_calls.append((job_id, status.value if hasattr(status, "value") else status))
        self.job.meta[JobMetaKey.STATUS] = status.value if hasattr(status, "value") else status
        self.status_published.set()
        if not self.release_status_return.wait(timeout=5.0):
            raise TimeoutError("test did not release set_status")

    def save_workspace(self, job_id, ws_dirs, fl_ctx):
        return "/fake/storage/workspace.zip"


class FakeConnection:
    def __init__(self, engine, job_id):
        self.app_ctx = engine
        self.props = {JobCommandModule.JOB_ID: job_id}
        self.strings = []
        self.successes = []
        self.errors = []

    def get_prop(self, name, default=None):
        return self.props.get(name, default)

    def set_prop(self, name, value):
        self.props[name] = value

    def append_string(self, value):
        self.strings.append(value)

    def append_success(self, value, meta=None):
        self.successes.append((value, meta))

    def append_error(self, value, meta=None):
        self.errors.append((value, meta))


class FakeEngine:
    def __init__(self, runner, job_manager, status_published):
        self.job_runner = runner
        self.job_def_manager = job_manager
        self.lock = threading.RLock()
        self.run_processes = {JOB_ID: {RunProcessKey.PARTICIPANTS: {}}}
        self.exception_run_processes = {}
        self.client_manager = SimpleNamespace(clients={})
        self.server = SimpleNamespace(
            admin_server=SimpleNamespace(timeout=1.0, sai=self, send_requests=lambda *args, **kwargs: [])
        )
        self._status_published = status_published

    @contextmanager
    def new_context(self):
        yield FakeFLContext(self)

    def get_component(self, name):
        if name == SystemComponents.JOB_MANAGER:
            return self.job_def_manager
        return None

    def validate_targets(self, client_sites):
        return [], []

    def remove_exception_process(self, job_id):
        with self.lock:
            self.exception_run_processes.pop(job_id, None)

    def abort_app_on_server(self, job_id):
        # Simulates the real cooperative SJ abort path: the server app exits cleanly
        # and wait_for_complete removes run_processes before stop_run marks aborted.
        with self.lock:
            self.run_processes.pop(job_id, None)
        if not self._status_published.wait(timeout=5.0):
            return "completion did not publish while abort was in _stop_run"
        return ""


def meta_status(success_record):
    meta = success_record[1]
    if isinstance(meta, dict):
        return meta.get("status")
    return getattr(meta, "status", None)


def main():
    status_started = threading.Event()
    status_published = threading.Event()
    release_status_return = threading.Event()

    job = SimpleNamespace(
        job_id=JOB_ID,
        run_aborted=False,
        meta={JobMetaKey.STATUS: RunStatus.RUNNING.value},
    )

    with tempfile.TemporaryDirectory(prefix="mc9-workspace-") as tmpdir:
        runner = JobRunner(workspace_root=tmpdir)
        runner.running_jobs[JOB_ID] = job
        runner._pending_client_outcomes[JOB_ID] = set()
        runner._fire_job_lifecycle_event = lambda event_type, job_id, fl_ctx: None
        runner._save_workspace = lambda fl_ctx, finished_state, job_id: None

        job_manager = FakeJobManager(job, status_started, status_published, release_status_return)
        engine = FakeEngine(runner, job_manager, status_published)

        thread_errors = []

        def run_completion():
            try:
                runner._job_complete_process(engine)
            except Exception:
                thread_errors.append(("completion", traceback.format_exc()))

        completion_thread = threading.Thread(target=run_completion, name="completion")
        completion_thread.start()

        command = JobCommandModule()
        conn = FakeConnection(engine, JOB_ID)

        def run_admin():
            try:
                command.abort_job(conn, ["abort_job", JOB_ID])
            except Exception:
                thread_errors.append(("admin", traceback.format_exc()))

        admin_thread = threading.Thread(target=run_admin, name="admin")
        admin_thread.start()

        if not status_started.wait(timeout=5.0):
            runner.ask_to_stop = True
            admin_thread.join(timeout=1.0)
            completion_thread.join(timeout=2.0)
            raise AssertionError(
                "completion did not enter job_manager.set_status; "
                f"admin_errors={conn.errors!r}; admin_strings={conn.strings!r}; "
                f"run_processes={list(engine.run_processes.keys())!r}; thread_errors={thread_errors!r}"
            )

        # Allow the admin call to leave _stop_run and run mark_run_aborted while
        # _job_complete_process is still in set_status, before it deletes running_jobs.
        admin_thread.join(timeout=5.0)
        if admin_thread.is_alive():
            release_status_return.set()
            runner.ask_to_stop = True
            admin_thread.join(timeout=1.0)
            completion_thread.join(timeout=2.0)
            raise AssertionError("admin abort did not return")

        release_status_return.set()
        time.sleep(0.05)
        runner.ask_to_stop = True
        completion_thread.join(timeout=2.0)
        if completion_thread.is_alive():
            raise AssertionError("completion thread did not stop")

    published_statuses = [status for _, status in job_manager.status_calls]
    final_published_status = published_statuses[-1] if published_statuses else None
    success_statuses = [meta_status(record) for record in conn.successes]
    admin_success = not conn.errors and any(status == MetaStatusValue.OK for status in success_statuses)

    print("MC-9 reproduction: stop-before-marker interleaving")
    print("escalation_level=2 (state injection of CE State 23/24 RUNNING precondition; real admin abort path)")
    print("admissible_precondition=counterexample State 23/24 has status RUNNING, runningJobs={j1}, rp present, runAborted=FALSE")
    print("real_entrypoint=nvflare/private/fed/server/job_cmds.py:1051 JobCommandModule.abort_job")
    print("completion_path=nvflare/private/fed/server/job_runner.py:441 _job_complete_process")
    print(f"admin_strings={conn.strings!r}")
    print(f"admin_errors={conn.errors!r}")
    print(f"admin_success={admin_success}")
    print(f"published_statuses={published_statuses!r}")
    print(f"final_published_status={final_published_status}")
    print(f"job_run_aborted_after_admin={job.run_aborted}")
    print(f"running_jobs_after_completion={list(runner.running_jobs.keys())!r}")
    print("expected_if_abort_wins=FINISHED:ABORTED or abort reports job not running")

    observed = (
        admin_success
        and final_published_status == RunStatus.FINISHED_COMPLETED.value
        and job.run_aborted is True
        and not runner.running_jobs
    )
    print(f"BUG_TRIGGERED={observed}")
    return 0 if observed else 1


if __name__ == "__main__":
    raise SystemExit(main())
