#!/usr/bin/env python3
"""Reproduce MC-1: acknowledged queued abort overwritten by runner lifecycle writes."""

import copy
import os
import sys
import threading
import time
from pathlib import Path
from types import SimpleNamespace


WORKTREE = Path(
    os.environ.get(
        "NVFLARE_MC1_WORKTREE",
        "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/"
        "gpt-continuation/nvflare-job/.specula-output/confirmation/MC-1/worktree",
    )
)
sys.path.insert(0, str(WORKTREE))

from nvflare.apis.fl_constant import SiteType, SystemComponents
from nvflare.apis.job_def import JobMetaKey, RunStatus, job_from_meta
from nvflare.apis.job_scheduler_spec import DispatchInfo
from nvflare.private.fed.server.job_cmds import JobCommandModule
from nvflare.private.fed.server.job_runner import JobRunner
from nvflare.private.fed.server.server_state import HotState


class FakeFLContext:
    def __init__(self, engine):
        self.engine = engine
        self.props = {}

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def get_engine(self):
        return self.engine

    def set_prop(self, key, value, *args, **kwargs):
        self.props[key] = value

    def get_prop(self, key, default=None):
        return self.props.get(key, default)

    def remove_prop(self, key):
        self.props.pop(key, None)

    def get_identity_name(self, default=None):
        return "server"


class RecordingConnection:
    def __init__(self, engine, job_id):
        self.app_ctx = engine
        self.props = {JobCommandModule.JOB_ID: job_id}
        self.strings = []
        self.successes = []
        self.errors = []

    def get_prop(self, key, default=None):
        return self.props.get(key, default)

    def append_string(self, message, meta=None):
        self.strings.append(message)

    def append_success(self, message, meta=None):
        self.successes.append((message, meta))

    def append_error(self, message, meta=None):
        self.errors.append((message, meta))


class RecordingJobManager:
    def __init__(self, job_id):
        self.lock = threading.Lock()
        self.meta = {
            JobMetaKey.JOB_ID.value: job_id,
            JobMetaKey.JOB_NAME.value: "mc1-repro",
            JobMetaKey.STATUS.value: RunStatus.SUBMITTED.value,
            JobMetaKey.DEPLOY_MAP.value: {"server_app": [SiteType.SERVER]},
            JobMetaKey.RESOURCE_SPEC.value: {},
            JobMetaKey.MIN_CLIENTS.value: 0,
            JobMetaKey.MANDATORY_CLIENTS.value: [],
            JobMetaKey.SCHEDULE_COUNT.value: 1,
            JobMetaKey.LAST_SCHEDULE_TIME.value: 0,
            JobMetaKey.SCHEDULE_HISTORY.value: [],
        }
        self.history = []

    def _copy_job(self):
        return job_from_meta(copy.deepcopy(self.meta))

    def get_job(self, jid, fl_ctx):
        if jid != self.meta[JobMetaKey.JOB_ID.value]:
            raise RuntimeError(f"unexpected job id {jid}")
        with self.lock:
            return self._copy_job()

    def get_jobs_to_schedule(self, fl_ctx):
        with self.lock:
            if self.meta[JobMetaKey.STATUS.value] == RunStatus.SUBMITTED.value:
                return [self._copy_job()]
            return []

    def set_status(self, jid, status, fl_ctx):
        if jid != self.meta[JobMetaKey.JOB_ID.value]:
            raise RuntimeError(f"unexpected job id {jid}")
        value = status.value if hasattr(status, "value") else status
        with self.lock:
            self.meta[JobMetaKey.STATUS.value] = value
            self.history.append(value)

    def update_meta(self, jid, meta, fl_ctx):
        if jid != self.meta[JobMetaKey.JOB_ID.value]:
            raise RuntimeError(f"unexpected job id {jid}")
        with self.lock:
            self.meta.update(meta)

    def status(self):
        with self.lock:
            return self.meta[JobMetaKey.STATUS.value]


class SingleJobScheduler:
    def schedule_job(self, job_manager, job_candidates, fl_ctx):
        if not job_candidates:
            return None, None
        return job_candidates[0], {SiteType.SERVER: DispatchInfo("server_app", {}, None)}


class FakeEngine:
    def __init__(self, job_manager, scheduler):
        self.job_def_manager = job_manager
        self.scheduler = scheduler
        self.job_runner = None
        self.server = SimpleNamespace(server_state=HotState())
        self.run_processes = {}
        self.exception_run_processes = {}
        self.lock = threading.Lock()

    def get_component(self, component_id):
        if component_id == SystemComponents.JOB_MANAGER:
            return self.job_def_manager
        if component_id == SystemComponents.JOB_SCHEDULER:
            return self.scheduler
        return None

    def get_clients(self):
        return [object()]

    def new_context(self):
        return FakeFLContext(self)

    def remove_exception_process(self, job_id):
        self.exception_run_processes.pop(job_id, None)


def install_quiet_runner_hooks(runner):
    def no_op(*args, **kwargs):
        return None

    runner.log_debug = no_op
    runner.log_info = no_op
    runner.log_warning = no_op
    runner.log_error = no_op
    runner.log_exception = no_op
    runner.fire_event = no_op
    runner.fire_event_with_data = no_op
    runner._fire_job_lifecycle_event = no_op


def abort_with_real_handler(engine, job_id):
    conn = RecordingConnection(engine, job_id)
    JobCommandModule().abort_job(conn, ["abort_job", job_id])
    return conn


def run_race_scenario(abort_site):
    job_id = f"mc1-{abort_site}"
    job_manager = RecordingJobManager(job_id)
    scheduler = SingleJobScheduler()
    engine = FakeEngine(job_manager, scheduler)
    runner = JobRunner(workspace_root="/tmp/nvflare-mc1-unused")
    install_quiet_runner_hooks(runner)
    runner.scheduler = scheduler
    engine.job_runner = runner

    abort_conn = None
    starts = []

    def fake_deploy(job, sites, fl_ctx):
        nonlocal abort_conn
        if abort_site == "deploy":
            abort_conn = abort_with_real_handler(engine, job.job_id)
            time.sleep(0.05)
        return job.job_id, []

    def fake_start_run(job_id, job, client_sites, fl_ctx):
        nonlocal abort_conn
        if abort_site == "start":
            abort_conn = abort_with_real_handler(engine, job_id)
            time.sleep(0.05)
        engine.run_processes[job_id] = {"participants": {}}
        starts.append(job_id)
        runner.ask_to_stop = True

    runner._deploy_job = fake_deploy
    runner._start_run = fake_start_run
    runner.run(FakeFLContext(engine))

    running_job = runner.running_jobs.get(job_id)
    acked = bool(abort_conn and abort_conn.successes and any("before running" in s for s in abort_conn.strings))
    return {
        "name": f"abort-during-{abort_site}",
        "ack_messages": list(abort_conn.strings if abort_conn else []),
        "ack_errors": list(abort_conn.errors if abort_conn else []),
        "status_history": list(job_manager.history),
        "final_status": job_manager.status(),
        "started_after_ack": acked and bool(starts),
        "run_aborted": bool(getattr(running_job, "run_aborted", False)),
        "bug_triggered": acked
        and bool(starts)
        and job_manager.status() == RunStatus.RUNNING.value
        and not bool(getattr(running_job, "run_aborted", False)),
    }


def run_pre_schedule_control():
    job_id = "mc1-control"
    job_manager = RecordingJobManager(job_id)
    scheduler = SingleJobScheduler()
    engine = FakeEngine(job_manager, scheduler)
    runner = JobRunner(workspace_root="/tmp/nvflare-mc1-unused")
    install_quiet_runner_hooks(runner)
    engine.job_runner = runner

    conn = abort_with_real_handler(engine, job_id)
    pending = job_manager.get_jobs_to_schedule(FakeFLContext(engine))
    return {
        "ack_messages": list(conn.strings),
        "status_history": list(job_manager.history),
        "final_status": job_manager.status(),
        "jobs_to_schedule_after_abort": len(pending),
        "control_ok": job_manager.status() == RunStatus.FINISHED_ABORTED.value and len(pending) == 0,
    }


def print_scenario(result):
    print(f"SCENARIO {result['name']}")
    print(f"  abort_reply={result['ack_messages']}")
    print(f"  abort_errors={result['ack_errors']}")
    print(f"  status_history={' -> '.join(result['status_history'])}")
    print(f"  final_status={result['final_status']}")
    print(f"  started_after_ack={result['started_after_ack']}")
    print(f"  run_aborted={result['run_aborted']}")
    print(f"  bug_triggered={result['bug_triggered']}")


def main():
    print(f"WORKTREE={WORKTREE}")
    print("ESCALATION=Level 1 timing-controlled harness; no state injection; no product source patch")

    control = run_pre_schedule_control()
    print("CONTROL abort-before-schedule")
    print(f"  abort_reply={control['ack_messages']}")
    print(f"  status_history={' -> '.join(control['status_history'])}")
    print(f"  final_status={control['final_status']}")
    print(f"  jobs_to_schedule_after_abort={control['jobs_to_schedule_after_abort']}")
    print(f"  control_ok={control['control_ok']}")

    deploy = run_race_scenario("deploy")
    start = run_race_scenario("start")
    print_scenario(deploy)
    print_scenario(start)

    if control["control_ok"] and deploy["bug_triggered"] and start["bug_triggered"]:
        print("RESULT: BUG REPRODUCED - acknowledged queued abort was overwritten and the job started RUNNING")
        return 0

    print("RESULT: BUG NOT REPRODUCED")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
