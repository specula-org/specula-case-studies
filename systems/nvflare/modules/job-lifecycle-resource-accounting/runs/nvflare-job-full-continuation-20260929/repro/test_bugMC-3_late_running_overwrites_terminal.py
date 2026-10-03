#!/usr/bin/env python3
"""Reproduce MC-3: late RUNNING overwrites a terminal completion status."""

from __future__ import annotations

import json
import os
import sys
import threading
import time
from contextlib import contextmanager
from types import SimpleNamespace
from unittest.mock import patch


WORKTREE = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "../confirmation/MC-3/worktree")
)
if WORKTREE not in sys.path:
    sys.path.insert(0, WORKTREE)

from nvflare.apis.fl_constant import FLContextKey, RunProcessKey, SiteType, SystemComponents
from nvflare.apis.job_def import Job, JobMetaKey, RunStatus
from nvflare.fuel.common.exit_codes import ProcessExitCode
from nvflare.private.admin_defs import ReturnCode
from nvflare.private.fed.server.job_cmds import JobCommandModule
from nvflare.private.fed.server.job_runner import JobRunner
from nvflare.private.fed.server.server_state import HotState


REAL_SLEEP = time.sleep


class FakeFLContext:
    def __init__(self, engine):
        self.engine = engine
        self.props = {}

    def get_engine(self):
        return self.engine

    def set_prop(self, key, value, *args, **kwargs):
        self.props[key] = value

    def get_prop(self, key, default=None):
        return self.props.get(key, default)

    def get_identity_name(self):
        return "repro-sp"


class FakeClient:
    def __init__(self, name="site-1", token="token-site-1"):
        self.name = name
        self.token = token

    def to_dict(self):
        return {"name": self.name, "token": self.token}


class FakeReplyBody:
    body = ""

    def get_header(self, key, default=None):
        return ReturnCode.OK if default is None else default


class FakeClientReply:
    def __init__(self, client_name):
        self.client_name = client_name
        self.reply = FakeReplyBody()


class FakeScheduler:
    def schedule_job(self, job_manager, job_candidates, fl_ctx):
        if not job_candidates:
            return None, {}
        return (
            job_candidates[0],
            {
                SiteType.SERVER: object(),
                "site-1": object(),
            },
        )


class RecordingJobManager:
    def __init__(self, job, gate_late_running: bool):
        self.job = job
        self.gate_late_running = gate_late_running
        self.runner = None
        self.engine = None
        self.lock = threading.RLock()
        self.history = []
        self.scheduled_once = False
        self.terminal_published = threading.Event()

    def attach(self, runner, engine):
        self.runner = runner
        self.engine = engine

    def get_jobs_to_schedule(self, fl_ctx):
        if self.scheduled_once:
            return []
        self.scheduled_once = True
        return [self.job]

    def get_job(self, jid=None, fl_ctx=None, *args, **kwargs):
        if jid is None and args:
            jid = args[0]
        if jid is None:
            jid = kwargs.get("jid")
        return self.job if jid == self.job.job_id else None

    def set_status(self, job_id, status, fl_ctx):
        value = status.value if hasattr(status, "value") else str(status)
        if value == RunStatus.RUNNING.value and self.gate_late_running:
            if not self.terminal_published.wait(timeout=5):
                raise AssertionError("timing gate timed out waiting for terminal publication")
            deadline = time.monotonic() + 5
            while job_id in self.runner.running_jobs:
                if time.monotonic() > deadline:
                    raise AssertionError("timing gate timed out waiting for completion removal")
                REAL_SLEEP(0.005)

        with self.lock:
            self.history.append(value)
            self.job.meta[JobMetaKey.STATUS] = value
            self.job.meta[JobMetaKey.STATUS.value] = value

        if value.startswith("FINISHED:"):
            self.terminal_published.set()
            if not self.gate_late_running:
                self.runner.ask_to_stop = True

        if value == RunStatus.RUNNING.value and self.gate_late_running:
            self.runner.ask_to_stop = True

    def update_meta(self, job_id, meta, fl_ctx):
        self.job.meta.update(meta)

    def save_workspace(self, job_id, ws_dirs, fl_ctx):
        return "/tmp/repro-workspace.zip"


class FakeEngine:
    def __init__(self, job_manager):
        self.job_manager = job_manager
        self.lock = threading.RLock()
        self.run_processes = {}
        self.exception_run_processes = {}
        self.client = FakeClient()
        self.client_manager = SimpleNamespace(clients={self.client.token: self.client})
        self.server = SimpleNamespace(
            server_state=HotState(),
            admin_server=SimpleNamespace(timeout=0.05, sai=SimpleNamespace(new_context=self.new_context)),
        )
        self.job_runner = None
        self.job_def_manager = job_manager

    def get_component(self, component_id):
        if component_id == SystemComponents.JOB_MANAGER:
            return self.job_manager
        return None

    def get_clients(self):
        return [self.client]

    def get_job_clients(self, client_sites):
        return {self.client.token: self.client}

    def start_app_on_server(self, fl_ctx, job=None, job_clients=None, snapshot=None):
        info = {
            RunProcessKey.JOB_HANDLE: object(),
            RunProcessKey.JOB_ID: job.job_id,
            RunProcessKey.PARTICIPANTS: dict(job_clients or {}),
        }
        with self.lock:
            self.run_processes[job.job_id] = info

        def finish_sj_early():
            REAL_SLEEP(0.02)
            with self.lock:
                run_info = self.run_processes.get(job.job_id)
                if run_info is None:
                    return
                run_info[RunProcessKey.PROCESS_RETURN_CODE] = ProcessExitCode.EXCEPTION
                self.exception_run_processes[job.job_id] = run_info
                self.run_processes.pop(job.job_id, None)

        threading.Thread(target=finish_sj_early, daemon=True).start()
        return ""

    def start_client_job(self, job, client_sites, fl_ctx):
        return [FakeClientReply(name) for name in client_sites]

    @contextmanager
    def new_context(self):
        yield FakeFLContext(self)

    def remove_exception_process(self, job_id):
        with self.lock:
            self.exception_run_processes.pop(job_id, None)

    def abort_app_on_server(self, job_id):
        with self.lock:
            self.run_processes.pop(job_id, None)
        return ""


class ReproJobRunner(JobRunner):
    def _deploy_job(self, job, sites, fl_ctx):
        return job.job_id, []


class FakeConn:
    def __init__(self, engine, job_id):
        self.app_ctx = engine
        self.job_id = job_id
        self.messages = []

    def get_prop(self, key, default=None):
        if key == JobCommandModule.JOB_ID:
            return self.job_id
        return default

    def append_error(self, message, meta=None):
        self.messages.append(("ERROR", message))

    def append_string(self, message):
        self.messages.append(("STRING", message))

    def append_success(self, message, meta=None):
        self.messages.append(("SUCCESS", message))


def make_job(job_id):
    meta = {
        JobMetaKey.JOB_ID: job_id,
        JobMetaKey.JOB_ID.value: job_id,
        JobMetaKey.STATUS: RunStatus.SUBMITTED.value,
        JobMetaKey.STATUS.value: RunStatus.SUBMITTED.value,
        JobMetaKey.SCHEDULE_COUNT.value: 0,
        JobMetaKey.LAST_SCHEDULE_TIME.value: 0,
        JobMetaKey.SCHEDULE_HISTORY.value: [],
    }
    return Job(
        job_id=job_id,
        resource_spec={},
        deploy_map={"server": [SiteType.SERVER], "client": ["site-1"]},
        meta=meta,
        min_sites=1,
        required_sites=[],
    )


def no_op(*args, **kwargs):
    return None


def run_job(gate_late_running: bool):
    job = make_job("job-mc3")
    job_manager = RecordingJobManager(job, gate_late_running=gate_late_running)
    engine = FakeEngine(job_manager)
    runner = ReproJobRunner(workspace_root="/tmp")
    runner.scheduler = FakeScheduler()
    runner.abort_client_run = no_op
    runner._save_workspace = no_op
    runner._fire_job_lifecycle_event = no_op
    for name in ("log_debug", "log_info", "log_warning", "log_error", "log_exception"):
        setattr(runner, name, no_op)
    runner.logger = SimpleNamespace(info=no_op, warning=no_op, error=no_op, debug=no_op)
    engine.job_runner = runner
    job_manager.attach(runner, engine)

    fl_ctx = FakeFLContext(engine)

    def fast_sleep(seconds):
        REAL_SLEEP(0.01 if seconds else 0)

    with patch("nvflare.private.fed.server.job_runner.time.sleep", side_effect=fast_sleep):
        t = threading.Thread(target=runner.run, args=(fl_ctx,), daemon=True)
        t.start()
        t.join(timeout=8)
        if t.is_alive():
            runner.ask_to_stop = True
            t.join(timeout=2)
            raise AssertionError("JobRunner.run did not stop")

    final_status = job.meta[JobMetaKey.STATUS]
    return {
        "history": list(job_manager.history),
        "final_status": final_status,
        "running_jobs": sorted(runner.running_jobs.keys()),
        "run_processes": sorted(engine.run_processes.keys()),
        "exception_run_processes": sorted(engine.exception_run_processes.keys()),
        "runner": runner,
        "engine": engine,
        "job_manager": job_manager,
        "job": job,
    }


def exercise_abort_consumer(engine, job_id):
    conn = FakeConn(engine, job_id)
    JobCommandModule().abort_job(conn, ["abort_job", job_id])
    return conn.messages


def main():
    level0 = run_job(gate_late_running=False)
    level1 = run_job(gate_late_running=True)
    abort_messages = exercise_abort_consumer(level1["engine"], "job-mc3")

    expected_level0 = [
        RunStatus.DISPATCHED.value,
        RunStatus.RUNNING.value,
        RunStatus.FINISHED_EXECUTION_EXCEPTION.value,
    ]
    expected_level1 = [
        RunStatus.DISPATCHED.value,
        RunStatus.FINISHED_EXECUTION_EXCEPTION.value,
        RunStatus.RUNNING.value,
    ]

    bug_triggered = (
        level0["history"] == expected_level0
        and level1["history"] == expected_level1
        and level1["final_status"] == RunStatus.RUNNING.value
        and level1["running_jobs"] == []
        and level1["run_processes"] == []
        and any(kind == "ERROR" and "is not running" in msg for kind, msg in abort_messages)
    )

    report = {
        "level0_control": {
            "description": "normal JobRunner.run path with no timing gate",
            "status_history": level0["history"],
            "final_status": level0["final_status"],
        },
        "level1_timing_assisted": {
            "description": "same path, but the RUNNING persistence call waits until completion publishes terminal and removes running_jobs",
            "status_history": level1["history"],
            "final_status": level1["final_status"],
            "running_jobs": level1["running_jobs"],
            "run_processes": level1["run_processes"],
            "exception_run_processes": level1["exception_run_processes"],
        },
        "consumer_abort_job_messages": abort_messages,
        "bug_triggered": bug_triggered,
    }
    print(json.dumps(report, indent=2, sort_keys=True))
    if not bug_triggered:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
