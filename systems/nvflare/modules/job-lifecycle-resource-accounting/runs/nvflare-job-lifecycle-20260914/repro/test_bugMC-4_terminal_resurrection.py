#!/usr/bin/env python3
"""Reproduce MC-4: a delayed RUNNING status write can overwrite terminal state."""

from __future__ import annotations

import os
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path


WORKTREE = Path(
    "/home/ubuntu/nvflare-job-lifecycle-20260914/specula/runs/"
    "nvflare-job-lifecycle-20260914/nvflare-job-lifecycle/"
    ".specula-output/confirmation/MC-4/worktree"
)
sys.path.insert(0, str(WORKTREE))

from nvflare.apis.client import Client  # noqa: E402
from nvflare.apis.fl_constant import FLContextKey, RunProcessKey, SiteType, SystemComponents  # noqa: E402
from nvflare.apis.fl_context import FLContextManager  # noqa: E402
from nvflare.apis.job_def import Job, JobMetaKey, RunStatus  # noqa: E402
from nvflare.fuel.flare_api.api_spec import MonitorReturnCode  # noqa: E402
from nvflare.fuel.flare_api.flare_api import Session  # noqa: E402
from nvflare.private.admin_defs import Message, MsgHeader, ReturnCode  # noqa: E402
from nvflare.private.fed.server.job_runner import JobRunner  # noqa: E402
from nvflare.private.fed.server.message_send import ClientReply  # noqa: E402
from nvflare.private.fed.server.server_state import HotState  # noqa: E402


JOB_ID = "mc4-job"
CLIENT_NAME = "site-1"
CLIENT_TOKEN = "token-site-1"


class FakeWorkspace:
    def __init__(self, root: Path):
        self.root = root
        for name in ("run", "result", "log", "audit"):
            (root / name / JOB_ID).mkdir(parents=True, exist_ok=True)

    def get_run_dir(self, job_id):
        return str(self.root / "run" / job_id)

    def get_result_root(self, job_id):
        return str(self.root / "result" / job_id)

    def get_log_root(self, job_id):
        return str(self.root / "log" / job_id)

    def get_audit_root(self, job_id):
        return str(self.root / "audit" / job_id)


class FakeServer:
    def __init__(self):
        self.server_state = HotState()
        self.admin_server = None


class FakeScheduler:
    def schedule_job(self, job_manager, job_candidates, fl_ctx):
        if not job_candidates:
            return None, {}
        return job_candidates[0], {SiteType.SERVER: object(), CLIENT_NAME: object()}


class FakeJobManager:
    def __init__(self, block_running_write: bool):
        self.block_running_write = block_running_write
        self.running_write_entered = threading.Event()
        self.allow_running_write = threading.Event()
        self.running_written = threading.Event()
        self.terminal_written = threading.Event()
        self.history: list[str] = []
        self.lock = threading.RLock()
        self.offered = False
        self.meta = {
            JobMetaKey.JOB_ID.value: JOB_ID,
            JobMetaKey.JOB_NAME.value: "mc4-repro",
            JobMetaKey.STATUS.value: RunStatus.SUBMITTED.value,
            JobMetaKey.SCHEDULE_COUNT.value: 1,
            JobMetaKey.LAST_SCHEDULE_TIME.value: 0,
            JobMetaKey.SCHEDULE_HISTORY.value: [],
        }
        self.job = Job(
            job_id=JOB_ID,
            resource_spec={},
            deploy_map={},
            meta=self.meta,
            min_sites=0,
            required_sites=[],
        )

    def get_jobs_to_schedule(self, fl_ctx):
        with self.lock:
            if self.offered or self.meta[JobMetaKey.STATUS.value] != RunStatus.SUBMITTED.value:
                return []
            self.offered = True
            return [self.job]

    def get_job(self, jid, fl_ctx):
        if jid != JOB_ID:
            raise KeyError(jid)
        return self.job

    def get_app(self, job, app_name, fl_ctx):
        return b""

    def save_workspace(self, job_id, ws_dirs, fl_ctx):
        return f"fake://workspace/{job_id}"

    def update_meta(self, jid, meta, fl_ctx):
        with self.lock:
            self.meta.update(meta)

    def set_status(self, jid, status, fl_ctx):
        if jid != JOB_ID:
            raise KeyError(jid)
        status_value = status.value if isinstance(status, RunStatus) else str(status)
        if status == RunStatus.RUNNING:
            self.running_write_entered.set()
            if self.block_running_write:
                if not self.allow_running_write.wait(timeout=5):
                    raise TimeoutError("RUNNING write was not released")

        with self.lock:
            old_status = self.meta[JobMetaKey.STATUS.value]
            self.meta[JobMetaKey.STATUS.value] = status_value
            self.history.append(f"{old_status}->{status_value}")
            if status == RunStatus.RUNNING:
                self.meta[JobMetaKey.START_TIME.value] = "repro-start"
                self.running_written.set()
            if status_value.startswith("FINISHED:"):
                self.terminal_written.set()

    def snapshot_meta(self):
        with self.lock:
            return dict(self.meta)


class FakeEngine:
    def __init__(self, job_manager: FakeJobManager, workspace: FakeWorkspace):
        self.job_def_manager = job_manager
        self.scheduler = FakeScheduler()
        self.workspace = workspace
        self.server = FakeServer()
        self.lock = threading.RLock()
        self.run_processes = {}
        self.exception_run_processes = {}
        self.client = Client(CLIENT_NAME, CLIENT_TOKEN)
        self.client_manager = type("ClientManager", (), {"clients": {CLIENT_TOKEN: self.client}})()
        self.events: list[str] = []

    def get_component(self, component_id):
        if component_id == SystemComponents.JOB_MANAGER:
            return self.job_def_manager
        if component_id == SystemComponents.JOB_SCHEDULER:
            return self.scheduler
        return None

    def get_clients(self):
        return [self.client]

    def get_job_clients(self, client_sites):
        return {CLIENT_TOKEN: self.client} if CLIENT_NAME in client_sites else {}

    def start_app_on_server(self, fl_ctx, job, job_clients, snapshot=None):
        with self.lock:
            self.run_processes[job.job_id] = {
                RunProcessKey.PARTICIPANTS: {},
                RunProcessKey.PROCESS_FINISHED: True,
            }
        return ""

    def start_client_job(self, job, client_sites, fl_ctx):
        request = Message(topic="start", body="")
        reply = Message(topic="reply", body="OK")
        reply.set_header(MsgHeader.RETURN_CODE, ReturnCode.OK)
        return [ClientReply(CLIENT_TOKEN, CLIENT_NAME, request, reply)]

    def validate_targets(self, client_sites):
        clients = [self.client for site in client_sites if site == CLIENT_NAME]
        invalid = [site for site in client_sites if site != CLIENT_NAME]
        return clients, invalid

    def fire_event(self, event_type, fl_ctx):
        self.events.append(event_type)

    def new_context(self):
        return FLContextManager(engine=self, identity_name=SiteType.SERVER).new_context()

    def get_workspace(self):
        return self.workspace

    def remove_exception_process(self, job_id):
        with self.lock:
            self.exception_run_processes.pop(job_id, None)


class MetaBackedSession(Session):
    def __init__(self, job_manager: FakeJobManager):
        self.job_manager = job_manager

    def get_job_meta(self, job_id: str) -> dict:
        return self.job_manager.snapshot_meta()


@dataclass
class CaseResult:
    name: str
    final_status: str
    history: list[str]
    monitor_code: MonitorReturnCode
    monitor_meta: dict | None


def wait_for(event: threading.Event, label: str, timeout: float = 8.0):
    if not event.wait(timeout=timeout):
        raise TimeoutError(f"timed out waiting for {label}")


def run_case(name: str, block_running_write: bool) -> CaseResult:
    with tempfile.TemporaryDirectory(prefix=f"mc4-{name}-") as tmp:
        Path(tmp, "startup").mkdir()
        Path(tmp, "local").mkdir()
        job_manager = FakeJobManager(block_running_write=block_running_write)
        engine = FakeEngine(job_manager, FakeWorkspace(Path(tmp)))
        runner = JobRunner(workspace_root=tmp)
        runner.client_outcome_wait_timeout = 0.05
        runner.scheduler = engine.scheduler
        fl_ctx = engine.new_context()
        thread = threading.Thread(target=runner.run, args=(fl_ctx,), name=f"job-runner-{name}")
        thread.start()

        try:
            wait_for(job_manager.running_write_entered, f"{name}: RUNNING write entered")
            if block_running_write:
                runner.resolve_client_outcome(JOB_ID, CLIENT_NAME)
                with engine.lock:
                    engine.run_processes.pop(JOB_ID, None)
                wait_for(job_manager.terminal_written, f"{name}: terminal write")
                job_manager.allow_running_write.set()
                wait_for(job_manager.running_written, f"{name}: delayed RUNNING write")
            else:
                wait_for(job_manager.running_written, f"{name}: ordinary RUNNING write")
                runner.resolve_client_outcome(JOB_ID, CLIENT_NAME)
                with engine.lock:
                    engine.run_processes.pop(JOB_ID, None)
                wait_for(job_manager.terminal_written, f"{name}: terminal write")

            # Allow JobRunner's completion bookkeeping to run.
            time.sleep(0.1)
            final_meta = job_manager.snapshot_meta()
            session = MetaBackedSession(job_manager)
            monitor_code, monitor_meta = Session.monitor_job_and_return_job_meta(
                session, JOB_ID, timeout=0.2, poll_interval=0.05
            )
            return CaseResult(
                name=name,
                final_status=final_meta[JobMetaKey.STATUS.value],
                history=list(job_manager.history),
                monitor_code=monitor_code,
                monitor_meta=monitor_meta,
            )
        finally:
            runner.stop()
            if block_running_write:
                job_manager.allow_running_write.set()
            thread.join(timeout=5)
            if thread.is_alive():
                raise TimeoutError(f"{name}: JobRunner thread did not stop")


def main() -> int:
    os.environ.pop("NVFLARE_LIFECYCLE_RAW", None)
    level0 = run_case("level0_no_delay", block_running_write=False)
    level1 = run_case("level1_delayed_running_store", block_running_write=True)

    print("MC-4 repro: delayed startup status write after terminal publication")
    for result in (level0, level1):
        monitor_status = result.monitor_meta.get(JobMetaKey.STATUS.value) if result.monitor_meta else None
        print(f"{result.name}.history={result.history}")
        print(f"{result.name}.final_status={result.final_status}")
        print(f"{result.name}.monitor_return={result.monitor_code.name}")
        print(f"{result.name}.monitor_meta_status={monitor_status}")

    expected_terminal = RunStatus.FINISHED_COMPLETED.value
    if level0.final_status != expected_terminal:
        print(f"FAIL: level0 expected {expected_terminal}, got {level0.final_status}")
        return 1
    if level0.monitor_code != MonitorReturnCode.JOB_FINISHED:
        print(f"FAIL: level0 monitor expected JOB_FINISHED, got {level0.monitor_code.name}")
        return 1
    if level1.history[-2:] != [
        f"{RunStatus.DISPATCHED.value}->{RunStatus.FINISHED_COMPLETED.value}",
        f"{RunStatus.FINISHED_COMPLETED.value}->{RunStatus.RUNNING.value}",
    ]:
        print("FAIL: level1 did not publish terminal status before the delayed RUNNING write")
        return 1
    if level1.final_status != RunStatus.RUNNING.value:
        print(f"FAIL: level1 expected resurrected RUNNING, got {level1.final_status}")
        return 1
    if level1.monitor_code != MonitorReturnCode.TIMEOUT:
        print(f"FAIL: level1 monitor expected TIMEOUT, got {level1.monitor_code.name}")
        return 1

    print("BUG_TRIGGERED: terminal FINISHED:COMPLETED was overwritten by RUNNING")
    print("OBSERVED_BY: nvflare/fuel/flare_api/flare_api.py:1674 monitor_job_and_return_job_meta")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
