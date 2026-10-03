#!/usr/bin/env python3
"""Reproduce MC-6: JobRunner completion thread dies on a blind running_jobs delete.

This is a component-level race repro against the pinned NVFlare source.  It uses
real JobRunner.run/_start_run/_job_complete_process, the real admin delete_job
handler, and DefaultJobScheduler.handle_event for slot accounting.  The fakes
only stand in for the network/process/storage edges so the interleaving is
deterministic.
"""

from __future__ import annotations

import copy
import os
import sys
import tempfile
import threading
import time
import traceback
from types import SimpleNamespace


SOURCE = (
    "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/"
    "nvflare-job/.specula-output/confirmation/MC-6/worktree"
)
sys.path.insert(0, SOURCE)

from nvflare.apis.client import Client  # noqa: E402
from nvflare.apis.event_type import EventType  # noqa: E402
from nvflare.apis.fl_constant import FLContextKey, RunProcessKey, SystemComponents  # noqa: E402
from nvflare.apis.fl_context import FLContextManager  # noqa: E402
from nvflare.apis.job_def import JobMetaKey, RunStatus, job_from_meta  # noqa: E402
from nvflare.apis.job_scheduler_spec import DispatchInfo  # noqa: E402
from nvflare.apis.storage import StorageException  # noqa: E402
from nvflare.app_common.job_schedulers.job_scheduler import DefaultJobScheduler  # noqa: E402
from nvflare.private.admin_defs import Message, ok_reply  # noqa: E402
from nvflare.private.fed.server.job_cmds import JobCommandModule  # noqa: E402
from nvflare.private.fed.server.job_runner import JobRunner  # noqa: E402
from nvflare.private.fed.server.message_send import ClientReply  # noqa: E402
from nvflare.private.fed.server.server_state import HotState  # noqa: E402


JOB_ID = "job-mc6"
CLIENT_NAME = "site-1"
CLIENT_TOKEN = "tok-site-1"


class ScriptedScheduler(DefaultJobScheduler):
    def __init__(self):
        super().__init__(max_jobs=1, min_schedule_interval=0.0)
        self._returned = False

    def schedule_job(self, job_manager, job_candidates, fl_ctx):
        if self._returned or not job_candidates:
            return None, None
        self._returned = True
        return job_candidates[0], {
            "server": DispatchInfo("app", {}, None),
            CLIENT_NAME: DispatchInfo("app", {}, CLIENT_TOKEN),
        }


class FakeConn:
    def __init__(self, engine, job):
        self.app_ctx = engine
        self._props = {
            JobCommandModule.JOB: job,
            JobCommandModule.JOB_ID: job.job_id,
        }
        self.out = []

    def get_prop(self, key, default=None):
        return self._props.get(key, default)

    def set_prop(self, key, value):
        self._props[key] = value

    def append_string(self, s, meta=None):
        self.out.append(("string", s, meta))

    def append_success(self, s, meta=None):
        self.out.append(("success", s, meta))

    def append_error(self, s, meta=None):
        self.out.append(("error", s, meta))


class FakeJobManager:
    def __init__(self):
        self.meta = {
            JobMetaKey.JOB_ID.value: JOB_ID,
            JobMetaKey.JOB_NAME.value: "mc6",
            JobMetaKey.STATUS.value: RunStatus.SUBMITTED.value,
            JobMetaKey.DEPLOY_MAP.value: {"app": ["server", CLIENT_NAME]},
            JobMetaKey.RESOURCE_SPEC.value: {},
            JobMetaKey.MIN_CLIENTS.value: 1,
            JobMetaKey.SCHEDULE_COUNT.value: 1,
            JobMetaKey.LAST_SCHEDULE_TIME.value: time.time(),
            JobMetaKey.SCHEDULE_HISTORY.value: [],
            JobMetaKey.SUBMIT_TIME.value: time.time(),
        }
        self.deleted = False
        self.engine = None
        self.runner = None
        self.trace = []
        self.terminal_published = threading.Event()
        self.runner_cleanup_done = threading.Event()
        self.delete_done = threading.Event()

    def _job(self):
        if self.deleted:
            return None
        return job_from_meta(copy.deepcopy(self.meta))

    def get_jobs_to_schedule(self, fl_ctx):
        job = self._job()
        if job and self.meta.get(JobMetaKey.STATUS.value) == RunStatus.SUBMITTED.value:
            return [job]
        return []

    def get_job(self, jid, fl_ctx=None):
        if jid != JOB_ID:
            return None
        return self._job()

    def set_status(self, jid, status, fl_ctx):
        if jid != JOB_ID:
            raise StorageException(f"unknown job {jid}")

        if status == RunStatus.RUNNING:
            self.trace.append("runner: entered late set_status(RUNNING)")
            # Normal process completion and the client outcome both happen while
            # the runner is between running_jobs insertion and the RUNNING write.
            with self.engine.lock:
                self.engine.run_processes.pop(jid, None)
            self.runner.resolve_client_outcome(jid, CLIENT_NAME)
            self.trace.append("process/client: job finished before RUNNING write returned")

            if not self.terminal_published.wait(10):
                raise AssertionError("completion thread did not publish terminal status")

            snapshot = self.get_job(jid, fl_ctx)
            conn = FakeConn(self.engine, snapshot)
            JobCommandModule().delete_job(conn, ["delete_job", jid])
            self.trace.append(f"admin: delete_job reply={conn.out}")
            self.delete_done.set()

            raise StorageException("object jobs/job-mc6 does not exist after admin delete")

        if status == RunStatus.FAILED_TO_RUN:
            self.trace.append("runner: set_status(FAILED_TO_RUN) reached after delete")
            raise StorageException("object jobs/job-mc6 does not exist after admin delete")

        if self.deleted:
            raise StorageException("object jobs/job-mc6 does not exist")

        self.meta[JobMetaKey.STATUS.value] = status.value
        self.trace.append(f"{threading.current_thread().name}: set_status({status.value})")

        if status.value.startswith("FINISHED:"):
            self.terminal_published.set()
            if not self.runner_cleanup_done.wait(10):
                raise AssertionError("runner cleanup did not remove running_jobs")

    def update_meta(self, jid, meta, fl_ctx):
        if self.deleted:
            raise StorageException("object jobs/job-mc6 does not exist")
        self.meta.update(meta)

    def delete(self, jid, fl_ctx):
        if jid != JOB_ID or self.deleted:
            raise StorageException("object jobs/job-mc6 does not exist")
        self.deleted = True
        self.trace.append("job store: deleted job object")

    def mark_submit_records_job_deleted(self, job_id, deleted_by, fl_ctx):
        return []


class FakeEngine:
    def __init__(self, job_manager, scheduler):
        self.job_manager = job_manager
        self.job_def_manager = job_manager
        self.scheduler = scheduler
        self.lock = threading.Lock()
        self.run_processes = {}
        self.exception_run_processes = {}
        self.client = Client(CLIENT_NAME, CLIENT_TOKEN)
        self.client_manager = SimpleNamespace(clients={CLIENT_TOKEN: self.client})
        self.server = SimpleNamespace(server_state=HotState(), admin_server=None)
        self.ctx_mgr = FLContextManager(engine=self, identity_name="server", job_id="")
        self.events = []

    def get_component(self, component_id):
        if component_id == SystemComponents.JOB_MANAGER:
            return self.job_manager
        return None

    def get_clients(self):
        return [self.client]

    def new_context(self):
        return self.ctx_mgr.new_context()

    def fire_event(self, event_type, fl_ctx):
        data = fl_ctx.get_prop(FLContextKey.EVENT_DATA) or {}
        job_id = data.get(JobMetaKey.JOB_ID.value)
        self.events.append((event_type, job_id))
        self.scheduler.handle_event(event_type, fl_ctx)

    def get_job_clients(self, client_sites):
        return {CLIENT_TOKEN: self.client}

    def start_app_on_server(self, fl_ctx, job=None, job_clients=None):
        with self.lock:
            self.run_processes[job.job_id] = {
                RunProcessKey.JOB_ID: job.job_id,
                RunProcessKey.PARTICIPANTS: job_clients or {},
            }
        return ""

    def start_client_job(self, job, client_sites, fl_ctx):
        req = Message(topic="start_job", body="")
        return [ClientReply(CLIENT_TOKEN, CLIENT_NAME, req, ok_reply(body="Start the client app."))]

    def remove_exception_process(self, job_id):
        with self.lock:
            self.exception_run_processes.pop(job_id, None)


def main():
    assert os.path.realpath(__import__("nvflare").__file__).startswith(SOURCE)

    old_hook = threading.excepthook
    thread_errors = []

    def hook(args):
        thread_errors.append(
            {
                "thread": args.thread.name,
                "type": args.exc_type.__name__,
                "message": str(args.exc_value),
                "traceback": "".join(
                    traceback.format_exception(args.exc_type, args.exc_value, args.exc_traceback)
                ),
            }
        )
        old_hook(args)

    threading.excepthook = hook

    scheduler = ScriptedScheduler()
    job_manager = FakeJobManager()
    engine = FakeEngine(job_manager, scheduler)
    runner = JobRunner(workspace_root=tempfile.mkdtemp(prefix="mc6-workspace-"))
    runner.scheduler = scheduler
    runner._deploy_job = lambda job, sites, fl_ctx: (job.job_id, [])
    runner._save_workspace = lambda fl_ctx, finished_state, job_id: None

    def stop_run(job_id, fl_ctx):
        job_manager.trace.append("runner: exception cleanup removed running_jobs before completion remove")
        job_manager.runner_cleanup_done.set()

    runner._stop_run = stop_run
    job_manager.engine = engine
    job_manager.runner = runner

    result = {}

    def run_target():
        try:
            with engine.new_context() as ctx:
                runner.run(ctx)
        except BaseException as e:
            result["runner_exception"] = f"{type(e).__name__}: {e}"

    run_thread = threading.Thread(target=run_target, name="JobRunner.run")
    run_thread.start()

    deadline = time.time() + 20
    while time.time() < deadline:
        if thread_errors and job_manager.delete_done.is_set():
            break
        time.sleep(0.05)

    runner.ask_to_stop = True
    run_thread.join(timeout=5)
    threading.excepthook = old_hook

    completion_keyerror = any(
        e["type"] == "KeyError" and "_job_complete_process" in e["traceback"] for e in thread_errors
    )
    completed_events = [e for e in engine.events if e[0] == EventType.JOB_COMPLETED]
    aborted_events = [e for e in engine.events if e[0] == EventType.JOB_ABORTED]
    started_events = [e for e in engine.events if e[0] == EventType.JOB_STARTED]

    print("=== MC-6 reproduction output ===")
    for item in job_manager.trace:
        print(item)
    print(f"thread_errors={[(e['thread'], e['type'], e['message']) for e in thread_errors]}")
    print(f"runner_exception={result.get('runner_exception')}")
    print(f"events={engine.events}")
    print(f"scheduled_jobs={scheduler.scheduled_jobs}")
    print(f"running_jobs={list(runner.running_jobs)}")
    print(f"job_deleted={job_manager.deleted}")
    print(f"completion_keyerror={completion_keyerror}")
    print(f"started_events={started_events}")
    print(f"completed_events={completed_events}")
    print(f"aborted_events={aborted_events}")

    if not completion_keyerror:
        print("FAIL: completion thread did not die with KeyError")
        return 1
    if not started_events or completed_events or aborted_events:
        print("FAIL: lifecycle event consequence was not the expected STARTED-without-end-event state")
        return 1
    if JOB_ID not in scheduler.scheduled_jobs:
        print("FAIL: DefaultJobScheduler slot was released, so the live consequence was not reproduced")
        return 1

    print("PASS: reproduced completion thread KeyError and unreleased scheduler slot")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
