#!/usr/bin/env python3
"""Reproduce MC-3: deployment can overwrite an acknowledged pre-run abort.

The harness uses JobRunner.run and JobCommandModule.abort_job.  The delayed
deploy reply is timing assistance: it holds the runner in the normal deploy
wait while the admin abort command takes the pre-run SUBMITTED branch.
"""

from __future__ import annotations

import sys
import threading
import time
from pathlib import Path


WORKTREE = Path(
    "/home/ubuntu/nvflare-job-lifecycle-20260914/specula/runs/"
    "nvflare-job-lifecycle-20260914/nvflare-job-lifecycle/"
    ".specula-output/confirmation/MC-3/worktree"
)
sys.path.insert(0, str(WORKTREE))

from nvflare.apis.client import Client
from nvflare.apis.fl_constant import FLContextKey, SystemComponents
from nvflare.apis.fl_context import FLContextManager
from nvflare.apis.job_def import Job, JobMetaKey, RunStatus
from nvflare.apis.job_def_manager_spec import JobDefManagerSpec
from nvflare.private.admin_defs import Message, MsgHeader, ReturnCode
from nvflare.private.defs import TrainingTopic
from nvflare.private.fed.server.job_cmds import JobCommandModule
from nvflare.private.fed.server.job_runner import JobRunner
from nvflare.private.fed.server.message_send import ClientReply
from nvflare.private.fed.server.server_state import HotState


JOB_ID = "job-mc3"


def ok_message(body: str = "ok") -> Message:
    msg = Message(topic="reply", body=body)
    msg.set_header(MsgHeader.RETURN_CODE, ReturnCode.OK)
    return msg


class InMemoryJobManager(JobDefManagerSpec):
    def __init__(self, job: Job):
        super().__init__()
        self.job = job
        self.lock = threading.Lock()
        self.status_writes: list[str] = [job.meta[JobMetaKey.STATUS.value]]

    def create(self, meta, uploaded_content, fl_ctx):
        raise NotImplementedError

    def clone(self, from_jid, meta, fl_ctx):
        raise NotImplementedError

    def get_job(self, jid, fl_ctx):
        assert jid == self.job.job_id
        return self.job

    def get_app(self, job, app_name, fl_ctx):
        return b"minimal app bytes"

    def get_content(self, meta, fl_ctx):
        return b""

    def update_meta(self, jid, meta, fl_ctx):
        assert jid == self.job.job_id
        with self.lock:
            self.job.meta.update(meta)

    def refresh_meta(self, job, meta_keys, fl_ctx):
        return None

    def set_client_data(self, jid, data, client_name, data_type, fl_ctx):
        return None

    def get_client_data(self, jid, client_name, data_type, fl_ctx):
        return None

    def list_components(self, jid, fl_ctx):
        return []

    def set_status(self, jid, status, fl_ctx):
        assert jid == self.job.job_id
        value = status.value if isinstance(status, RunStatus) else str(status)
        with self.lock:
            self.job.meta[JobMetaKey.STATUS.value] = value
            self.job.meta[JobMetaKey.STATUS] = value
            self.status_writes.append(value)

    def get_jobs_to_schedule(self, fl_ctx):
        return [self.job]

    def get_all_jobs(self, fl_ctx):
        return [self.job]

    def get_jobs_by_status(self, run_status, fl_ctx):
        statuses = run_status if isinstance(run_status, list) else [run_status]
        wanted = {s.value if isinstance(s, RunStatus) else str(s) for s in statuses}
        return [self.job] if self.job.meta.get(JobMetaKey.STATUS.value) in wanted else []

    def get_jobs_waiting_for_review(self, reviewer_name, fl_ctx):
        return []

    def set_approval(self, jid, reviewer_name, approved, note, fl_ctx):
        return {}

    def delete(self, jid, fl_ctx):
        return None

    def save_workspace(self, jid, data, fl_ctx):
        return "memory://workspace"

    def get_storage_component(self, jid, component, fl_ctx):
        return None

    def get_storage_for_download(self, jid, download_dir, component, download_file, fl_ctx):
        return None


class OneShotScheduler:
    def __init__(self, job: Job):
        self.job = job
        self.calls = 0
        self.called = threading.Event()

    def schedule_job(self, job_manager, job_candidates, fl_ctx):
        self.calls += 1
        self.called.set()
        if self.calls == 1:
            return self.job, {"site-1": object()}
        return None, {}

    def restore_scheduled_job(self, job_id):
        return None


class BlockingAdminServer:
    def __init__(self, deploy_entered: threading.Event | None, release_deploy: threading.Event | None):
        self.timeout = 10.0
        self.deploy_entered = deploy_entered
        self.release_deploy = release_deploy

    def send_requests_and_get_reply_dict(self, requests, timeout_secs=None):
        if self.deploy_entered is not None:
            self.deploy_entered.set()
        if self.release_deploy is not None and not self.release_deploy.wait(5.0):
            raise TimeoutError("abort did not complete while deployment was waiting")
        return {token: ok_message("deploy ok") for token in requests}


class Server:
    def __init__(self, admin_server):
        self.server_state = HotState()
        self.admin_server = admin_server


class Engine:
    def __init__(self, job_manager, scheduler, admin_server, client):
        self.job_def_manager = job_manager
        self.job_runner = None
        self.scheduler = scheduler
        self.server = Server(admin_server)
        self.client = client
        self.run_processes = {}
        self.exception_run_processes = {}
        self.ctx_mgr = FLContextManager(engine=self, identity_name="server")

    def new_context(self):
        return self.ctx_mgr.new_context()

    def get_component(self, component_id):
        if component_id == SystemComponents.JOB_MANAGER:
            return self.job_def_manager
        if component_id == SystemComponents.JOB_SCHEDULER:
            return self.scheduler
        return None

    def get_clients(self):
        return [self.client]

    def validate_targets(self, client_sites):
        valid = []
        invalid = []
        for name in client_sites:
            if name == self.client.name:
                valid.append(self.client)
            else:
                invalid.append(name)
        return valid, invalid

    def get_job_clients(self, client_sites):
        return {self.client.token: self.client} if self.client.name in client_sites else {}

    def start_app_on_server(self, fl_ctx, job, job_clients, snapshot=None):
        self.run_processes[job.job_id] = {"participants": job_clients}
        return ""

    def start_client_job(self, job, client_sites, fl_ctx):
        request = Message(topic=TrainingTopic.START, body="")
        return [ClientReply(self.client.token, self.client.name, request, ok_message("start ok"))]

    def fire_event(self, event_type, fl_ctx):
        return None

    def remove_exception_process(self, job_id):
        self.exception_run_processes.pop(job_id, None)


class Connection:
    def __init__(self, engine):
        self.app_ctx = engine
        self.props = {JobCommandModule.JOB_ID: JOB_ID}
        self.strings = []
        self.successes = []
        self.errors = []

    def get_prop(self, key, default=None):
        return self.props.get(key, default)

    def append_string(self, msg, meta=None):
        self.strings.append((msg, meta))

    def append_success(self, msg, meta=None):
        self.successes.append((msg, meta))

    def append_error(self, msg, meta=None):
        self.errors.append((msg, meta))


def make_job() -> Job:
    meta = {
        JobMetaKey.JOB_ID.value: JOB_ID,
        JobMetaKey.STATUS.value: RunStatus.SUBMITTED.value,
        JobMetaKey.SCHEDULE_COUNT.value: 1,
        JobMetaKey.LAST_SCHEDULE_TIME.value: "test-time",
        JobMetaKey.SCHEDULE_HISTORY.value: ["scheduled"],
        JobMetaKey.SUBMITTER_NAME.value: "tester",
        JobMetaKey.SUBMITTER_ORG.value: "org",
        JobMetaKey.SUBMITTER_ROLE.value: "project_admin",
    }
    return Job(
        job_id=JOB_ID,
        resource_spec={},
        deploy_map={"app": ["site-1"]},
        meta=meta,
        min_sites=1,
        required_sites=[],
    )


def quiet_runner() -> JobRunner:
    workspace_root = Path("/tmp/nvflare-mc3")
    workspace_root.mkdir(parents=True, exist_ok=True)
    (workspace_root / "startup").mkdir(parents=True, exist_ok=True)
    (workspace_root / "local").mkdir(parents=True, exist_ok=True)
    runner = JobRunner(workspace_root=str(workspace_root))
    runner.log_debug = lambda *args, **kwargs: None
    runner.log_info = lambda *args, **kwargs: None
    runner.log_warning = lambda *args, **kwargs: None
    runner.log_error = lambda *args, **kwargs: None
    runner.log_exception = lambda *args, **kwargs: None
    return runner


def abort_via_admin_command(engine: Engine) -> Connection:
    conn = Connection(engine)
    JobCommandModule().abort_job(conn, ["abort_job", JOB_ID])
    if conn.errors:
        raise AssertionError(f"abort_job returned errors: {conn.errors}")
    return conn


def run_level0_no_overlap() -> tuple[str, list[str], bool]:
    job = make_job()
    manager = InMemoryJobManager(job)
    scheduler = OneShotScheduler(job)
    client = Client("site-1", "token-1")
    engine = Engine(manager, scheduler, BlockingAdminServer(None, None), client)
    runner = quiet_runner()
    engine.job_runner = runner
    runner.scheduler = scheduler

    abort_via_admin_command(engine)
    fl_ctx = engine.new_context()
    thread = threading.Thread(target=runner.run, args=(fl_ctx,), daemon=True)
    thread.start()
    scheduler.called.wait(3.0)
    runner.stop()
    thread.join(3.0)
    if thread.is_alive():
        raise AssertionError("level 0 runner did not stop")
    status = job.meta[JobMetaKey.STATUS.value]
    return status, manager.status_writes, status not in (RunStatus.FINISHED_ABORTED.value,)


def run_level1_delayed_deploy_overlap() -> tuple[str, list[str], Connection]:
    job = make_job()
    manager = InMemoryJobManager(job)
    scheduler = OneShotScheduler(job)
    client = Client("site-1", "token-1")
    deploy_entered = threading.Event()
    release_deploy = threading.Event()
    engine = Engine(manager, scheduler, BlockingAdminServer(deploy_entered, release_deploy), client)
    runner = quiet_runner()
    engine.job_runner = runner
    runner.scheduler = scheduler

    fl_ctx = engine.new_context()
    thread = threading.Thread(target=runner.run, args=(fl_ctx,), daemon=True)
    thread.start()
    if not deploy_entered.wait(5.0):
        runner.stop()
        thread.join(3.0)
        raise AssertionError("runner did not reach deployment wait")

    conn = abort_via_admin_command(engine)
    release_deploy.set()

    deadline = time.time() + 5.0
    while time.time() < deadline:
        if RunStatus.RUNNING.value in manager.status_writes:
            break
        time.sleep(0.01)

    runner.stop()
    thread.join(3.0)
    if thread.is_alive():
        raise AssertionError("level 1 runner did not stop")

    status = job.meta[JobMetaKey.STATUS.value]
    return status, manager.status_writes, conn


def main() -> int:
    print(f"source_head=53ba7ee567468ea7971dad4faccef13c6cb35dc2")

    level0_status, level0_writes, level0_triggered = run_level0_no_overlap()
    print("Level 0 pure normal sequence:")
    print(f"  status_writes={level0_writes}")
    print(f"  final_status={level0_status}")
    print(f"  triggered={level0_triggered}")

    level1_status, level1_writes, conn = run_level1_delayed_deploy_overlap()
    abort_text = conn.strings[0][0] if conn.strings else ""
    abort_ok = bool(conn.successes) and not conn.errors
    print("Level 1 delayed deploy reply:")
    print(f"  abort_ok={abort_ok}")
    print(f"  abort_message={abort_text}")
    print(f"  status_writes={level1_writes}")
    print(f"  final_status={level1_status}")
    print(f"  started_after_abort={RunStatus.RUNNING.value in level1_writes}")

    bug_triggered = (
        abort_ok
        and RunStatus.FINISHED_ABORTED.value in level1_writes
        and RunStatus.DISPATCHED.value in level1_writes
        and RunStatus.RUNNING.value in level1_writes
    )
    if not bug_triggered:
        print("BUG_TRIGGERED=no")
        return 1

    print("BUG_TRIGGERED=yes")
    print(
        "Expected: once abort_job acknowledges a SUBMITTED pre-run abort, "
        "the job remains FINISHED:ABORTED and must not start."
    )
    print("Observed: JobRunner published DISPATCHED and RUNNING after the abort acknowledgement.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
