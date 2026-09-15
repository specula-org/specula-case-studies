#!/usr/bin/env python3
"""MC-2 reproducer: post-spawn waiter failure frees a live child's resource."""

import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from nvflare.apis.event_type import EventType
from nvflare.apis.fl_constant import FLContextKey, JobConstants, RunProcessKey, SystemComponents
from nvflare.apis.fl_context import FLContextManager
from nvflare.apis.job_def import JobMetaKey
from nvflare.apis.job_launcher_spec import JobHandleSpec, JobLauncherSpec, add_launcher
from nvflare.apis.workspace import Workspace
from nvflare.app_common.resource_consumers.list_resource_consumer import ListResourceConsumer
from nvflare.app_common.resource_managers.list_resource_manager import ListResourceManager
from nvflare.private.admin_defs import Message
from nvflare.private.defs import RequestHeader, TrainingTopic
from nvflare.private.fed.client.client_engine_internal_spec import ClientEngineInternalSpec
from nvflare.private.fed.client.client_executor import JobExecutor
from nvflare.private.fed.client.scheduler_cmds import CheckResourceProcessor, StartJobProcessor
from nvflare.private.scheduler_constants import ShareableHeader


RESOURCE_SPEC = {"gpu": 1}
SERVER_CONFIG = [{"service": {"scheme": "grpc", "target": "parent:8002"}}]


class SubprocessHandle(JobHandleSpec):
    def __init__(self, job_id: str, seconds: int = 30):
        self.job_id = job_id
        self.cuda = os.environ.get("CUDA_VISIBLE_DEVICES", "")
        self.proc = subprocess.Popen(
            [sys.executable, "-c", f"import time; time.sleep({seconds})"],
            env=os.environ.copy(),
        )

    def terminate(self):
        if self.poll() is None:
            self.proc.terminate()

    def poll(self):
        return self.proc.poll()

    def wait(self):
        return self.proc.wait()


class RecordingLauncher(JobLauncherSpec):
    def __init__(self):
        super().__init__()
        self.handles = {}

    def launch_job(self, job_meta: dict, fl_ctx):
        job_id = job_meta[JobMetaKey.JOB_ID.value]
        handle = SubprocessHandle(job_id)
        self.handles[job_id] = handle
        print(f"LAUNCH {job_id}: pid={handle.proc.pid} CUDA_VISIBLE_DEVICES={handle.cuda!r}")
        return handle


class MiniCell:
    def get_internal_listener_url(self):
        return "tcp://parent:8002"

    def get_internal_listener_params(self):
        return {}

    def get_fqcn(self):
        return "site-1"

    def fire_and_forget(self, *args, **kwargs):
        return None


class MiniClient:
    def __init__(self):
        self.client_name = "site-1"
        self.token = "token"
        self.token_signature = "sig"
        self.ssid = "ssid"
        self.cell = MiniCell()
        self.components = {}
        self.multi_gpu = False

    def send_request_before_shutdown(self, *args, **kwargs):
        return None


class MiniEngine(ClientEngineInternalSpec):
    def __init__(self, workspace_root: str):
        self.workspace_root = workspace_root
        Path(workspace_root, "startup").mkdir(parents=True, exist_ok=True)
        Path(workspace_root, "local").mkdir(parents=True, exist_ok=True)
        self.workspace = Workspace(workspace_root, site_name="site-1")
        self.client = MiniClient()
        self.client.engine = self
        self.launcher = RecordingLauncher()
        self.resource_manager = ListResourceManager(resources={"gpu": [0]}, expiration_period=30)
        self.resource_consumer = ListResourceConsumer()
        self.args = SimpleNamespace(workspace=workspace_root, set=[])
        self.client_executor = JobExecutor(client=self.client, startup=self.workspace.get_startup_kit_dir())
        self.ctx_mgr = FLContextManager(
            engine=self,
            identity_name="site-1",
            job_id="job",
            private_stickers={
                FLContextKey.WORKSPACE_OBJECT: self.workspace,
                FLContextKey.SERVER_CONFIG: SERVER_CONFIG,
            },
        )

    def new_context(self):
        return self.ctx_mgr.new_context()

    def fire_event(self, event_type: str, fl_ctx):
        if event_type == EventType.BEFORE_JOB_LAUNCH:
            add_launcher(self.launcher, fl_ctx)

    def add_component(self, component_id: str, component):
        self.client.components[component_id] = component

    def get_component(self, component_id: str):
        if component_id == SystemComponents.RESOURCE_MANAGER:
            return self.resource_manager
        if component_id == SystemComponents.RESOURCE_CONSUMER:
            return self.resource_consumer
        return self.client.components.get(component_id)

    def start_app(self, job_id: str, job_meta: dict, allocated_resource=None, token=None, resource_manager=None):
        app_root = self.workspace.get_app_dir(job_id)
        if not os.path.exists(app_root):
            return f"ERROR: Client app does not exist for {job_id}"
        self.client_executor.start_app(
            self.client,
            job_id,
            job_meta,
            self.args,
            allocated_resource,
            token,
            resource_manager,
            fl_ctx=self.new_context(),
        )
        return "Start the client app..."

    def get_engine_status(self):
        return "running"

    def get_client_name(self) -> str:
        return self.client.client_name

    def deploy_app(self, app_name: str, job_id: str, job_meta: dict, client_name: str, app_data) -> str:
        return ""

    def notify_job_status(self, job_id: str, job_status):
        self.client_executor.notify_job_status(job_id, job_status)

    def abort_app(self, job_id: str) -> str:
        self.client_executor.abort_app(job_id)
        return ""

    def abort_task(self, job_id: str) -> str:
        return ""

    def delete_run(self, job_id: str) -> str:
        return ""

    def shutdown(self) -> str:
        return ""

    def restart(self) -> str:
        return ""

    def get_all_job_ids(self) -> list:
        return list(self.client_executor.run_processes)


def prepare_job(engine: MiniEngine, job_id: str):
    meta = {
        JobConstants.JOB_ID: job_id,
        JobMetaKey.RESOURCE_SPEC.value: RESOURCE_SPEC,
    }
    meta_path = Path(engine.workspace.get_job_meta_path(job_id))
    meta_path.parent.mkdir(parents=True, exist_ok=True)
    Path(engine.workspace.get_app_dir(job_id)).mkdir(parents=True, exist_ok=True)
    with open(meta_path, "w", encoding="utf-8") as f:
        json.dump(meta, f)
    return meta


def check_resource(engine: MiniEngine, job_id: str):
    req = Message(topic=TrainingTopic.CHECK_RESOURCE, body=RESOURCE_SPEC)
    req.set_header(RequestHeader.JOB_ID, job_id)
    reply = CheckResourceProcessor().process(req, engine)
    enough = reply.body.get_header(ShareableHeader.IS_RESOURCE_ENOUGH)
    token = reply.body.get_header(ShareableHeader.RESOURCE_RESERVE_TOKEN)
    return enough, token


def start_job(engine: MiniEngine, job_id: str, token: str, meta: dict):
    req = Message(topic=TrainingTopic.START_JOB, body=RESOURCE_SPEC)
    req.set_header(RequestHeader.JOB_ID, job_id)
    req.set_header(RequestHeader.JOB_META, dict(meta))
    req.set_header(ShareableHeader.RESOURCE_RESERVE_TOKEN, token)
    return StartJobProcessor().process(req, engine)


def free_gpus(engine: MiniEngine):
    return engine.resource_manager.report_resources(None)["resources"]["gpu"]


def stop_all(engine: MiniEngine):
    for handle in list(engine.launcher.handles.values()):
        handle.terminate()
    for handle in list(engine.launcher.handles.values()):
        try:
            handle.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            handle.proc.kill()
            handle.proc.wait(timeout=5)
    deadline = time.time() + 5
    while time.time() < deadline and engine.client_executor.run_processes:
        time.sleep(0.05)


def run_level0_control():
    with tempfile.TemporaryDirectory(prefix="mc2-level0-") as root:
        engine = MiniEngine(root)
        meta = prepare_job(engine, "job-control")
        enough, token = check_resource(engine, "job-control")
        assert enough and token
        reply = start_job(engine, "job-control", token, meta)
        handle = engine.launcher.handles["job-control"]
        assert reply.body == "Start the client app..."
        assert handle.poll() is None
        assert free_gpus(engine) == []
        print(
            "LEVEL0 normal-start control: "
            f"child_alive={handle.poll() is None} free_gpus={free_gpus(engine)} result={reply.body!r}"
        )
        stop_all(engine)


def run_level2_waiter_failure():
    with tempfile.TemporaryDirectory(prefix="mc2-level2-") as root:
        engine = MiniEngine(root)
        meta1 = prepare_job(engine, "job-1")
        meta2 = prepare_job(engine, "job-2")

        enough1, token1 = check_resource(engine, "job-1")
        assert enough1 and token1

        original_start = threading.Thread.start

        def fail_cleanup_waiter_start(thread):
            target = getattr(thread, "_target", None)
            if getattr(target, "__name__", "") == "_wait_child_process_finish":
                raise RuntimeError("controlled waiter installation failure")
            return original_start(thread)

        with patch.object(threading.Thread, "start", fail_cleanup_waiter_start):
            reply1 = start_job(engine, "job-1", token1, meta1)

        first = engine.launcher.handles["job-1"]
        process = engine.client_executor.run_processes["job-1"]
        pending_handle = process[RunProcessKey.JOB_HANDLE]
        assert "controlled waiter installation failure" in reply1.body
        assert first.poll() is None
        assert getattr(pending_handle, "_job_handle", None) is first
        assert free_gpus(engine) == [0]
        print(
            "LEVEL2 injected CE step MCJobExecutorWaiterInstallationException: "
            f"start_reply={reply1.body!r} first_child_alive={first.poll() is None} "
            f"registered_status={process[RunProcessKey.STATUS]} free_gpus_after_rollback={free_gpus(engine)}"
        )

        enough2, token2 = check_resource(engine, "job-2")
        assert enough2 and token2
        print(
            "OBSERVED WRONG AVAILABILITY: "
            f"job2_check_enough={enough2} token_present={bool(token2)} while_job1_child_alive={first.poll() is None}"
        )

        reply2 = start_job(engine, "job-2", token2, meta2)
        second = engine.launcher.handles["job-2"]
        assert reply2.body == "Start the client app..."
        assert second.cuda == "0"
        assert first.poll() is None and second.poll() is None
        print(
            "OBSERVED DOUBLE ASSIGNMENT: "
            f"job1_pid={first.proc.pid} job1_cuda={first.cuda!r} "
            f"job2_pid={second.proc.pid} job2_cuda={second.cuda!r} "
            f"both_children_alive={first.poll() is None and second.poll() is None}"
        )

        stop_all(engine)


def main():
    run_level0_control()
    run_level2_waiter_failure()
    print("MC-2 reproduced: StartJobProcessor freed a resource while the launched child was still alive.")


if __name__ == "__main__":
    main()
