#!/usr/bin/env python3
"""Reproduce MC-12: stale delete authorization strands a running job slot."""

import json
import os
import shutil
import sys
import tempfile
import threading
import time
import zipfile
from pathlib import Path
from types import SimpleNamespace


SOURCE = Path(
    "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/"
    "nvflare-job/.specula-output/confirmation/MC-12/worktree"
)
sys.path.insert(0, str(SOURCE))

from nvflare.apis.client import Client
from nvflare.apis.event_type import EventType
from nvflare.apis.fl_constant import FLContextKey, RunProcessKey, SystemComponents
from nvflare.apis.fl_context import FLContextManager
from nvflare.apis.job_def import JobMetaKey
from nvflare.apis.job_def_manager_spec import RunStatus
from nvflare.apis.server_engine_spec import ServerEngineSpec
from nvflare.apis.storage import StorageException
from nvflare.apis.utils.event import fire_event_to_components
from nvflare.apis.workspace import Workspace
from nvflare.app_common.job_schedulers.job_scheduler import DefaultJobScheduler
from nvflare.app_common.storages.filesystem_storage import FilesystemStorage
from nvflare.apis.impl.job_def_manager import SimpleJobDefManager
from nvflare.fuel.hci.conn import Connection
from nvflare.fuel.hci.server.authz import PreAuthzReturnCode
from nvflare.fuel.hci.server.constants import ConnProps
from nvflare.private.admin_defs import Message
from nvflare.private.fed.server.job_cmds import JobCommandModule
from nvflare.private.fed.server.job_runner import JobRunner
from nvflare.private.fed.server.message_send import ClientReply
from nvflare.private.fed.server.server_state import HotState


J1 = "11111111-1111-4111-8111-111111111111"
J2 = "22222222-2222-4222-8222-222222222222"
CONTROL_JOB = "33333333-3333-4333-8333-333333333333"
CLIENT_NAME = "site-1"
CLIENT_TOKEN = "token-1"


class FakeAdminServer:
    timeout = 0.2

    def __init__(self, ctx_manager):
        self.sai = SimpleNamespace(new_context=ctx_manager.new_context)

    def send_requests_and_get_reply_dict(self, requests, timeout_secs=2.0):
        return {token: Message(topic="deploy_reply", body="OK") for token in requests}


class FakeWorkspace:
    """Workspace view with no archive sources, so completion reaches set_status."""

    def __init__(self, root):
        self.root = Path(root)

    def get_run_dir(self, job_id):
        return str(self.root / "absent-run" / job_id)

    def get_result_root(self, job_id):
        return str(self.root / "absent-result" / job_id)

    def get_log_root(self, job_id):
        return str(self.root / "absent-log" / job_id)

    def get_audit_root(self, job_id):
        return str(self.root / "absent-audit" / job_id)


class FakeEngine:
    def __init__(self, root, job_manager, storage, scheduler):
        self.root = Path(root)
        self.job_def_manager = job_manager
        self.components = {
            "job_store": storage,
            SystemComponents.JOB_MANAGER: job_manager,
            SystemComponents.JOB_SCHEDULER: scheduler,
        }
        self.ctx_manager = FLContextManager(engine=self, identity_name="server", job_id="server")
        self.client = Client(name=CLIENT_NAME, token=CLIENT_TOKEN)
        self.client_manager = SimpleNamespace(clients={CLIENT_TOKEN: self.client})
        self.server = SimpleNamespace(server_state=HotState(), admin_server=FakeAdminServer(self.ctx_manager))
        self.run_processes = {}
        self.exception_run_processes = {}
        self.lock = threading.Lock()
        self.scheduler = scheduler
        self.events = []
        self.started_jobs = []

    def fire_event(self, event_type, fl_ctx):
        event_data = fl_ctx.get_prop(FLContextKey.EVENT_DATA, None)
        job_id = event_data.get(JobMetaKey.JOB_ID.value) if isinstance(event_data, dict) else None
        self.events.append((event_type, job_id))
        fire_event_to_components(event_type, [self.scheduler], fl_ctx)

    def get_clients(self):
        return [self.client]

    def sync_clients_from_main_process(self):
        return None

    def validate_targets(self, client_names):
        clients = []
        invalid = []
        for name in client_names:
            if name == CLIENT_NAME:
                clients.append(self.client)
            else:
                invalid.append(name)
        return clients, invalid

    def new_context(self):
        return self.ctx_manager.new_context()

    def get_workspace(self):
        return FakeWorkspace(self.root / "completion-workspace")

    def add_component(self, component_id, component):
        self.components[component_id] = component

    def get_component(self, component_id):
        return self.components.get(component_id)

    def register_aux_message_handler(self, topic, message_handle_func):
        return None

    def send_aux_request(self, targets, topic, request, timeout, fl_ctx, optional=False, secure=False):
        return {}

    def update_job_run_status(self):
        return None

    def get_job_clients(self, client_sites):
        return {CLIENT_TOKEN: self.client}

    def check_client_resources(self, job, resource_reqs, fl_ctx):
        return {site_name: (True, None) for site_name in resource_reqs}

    def cancel_client_resources(self, resource_check_results, resource_reqs, fl_ctx):
        return None

    def start_app_on_server(self, fl_ctx, job=None, job_clients=None, snapshot=None):
        with self.lock:
            self.run_processes[job.job_id] = {
                RunProcessKey.PARTICIPANTS: job_clients or {},
                RunProcessKey.PROCESS_FINISHED: False,
            }
        self.started_jobs.append(job.job_id)
        return ""

    def start_client_job(self, job, client_sites, fl_ctx):
        reply = Message(topic="start_reply", body="OK")
        return [ClientReply(CLIENT_TOKEN, CLIENT_NAME, None, reply)]

    def finish_server_process(self, job_id):
        with self.lock:
            self.run_processes.pop(job_id, None)

    def remove_exception_process(self, job_id):
        with self.lock:
            self.exception_run_processes.pop(job_id, None)


ServerEngineSpec.register(FakeEngine)


def make_workspace_root(root):
    workspace_root = Path(root) / "server-workspace"
    (workspace_root / "startup").mkdir(parents=True, exist_ok=True)
    (workspace_root / "local").mkdir(parents=True, exist_ok=True)
    return workspace_root


def make_job_zip(root, folder_name):
    job_root = Path(root) / folder_name
    app_dir = job_root / "app"
    app_dir.mkdir(parents=True, exist_ok=True)
    (app_dir / "placeholder.txt").write_text("minimal app payload\n", encoding="utf-8")
    zip_path = Path(root) / f"{folder_name}.zip"
    with zipfile.ZipFile(zip_path, "w") as zf:
        for path in sorted(job_root.rglob("*")):
            zf.write(path, path.relative_to(root))
    return zip_path.read_bytes()


def create_job(job_manager, engine, job_id, folder_name):
    payload = make_job_zip(engine.root, folder_name)
    meta = {
        JobMetaKey.JOB_ID.value: job_id,
        JobMetaKey.JOB_NAME.value: folder_name,
        JobMetaKey.JOB_FOLDER_NAME.value: folder_name,
        JobMetaKey.DEPLOY_MAP.value: {"app": ["server", CLIENT_NAME]},
        JobMetaKey.RESOURCE_SPEC.value: {},
        JobMetaKey.MIN_CLIENTS.value: 1,
        JobMetaKey.MANDATORY_CLIENTS.value: [],
        JobMetaKey.SUBMITTER_NAME.value: "alice",
        JobMetaKey.SUBMITTER_ORG.value: "org",
        JobMetaKey.SUBMITTER_ROLE.value: "project_admin",
    }
    with engine.new_context() as fl_ctx:
        return job_manager.create(meta, payload, fl_ctx)


def wait_for(label, predicate, timeout=12.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return
        time.sleep(0.1)
    raise AssertionError(f"timed out waiting for {label}")


def status_of(job_manager, engine, job_id):
    with engine.new_context() as fl_ctx:
        job = job_manager.get_job(job_id, fl_ctx)
    return None if job is None else job.meta.get(JobMetaKey.STATUS.value)


def control_fresh_running_delete_is_rejected():
    root = Path(tempfile.mkdtemp(prefix="mc12-control-"))
    try:
        storage = FilesystemStorage(root_dir=str(root / "store"), uri_root="/")
        job_manager = SimpleJobDefManager(uri_root="jobs")
        scheduler = DefaultJobScheduler(max_jobs=1, min_schedule_interval=0)
        engine = FakeEngine(root=root, job_manager=job_manager, storage=storage, scheduler=scheduler)
        create_job(job_manager, engine, CONTROL_JOB, "control_job")
        with engine.new_context() as fl_ctx:
            job_manager.set_status(CONTROL_JOB, RunStatus.RUNNING, fl_ctx)

        cmd = JobCommandModule()
        conn = Connection(
            app_ctx=engine,
            props={
                ConnProps.USER_NAME: "alice",
                ConnProps.USER_ORG: "org",
                ConnProps.USER_ROLE: "project_admin",
            },
        )
        auth_rc = cmd.authorize_job(conn, ["delete_job", CONTROL_JOB])
        assert auth_rc == PreAuthzReturnCode.REQUIRE_AUTHZ, auth_rc
        cmd.delete_job(conn, ["delete_job", CONTROL_JOB])
        response = conn.close()
        assert status_of(job_manager, engine, CONTROL_JOB) == RunStatus.RUNNING.value
        assert '"status": "job_running"' in response, response
        return response
    finally:
        shutil.rmtree(root, ignore_errors=True)


def main():
    assert Path(__import__("nvflare").__file__).resolve().is_relative_to(SOURCE)
    control_response = control_fresh_running_delete_is_rejected()
    root = Path(tempfile.mkdtemp(prefix="mc12-repro-"))
    try:
        storage = FilesystemStorage(root_dir=str(root / "store"), uri_root="/")
        job_manager = SimpleJobDefManager(uri_root="jobs")
        scheduler = DefaultJobScheduler(max_jobs=1, min_schedule_interval=0)
        engine = FakeEngine(root=root, job_manager=job_manager, storage=storage, scheduler=scheduler)
        runner = JobRunner(workspace_root=str(make_workspace_root(root)))
        runner.log_info = lambda *args, **kwargs: None
        runner.log_debug = lambda *args, **kwargs: None
        runner.log_warning = lambda *args, **kwargs: None
        runner.log_error = lambda *args, **kwargs: None
        completion_errors = []
        runner.log_exception = lambda _ctx, msg: completion_errors.append(msg)

        create_job(job_manager, engine, J1, "job_one")
        time.sleep(0.02)
        create_job(job_manager, engine, J2, "job_two")

        cmd = JobCommandModule()
        conn = Connection(
            app_ctx=engine,
            props={
                ConnProps.USER_NAME: "alice",
                ConnProps.USER_ORG: "org",
                ConnProps.USER_ROLE: "project_admin",
            },
        )
        auth_rc = cmd.authorize_job(conn, ["delete_job", J1])
        assert auth_rc == PreAuthzReturnCode.REQUIRE_AUTHZ, auth_rc
        cached_job = conn.get_prop(cmd.JOB)
        assert cached_job.meta[JobMetaKey.STATUS.value] == RunStatus.SUBMITTED.value

        with engine.new_context() as fl_ctx:
            runner.handle_event(EventType.SYSTEM_START, fl_ctx)
            runner_thread = threading.Thread(target=runner.run, args=(fl_ctx,), daemon=True)
            runner_thread.start()

        wait_for("j1 to reach RUNNING", lambda: status_of(job_manager, engine, J1) == RunStatus.RUNNING.value)
        wait_for("j1 scheduled slot", lambda: J1 in scheduler.scheduled_jobs)
        wait_for("j1 running map", lambda: J1 in runner.running_jobs)

        status_before_delete = status_of(job_manager, engine, J1)
        cmd.delete_job(conn, ["delete_job", J1])
        delete_response = conn.close()
        status_after_delete = status_of(job_manager, engine, J1)
        assert status_before_delete == RunStatus.RUNNING.value
        assert status_after_delete is None

        runner.resolve_client_outcome(J1, CLIENT_NAME)
        engine.finish_server_process(J1)

        wait_for(
            "completion retry after deleted store object",
            lambda: bool(completion_errors) and J1 in runner.running_jobs,
            timeout=8.0,
        )
        time.sleep(2.2)

        j2_status = status_of(job_manager, engine, J2)
        completed_events = [e for e in engine.events if e == (EventType.JOB_COMPLETED, J1)]
        aborted_events = [e for e in engine.events if e == (EventType.JOB_ABORTED, J1)]

        assert J1 in runner.running_jobs
        assert J1 in scheduler.scheduled_jobs
        assert j2_status == RunStatus.SUBMITTED.value
        assert J2 not in engine.started_jobs
        assert not completed_events
        assert not aborted_events

        runner.ask_to_stop = True
        runner_thread.join(timeout=5)
        assert not runner_thread.is_alive()

        print("MC-12 reproduction: REPRODUCED")
        print(f"control_fresh_running_delete_response={control_response}")
        print(f"auth_snapshot_status={cached_job.meta[JobMetaKey.STATUS.value]}")
        print(f"status_before_delete={status_before_delete}")
        print(f"delete_response={delete_response}")
        print(f"status_after_delete={status_after_delete}")
        print(f"completion_error_count={len(completion_errors)}")
        print(f"first_completion_error={completion_errors[0]}")
        print(f"runner_running_jobs={sorted(runner.running_jobs.keys())}")
        print(f"scheduler_scheduled_jobs={list(scheduler.scheduled_jobs)}")
        print(f"j2_status={j2_status}")
        print(f"started_jobs={list(engine.started_jobs)}")
        print(f"job_completed_events_for_j1={completed_events}")
        print(f"job_aborted_events_for_j1={aborted_events}")
    finally:
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    main()
