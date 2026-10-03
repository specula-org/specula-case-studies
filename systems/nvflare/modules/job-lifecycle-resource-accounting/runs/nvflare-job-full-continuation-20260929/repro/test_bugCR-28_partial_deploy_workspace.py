#!/usr/bin/env python3
"""Reproduce CR-28: partial deploy leaves finished job without stored workspace."""

import json
import os
import shutil
import sys
import tempfile
import threading
import time
import uuid
from pathlib import Path
from types import SimpleNamespace


SOURCE_ROOT = os.environ.get(
    "NVFLARE_SOURCE_ROOT",
    "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/"
    "nvflare-job/.specula-output/confirmation/CR-28/worktree",
)
sys.path.insert(0, SOURCE_ROOT)

from nvflare.apis.client import Client  # noqa: E402
from nvflare.apis.event_type import EventType  # noqa: E402
from nvflare.apis.fl_constant import FLContextKey, SiteType, SystemComponents  # noqa: E402
from nvflare.apis.fl_context import FLContextManager  # noqa: E402
from nvflare.apis.fl_snapshot import RunSnapshot  # noqa: E402
from nvflare.apis.impl.job_def_manager import SimpleJobDefManager  # noqa: E402
from nvflare.apis.job_def import Job, JobMetaKey, RunStatus  # noqa: E402
from nvflare.apis.server_engine_spec import ServerEngineSpec  # noqa: E402
from nvflare.apis.shareable import Shareable  # noqa: E402
from nvflare.apis.storage import WORKSPACE, WORKSPACE_ZIP  # noqa: E402
from nvflare.apis.utils.event import fire_event_to_components  # noqa: E402
from nvflare.apis.workspace import Workspace  # noqa: E402
from nvflare.app_common.job_schedulers.job_scheduler import DefaultJobScheduler  # noqa: E402
from nvflare.app_common.storages.filesystem_storage import FilesystemStorage  # noqa: E402
from nvflare.fuel.hci.server.constants import ConnProps  # noqa: E402
from nvflare.fuel.utils.zip_utils import zip_directory_to_bytes  # noqa: E402
from nvflare.private.admin_defs import error_reply, ok_reply  # noqa: E402
from nvflare.private.fed.server.job_cmds import JobCommandModule  # noqa: E402
from nvflare.private.fed.server.job_runner import JobRunner  # noqa: E402
from nvflare.private.fed.server.server_state import HotState  # noqa: E402


CLIENTS = ("site-1", "site-2")


class FakeAdminServer:
    def __init__(self, engine):
        self.timeout = 2.0
        self.sai = engine
        self.deploy_request_tokens = []

    def send_requests_and_get_reply_dict(self, requests, timeout_secs=None):
        self.deploy_request_tokens = sorted(requests)
        replies = {}
        for token in requests:
            if token == "token-site-1":
                replies[token] = ok_reply(body="deployed")
            else:
                replies[token] = error_reply("simulated reachable client deploy rejection")
        return replies

    def send_requests(self, requests, fl_ctx, timeout_secs=None, optional=False):
        return []


class FakeEngine(ServerEngineSpec):
    def __init__(self, root_dir: str):
        self.root_dir = root_dir
        self.workspace_root = os.path.join(root_dir, "server_workspace")
        os.makedirs(os.path.join(self.workspace_root, "startup"), exist_ok=True)
        os.makedirs(os.path.join(self.workspace_root, "local"), exist_ok=True)
        self.workspace = Workspace(root_dir=self.workspace_root, site_name=SiteType.SERVER)

        self.job_store_root = os.path.join(root_dir, "job_store", "jobs")
        self.storage = FilesystemStorage()
        self.job_def_manager = SimpleJobDefManager(uri_root=self.job_store_root)
        self.scheduler = DefaultJobScheduler(max_jobs=1, max_schedule_count=1, min_schedule_interval=0.0)
        self.components = {
            "job_store": self.storage,
            SystemComponents.JOB_MANAGER: self.job_def_manager,
            SystemComponents.JOB_SCHEDULER: self.scheduler,
        }
        self.clients = {f"token-{name}": Client(name, f"token-{name}") for name in CLIENTS}
        self.client_manager = SimpleNamespace(clients=self.clients)
        self.server = SimpleNamespace(admin_server=FakeAdminServer(self), server_state=HotState())
        self.run_processes = {}
        self.exception_run_processes = {}
        self.lock = threading.Lock()
        self.ctx_mgr = FLContextManager(engine=self, identity_name=SiteType.SERVER)
        self.cancel_calls = []
        self.fired_events = []

    def fire_event(self, event_type: str, fl_ctx):
        self.fired_events.append(event_type)
        fire_event_to_components(event_type, [self.scheduler], fl_ctx)

    def get_clients(self):
        return list(self.clients.values())

    def sync_clients_from_main_process(self):
        return self.get_clients()

    def update_job_run_status(self):
        return None

    def new_context(self):
        ctx = self.ctx_mgr.new_context()
        ctx.set_prop(FLContextKey.WORKSPACE_OBJECT, self.workspace, private=True, sticky=False)
        return ctx

    def get_workspace(self):
        return self.workspace

    def add_component(self, component_id: str, component):
        self.components[component_id] = component

    def get_component(self, component_id: str):
        return self.components.get(component_id)

    def register_aux_message_handler(self, topic: str, message_handle_func):
        return None

    def send_aux_request(
        self,
        targets: [],
        topic: str,
        request: Shareable,
        timeout: float,
        fl_ctx,
        optional=False,
        secure=False,
    ):
        return {}

    def multicast_aux_requests(
        self,
        topic: str,
        target_requests: dict[str, Shareable],
        timeout: float,
        fl_ctx,
        optional: bool = False,
        secure: bool = False,
    ):
        return {}

    def get_widget(self, widget_id: str):
        return None

    def persist_components(self, fl_ctx, completed: bool):
        return None

    def restore_components(self, snapshot: RunSnapshot, fl_ctx):
        return None

    def start_client_job(self, job, client_sites, fl_ctx):
        raise AssertionError("CR-28 deploy failure should happen before start_client_job")

    def check_client_resources(self, job: Job, resource_reqs: dict[str, dict], fl_ctx):
        return {name: (True, f"reserve-{name}") for name in resource_reqs}

    def cancel_client_resources(self, resource_check_results, resource_reqs, fl_ctx):
        self.cancel_calls.append((dict(resource_check_results), dict(resource_reqs)))

    def get_client_name_from_token(self, token: str) -> str:
        return self.clients[token].name

    def validate_targets(self, client_sites):
        valid = []
        invalid = []
        by_name = {client.name: client for client in self.clients.values()}
        for site in client_sites:
            client = by_name.get(site)
            if client:
                valid.append(client)
            else:
                invalid.append(site)
        return valid, invalid

    def get_job_clients(self, client_sites):
        by_name = {client.name: token for token, client in self.clients.items()}
        return {by_name[site]: self.clients[by_name[site]] for site in client_sites}

    def start_app_on_server(self, fl_ctx, job):
        raise AssertionError("CR-28 deploy failure should happen before start_app_on_server")

    def abort_app_on_server(self, job_id):
        return ""

    def delete_job_id(self, job_id):
        run_dir = self.workspace.get_run_dir(job_id)
        if os.path.exists(run_dir):
            shutil.rmtree(run_dir)
        return ""


class CaptureDownloadJobModule(JobCommandModule):
    def __init__(self):
        super().__init__()
        self.downloaded_files = []

    def download_folder(self, conn, tx_id: str, folder_name: str):
        tx_folder = Path(self.tx_path(conn, tx_id)) / folder_name
        self.downloaded_files = sorted(
            p.relative_to(tx_folder).as_posix() for p in tx_folder.rglob("*") if p.is_file() or p.is_symlink()
        )
        conn.append_success(f"captured download for {folder_name}")


class MockConnection:
    def __init__(self, app_ctx, download_dir):
        self.app_ctx = app_ctx
        self._props = {ConnProps.DOWNLOAD_DIR: download_dir}
        self.errors = []
        self.successes = []
        self.strings = []
        self.meta = {}

    def get_prop(self, key, default=None):
        return self._props.get(key, default)

    def set_prop(self, key, value):
        self._props[key] = value

    def append_error(self, msg, meta=None):
        self.errors.append((msg, meta))
        if meta:
            self.update_meta(meta)

    def append_success(self, msg, meta=None):
        self.successes.append((msg, meta))
        if meta:
            self.update_meta(meta)

    def append_string(self, msg, meta=None):
        self.strings.append((msg, meta))
        if meta:
            self.update_meta(meta)

    def update_meta(self, meta):
        self.meta.update(meta)


def submit_job(engine: FakeEngine) -> str:
    job_root = Path(SOURCE_ROOT) / "tests" / "unit_test" / "data" / "jobs" / "valid_job"
    meta = json.loads((job_root / "meta.json").read_text(encoding="utf-8"))
    job_id = str(uuid.uuid4())
    meta.update(
        {
            JobMetaKey.JOB_ID.value: job_id,
            JobMetaKey.JOB_FOLDER_NAME.value: "valid_job",
            JobMetaKey.MIN_CLIENTS.value: 2,
            JobMetaKey.MANDATORY_CLIENTS.value: [],
        }
    )
    uploaded_content = zip_directory_to_bytes(str(job_root.parent), "valid_job")
    with engine.new_context() as fl_ctx:
        engine.job_def_manager.create(meta, uploaded_content, fl_ctx)
    return job_id


def wait_for_status(engine: FakeEngine, job_id: str, expected: RunStatus, timeout_s=8.0):
    deadline = time.time() + timeout_s
    last_status = None
    while time.time() < deadline:
        with engine.new_context() as fl_ctx:
            job = engine.job_def_manager.get_job(job_id, fl_ctx)
            last_status = job.meta.get(JobMetaKey.STATUS.value) if job else None
        if last_status == expected.value:
            return last_status
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for {expected.value}; last_status={last_status}")


def list_relative_files(root: str):
    base = Path(root)
    if not base.exists():
        return []
    return sorted(p.relative_to(base).as_posix() for p in base.rglob("*") if p.is_file())


def main() -> int:
    print("CR-28 reproduction: partial deploy vs finished-job workspace download")
    print(f"source repo: {SOURCE_ROOT}")

    with tempfile.TemporaryDirectory(prefix="cr28-partial-deploy-") as root_dir:
        engine = FakeEngine(root_dir)
        job_id = submit_job(engine)

        runner = JobRunner(workspace_root=engine.workspace_root)
        with engine.new_context() as start_ctx:
            runner.handle_event(EventType.SYSTEM_START, start_ctx)

        thread = threading.Thread(target=runner.run, args=(engine.new_context(),), name="cr28-job-runner")
        thread.start()
        try:
            final_status = wait_for_status(engine, job_id, RunStatus.FAILED_TO_RUN)
        finally:
            runner.ask_to_stop = True
            thread.join(timeout=4.0)
            if thread.is_alive():
                raise AssertionError("JobRunner thread did not stop")

        run_dir = engine.workspace.get_run_dir(job_id)
        server_app_dir = engine.workspace.get_app_dir(job_id)
        live_workspace_files = list_relative_files(run_dir)
        job_store_workspace_component = os.path.join(engine.job_store_root, job_id, WORKSPACE)

        download_dir = os.path.join(root_dir, "download")
        conn = MockConnection(engine, download_dir)
        module = CaptureDownloadJobModule()
        module.download_job(conn, ["download_job", job_id])

        workspace_in_download = WORKSPACE_ZIP in module.downloaded_files
        reproduced = (
            final_status == RunStatus.FAILED_TO_RUN.value
            and os.path.isdir(run_dir)
            and os.path.isdir(server_app_dir)
            and not os.path.exists(job_store_workspace_component)
            and not conn.errors
            and not workspace_in_download
        )

        print(f"job_id={job_id}")
        print(f"deploy_request_tokens={engine.server.admin_server.deploy_request_tokens}")
        print(f"final_status={final_status}")
        print(f"server_run_dir_exists={os.path.isdir(run_dir)}")
        print(f"server_app_dir_exists={os.path.isdir(server_app_dir)}")
        print(f"server_run_dir={run_dir}")
        print(f"server_run_dir_files={live_workspace_files}")
        print(f"stored_workspace_component_exists={os.path.exists(job_store_workspace_component)}")
        print(f"download_errors={conn.errors}")
        print(f"download_successes={conn.successes}")
        print(f"downloaded_files={module.downloaded_files}")
        print(f"workspace_zip_in_download={workspace_in_download}")
        print("reachable_client_error_reply=nvflare/private/fed/client/training_cmds.py DeployProcessor error_reply")
        print("wrong_consumer=nvflare/private/fed/server/job_cmds.py JobCommandModule.download_job")
        print(f"BUG_TRIGGERED={reproduced}")

        if not reproduced:
            raise AssertionError("CR-28 symptom not reproduced")

    print("RESULT: CR-28 reproduced")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
