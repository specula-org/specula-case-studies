#!/usr/bin/env python3
"""CR-5 reproduction: startup failure cleanup can leave scheduler accounting stale.

This is a focused component-level reproduction. It drives JobRunner.run(), lets
_start_run emit JOB_STARTED normally, then injects a per-job status-store
failure on both RUNNING and FAILED_TO_RUN writes. The failed FAILED_TO_RUN write
is reachable because SimpleJobDefManager.set_status delegates to storage without
catching storage-layer update failures.
"""

from __future__ import annotations

import os
import sys
import threading
import time as real_time
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


WORKTREE = Path(
    os.environ.get(
        "NVFLARE_WORKTREE",
        "/home/ubuntu/nvflare-job-lifecycle-20260914/specula/runs/"
        "nvflare-job-lifecycle-20260914/nvflare-job-lifecycle/.specula-output/"
        "confirmation/CR-5/worktree",
    )
)
sys.path.insert(0, str(WORKTREE))

from nvflare.apis.client import Client
from nvflare.apis.event_type import EventType
from nvflare.apis.fl_context import FLContext, FLContextManager
from nvflare.apis.job_def import SERVER_SITE_NAME, Job, JobMetaKey, RunStatus
from nvflare.apis.job_scheduler_spec import DispatchInfo
from nvflare.apis.server_engine_spec import ServerEngineSpec
from nvflare.apis.workspace import Workspace
from nvflare.apis.fl_constant import RunProcessKey, SystemComponents
from nvflare.app_common.job_schedulers.job_scheduler import DefaultJobScheduler
from nvflare.private.admin_defs import Message, ok_reply
from nvflare.private.defs import TrainingTopic
from nvflare.private.fed.server import job_runner as job_runner_mod
from nvflare.private.fed.server.job_runner import JobRunner
from nvflare.private.fed.server.message_send import ClientReply
from nvflare.private.fed.server.server_state import HotState


class ControlledStoreFailure(RuntimeError):
    pass


def make_job(job_id: str, status: RunStatus = RunStatus.SUBMITTED) -> Job:
    meta = {
        JobMetaKey.JOB_ID: job_id,
        JobMetaKey.JOB_ID.value: job_id,
        JobMetaKey.STATUS: status,
        JobMetaKey.STATUS.value: status.value,
        JobMetaKey.SUBMIT_TIME.value: 0.0,
        JobMetaKey.JOB_NAME.value: job_id,
    }
    return Job(
        job_id=job_id,
        resource_spec={},
        deploy_map={"app": [SERVER_SITE_NAME, "site-1"]},
        min_sites=1,
        required_sites=[],
        meta=meta,
    )


class StatusFailingJobManager:
    def __init__(self, runner: JobRunner, jobs: list[Job]):
        self.runner = runner
        self.jobs = {j.job_id: j for j in jobs}
        self.set_status_calls = []
        self.update_meta_calls = []

    def get_jobs_to_schedule(self, fl_ctx: FLContext):
        return list(self.jobs.values())

    def get_job(self, jid: str, fl_ctx: FLContext):
        return self.jobs[jid]

    def set_status(self, jid: str, status: RunStatus, fl_ctx: FLContext):
        self.set_status_calls.append((jid, status.value))
        self.jobs[jid].meta[JobMetaKey.STATUS] = status
        self.jobs[jid].meta[JobMetaKey.STATUS.value] = status.value
        if jid == "job-1" and status in (RunStatus.RUNNING, RunStatus.FAILED_TO_RUN):
            self.runner.ask_to_stop = True
            raise ControlledStoreFailure(f"controlled per-job status-store failure for {jid} -> {status.value}")

    def update_meta(self, jid: str, meta: dict, fl_ctx: FLContext):
        self.update_meta_calls.append((jid, dict(meta)))
        self.jobs[jid].meta.update(meta)

    def refresh_meta(self, job: Job, meta_keys: list, fl_ctx: FLContext):
        pass

    def save_workspace(self, jid: str, data, fl_ctx: FLContext):
        return f"/tmp/{jid}.zip"


class ManualFirstAdmissionScheduler(DefaultJobScheduler):
    def __init__(self, job: Job):
        super().__init__(max_jobs=1, min_schedule_interval=0.0, max_schedule_interval=0.0)
        self.job = job
        self.manual_admissions = 0

    def schedule_job(self, job_manager, job_candidates, fl_ctx):
        if self.manual_admissions == 0:
            self.manual_admissions += 1
            return self.job, {
                SERVER_SITE_NAME: DispatchInfo("app", {}, None),
                "site-1": DispatchInfo("app", {}, "reserved-token"),
            }
        return super().schedule_job(job_manager, job_candidates, fl_ctx)


class HarnessEngine(ServerEngineSpec):
    def __init__(self, scheduler, job_manager):
        self.scheduler = scheduler
        self.job_manager = job_manager
        self.client = Client(name="site-1", token="token-1")
        self.lock = threading.Lock()
        self.run_processes = {}
        self.exception_run_processes = {}
        self.server = SimpleNamespace(server_state=HotState(), admin_server=SimpleNamespace(timeout=1.0))
        self.client_manager = SimpleNamespace(clients={self.client.token: self.client})
        self.events = []
        self.fl_ctx_mgr = FLContextManager(
            engine=self,
            identity_name=SERVER_SITE_NAME,
            job_id="server",
            public_stickers={},
            private_stickers={},
        )
        self.server.admin_server.sai = SimpleNamespace(new_context=self.new_context)
        self.server.admin_server.send_requests = lambda requests, fl_ctx, timeout_secs=None, optional=False: []

    def validate_targets(self, target_names: list[str]):
        valid = [self.client for name in target_names if name == self.client.name]
        invalid = [name for name in target_names if name != self.client.name]
        return valid, invalid

    def fire_event(self, event_type: str, fl_ctx: FLContext):
        self.events.append(event_type)
        self.scheduler.handle_event(event_type, fl_ctx)

    def get_clients(self):
        return [self.client]

    def sync_clients_from_main_process(self):
        pass

    def update_job_run_status(self):
        pass

    def new_context(self):
        return self.fl_ctx_mgr.new_context()

    def get_workspace(self):
        return Workspace(root_dir="/tmp/cr5-workspace", site_name=SERVER_SITE_NAME)

    def add_component(self, component_id: str, component):
        pass

    def get_component(self, component_id: str):
        if component_id == SystemComponents.JOB_MANAGER:
            return self.job_manager
        if component_id == SystemComponents.JOB_SCHEDULER:
            return self.scheduler
        return None

    def register_aux_message_handler(self, topic: str, message_handle_func):
        pass

    def send_aux_request(self, targets, topic: str, request, timeout: float, fl_ctx: FLContext, optional=False, secure=False):
        return {}

    def multicast_aux_requests(
        self, topic: str, target_requests, timeout: float, fl_ctx: FLContext, optional: bool = False, secure: bool = False
    ):
        return {}

    def get_widget(self, widget_id: str):
        return None

    def persist_components(self, fl_ctx: FLContext, completed: bool):
        pass

    def restore_components(self, snapshot, fl_ctx: FLContext):
        pass

    def start_client_job(self, job, client_sites, fl_ctx: FLContext):
        req = Message(topic=TrainingTopic.START_JOB, body="")
        return [ClientReply(self.client.token, self.client.name, req, ok_reply())]

    def check_client_resources(self, job: Job, resource_reqs: dict[str, dict], fl_ctx: FLContext):
        return {site_name: (True, f"token-{job.job_id}-{site_name}") for site_name in resource_reqs}

    def cancel_client_resources(self, resource_check_results, resource_reqs, fl_ctx: FLContext):
        pass

    def get_client_name_from_token(self, token: str):
        return self.client.name if token == self.client.token else None

    def get_job_clients(self, client_sites):
        return {self.client.token: self.client}

    def start_app_on_server(self, fl_ctx: FLContext, job: Job = None, job_clients=None, snapshot=None):
        with self.lock:
            self.run_processes[job.job_id] = {
                RunProcessKey.JOB_ID: job.job_id,
                RunProcessKey.PARTICIPANTS: job_clients or {},
            }
        return ""

    def abort_app_on_server(self, job_id: str):
        with self.lock:
            self.run_processes.pop(job_id, None)
        return ""

    def remove_exception_process(self, job_id: str):
        self.exception_run_processes.pop(job_id, None)


def main():
    job1 = make_job("job-1")
    job2 = make_job("job-2")
    runner = JobRunner(workspace_root="/tmp/cr5-workspace")
    scheduler = ManualFirstAdmissionScheduler(job1)
    job_manager = StatusFailingJobManager(runner, [job1, job2])
    engine = HarnessEngine(scheduler, job_manager)
    runner.scheduler = scheduler
    runner._deploy_job = lambda ready_job, sites, fl_ctx: (ready_job.job_id, [])

    original_sleep = real_time.sleep

    def fast_sleep(_seconds):
        original_sleep(0)

    with engine.new_context() as fl_ctx:
        escaped = None
        with patch.object(job_runner_mod.time, "sleep", side_effect=fast_sleep):
            try:
                runner.run(fl_ctx)
            except ControlledStoreFailure as e:
                escaped = e

        original_sleep(0.05)
        stale_before = list(scheduler.scheduled_jobs)
        blocked_job, blocked_dispatch = DefaultJobScheduler.schedule_job(scheduler, job_manager, [job2], fl_ctx)
        scheduler.scheduled_jobs.clear()
        admitted_job, admitted_dispatch = DefaultJobScheduler.schedule_job(scheduler, job_manager, [job2], fl_ctx)

    print("CR-5 startup failure escape reproduction")
    print(f"escaped_exception={type(escaped).__name__}: {escaped}")
    print(f"events={[e for e in engine.events if e in (EventType.JOB_STARTED, EventType.JOB_ABORTED, EventType.JOB_COMPLETED)]}")
    print(f"status_calls={job_manager.set_status_calls}")
    print(f"stale_scheduled_jobs_after_escape={stale_before}")
    print(f"later_candidate_with_stale_accounting={blocked_job}")
    print(f"later_candidate_after_clearing_mask={admitted_job.job_id if admitted_job else None}")
    print(f"dispatch_after_clearing_mask={sorted(admitted_dispatch) if admitted_dispatch else None}")

    assert escaped is not None, "runner.run() should leak the failure-handler status-store exception"
    assert EventType.JOB_STARTED in engine.events, "startup must have reached the normal JOB_STARTED event"
    assert EventType.JOB_ABORTED not in engine.events, "failure handler escaped before JOB_ABORTED cleanup"
    assert stale_before == ["job-1"], stale_before
    assert blocked_job is None and blocked_dispatch is None, "stale scheduled_jobs should block later admission"
    assert admitted_job is job2, "job-2 should be admissible once stale accounting is cleared"
    print("RESULT=REPRODUCED")


if __name__ == "__main__":
    main()
