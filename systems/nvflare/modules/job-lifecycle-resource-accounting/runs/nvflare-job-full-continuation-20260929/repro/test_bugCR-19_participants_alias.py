#!/usr/bin/env python3
"""Reproduce CR-19: empty job_clients aliases the live client registry.

This is a focused NVFlare bookkeeping test.  It uses the real ServerEngine
start path and the real FedServer dead-client consumer; only the job launcher
and CellNet process edge are stubbed so no subprocess or network is required.
"""

import json
import logging
import os
import sys
import tempfile
import threading
from types import SimpleNamespace


WORKTREE = (
    "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/"
    "gpt-continuation/nvflare-job/.specula-output/confirmation/CR-19/worktree"
)
sys.path.insert(0, WORKTREE)

from nvflare.apis.client import Client
from nvflare.apis.event_type import EventType
from nvflare.apis.fl_constant import FLContextKey, RunProcessKey, ServerCommandKey, SiteType
from nvflare.apis.fl_context import FLContextManager
from nvflare.apis.job_def import Job, JobMetaKey
from nvflare.apis.job_launcher_spec import JobHandleSpec, JobLauncherSpec, add_launcher
from nvflare.apis.workspace import Workspace
from nvflare.private.fed.server.client_manager import ClientManager
from nvflare.private.fed.server.fed_server import FederatedServer
from nvflare.private.fed.server.server_engine import ServerEngine
from nvflare.private.fed.server.server_state import HotState


class BlockingHandle(JobHandleSpec):
    def __init__(self):
        self._finished = threading.Event()

    def wait(self):
        self._finished.wait(timeout=10)

    def poll(self):
        return 0 if self._finished.is_set() else None

    def terminate(self):
        self._finished.set()

    def finish(self):
        self._finished.set()


class StubLauncher(JobLauncherSpec):
    def __init__(self):
        super().__init__()
        self.handle = BlockingHandle()

    def launch_job(self, job_meta: dict, fl_ctx):
        return self.handle


class StubCell:
    def __init__(self):
        self.dead_job_commands = []

    def get_internal_listener_url(self):
        return "tcp://localhost:0"

    def get_root_url_for_child(self):
        return "tcp://localhost:0"

    def get_internal_listener_params(self):
        return None

    def fire_and_forget(self, targets, channel, topic, message, optional=False, **kwargs):
        self.dead_job_commands.append(
            {
                "target": targets,
                "topic": topic,
                "client": message.payload.get_header(ServerCommandKey.FL_CLIENT),
                "reason": message.payload.get_header(ServerCommandKey.REASON),
            }
        )


class FakeRunManager:
    def __init__(self, engine, workspace, launcher):
        self._ctx_mgr = FLContextManager(
            engine=engine,
            identity_name="server",
            job_id="",
            public_stickers={},
            private_stickers={},
        )
        self._workspace = workspace
        self._launcher = launcher

    def new_context(self):
        return self._ctx_mgr.new_context()

    def get_workspace(self):
        return self._workspace

    def fire_event(self, event_type: str, fl_ctx):
        if event_type == EventType.BEFORE_JOB_LAUNCH:
            add_launcher(self._launcher, fl_ctx)


class EmptyOutcomeRunner:
    def get_client_outcome_jobs(self, *args, **kwargs):
        return []


def make_engine(root_dir):
    for name in ("startup", "local"):
        os.makedirs(os.path.join(root_dir, name), exist_ok=True)

    client_manager = ClientManager(project_name="cr19", min_num_clients=0, max_num_clients=10)
    cell = StubCell()
    server = SimpleNamespace(
        admin_server=SimpleNamespace(file_upload_dir=root_dir),
        cell=cell,
        server_state=HotState(host="localhost", port=8002),
        sign_auth_token=lambda client_name, token: "signature",
        runner_config=SimpleNamespace(add_component=lambda *args, **kwargs: None),
    )
    args = SimpleNamespace(workspace=root_dir, set=[], config_folder="config")
    engine = ServerEngine(server=server, args=args, client_manager=client_manager, snapshot_persistor=None, workers=1)
    launcher = StubLauncher()
    workspace = Workspace(root_dir=root_dir, site_name=SiteType.SERVER)
    engine.run_manager = FakeRunManager(engine, workspace, launcher)
    engine.job_runner = EmptyOutcomeRunner()
    return engine, cell, launcher


def prepare_deployed_job(root_dir, job_id):
    workspace = Workspace(root_dir=root_dir, site_name=SiteType.SERVER)
    os.makedirs(workspace.get_app_dir(job_id), exist_ok=True)
    os.makedirs(os.path.dirname(workspace.get_job_meta_path(job_id)), exist_ok=True)
    with open(workspace.get_job_meta_path(job_id), "w", encoding="utf-8") as f:
        json.dump({JobMetaKey.JOB_ID.value: job_id}, f)
    return workspace


def add_live_client(engine, token, name):
    client = Client(name=name, token=token)
    client.set_fqcn(name)
    client.last_connect_time = 0.0
    engine.client_manager.clients[token] = client
    engine.client_manager.name_to_clients[name] = client
    return client


def start_server_job(engine, workspace, job_id, job_clients):
    job = Job(
        job_id=job_id,
        resource_spec={},
        deploy_map={"app": [SiteType.SERVER, "site-a"]},
        meta={
            JobMetaKey.JOB_ID.value: job_id,
            JobMetaKey.JOB_NAME.value: "cr19",
            JobMetaKey.DEPLOY_MAP.value: {"app": [SiteType.SERVER, "site-a"]},
            JobMetaKey.RESOURCE_SPEC.value: {},
        },
        min_sites=1,
    )
    with engine.new_context() as fl_ctx:
        fl_ctx.set_prop(FLContextKey.WORKSPACE_OBJECT, workspace, private=True, sticky=False)
        fl_ctx.set_prop(FLContextKey.ARGS, engine.args, private=True, sticky=False)
        fl_ctx.set_prop(FLContextKey.SITE_OBJ, engine.server, private=True, sticky=False)
        err = engine.start_app_on_server(fl_ctx, job=job, job_clients=job_clients)
    assert err == "", err
    return job


def notify_dead_client(engine, client):
    class FakeFederatedServer:
        def __init__(self):
            self.engine = engine
            self.client_manager = engine.client_manager
            self.logger = logging.getLogger("cr19.fake-fed-server")

        def _notify_dead_job(self, client_obj, job_id: str, reason: str):
            return FederatedServer._notify_dead_job(self, client_obj, job_id, reason)

    fake_server = FakeFederatedServer()
    FederatedServer.notify_dead_client(fake_server, client)


def run_alias_case():
    root = tempfile.mkdtemp(prefix="nvflare-cr19-alias-")
    engine, cell, launcher = make_engine(root)
    workspace = prepare_deployed_job(root, "jobCR19alias")

    start_server_job(engine, workspace, "jobCR19alias", job_clients={})
    participants = engine.run_processes["jobCR19alias"][RunProcessKey.PARTICIPANTS]
    print(f"alias_case.participants_is_live_clients={participants is engine.client_manager.clients}")
    print(f"alias_case.participants_initial={list(participants)}")

    alien = add_live_client(engine, "token-alien", "site-never-started")
    print(f"alias_case.participants_after_register={list(participants)}")

    notify_dead_client(engine, alien)
    print(f"alias_case.dead_job_commands={cell.dead_job_commands}")

    launcher.handle.finish()
    return cell.dead_job_commands


def run_snapshot_control():
    root = tempfile.mkdtemp(prefix="nvflare-cr19-control-")
    engine, cell, launcher = make_engine(root)
    workspace = prepare_deployed_job(root, "jobCR19control")

    original = add_live_client(engine, "token-original", "site-original")
    start_server_job(engine, workspace, "jobCR19control", job_clients={"token-original": original})
    participants = engine.run_processes["jobCR19control"][RunProcessKey.PARTICIPANTS]
    print(f"control.participants_is_live_clients={participants is engine.client_manager.clients}")
    print(f"control.participants_initial={list(participants)}")

    alien = add_live_client(engine, "token-alien", "site-never-started")
    print(f"control.participants_after_register={list(participants)}")

    notify_dead_client(engine, alien)
    print(f"control.dead_job_commands={cell.dead_job_commands}")

    launcher.handle.finish()
    return cell.dead_job_commands


def main():
    commands = run_alias_case()
    control_commands = run_snapshot_control()

    if not commands:
        raise SystemExit("FAIL: aliased PARTICIPANTS did not notify dead job for non-participant")
    if control_commands:
        raise SystemExit("FAIL: snapshot control also notified dead job")
    if commands[0]["client"] != "site-never-started":
        raise SystemExit(f"FAIL: wrong client in dead-job command: {commands}")

    print("RESULT: CR-19 reproduced - non-participant client observed as job participant")


if __name__ == "__main__":
    main()
