#!/usr/bin/env python3
"""Reproduce CR-26: waiter cleanup exception leaves client resources/job owned."""

import json
import os
import sys
import tempfile
import threading
import time
from types import SimpleNamespace


SOURCE_ROOT = os.environ.get(
    "NVFLARE_SOURCE_ROOT",
    "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/"
    "nvflare-job/.specula-output/confirmation/CR-26/worktree",
)
sys.path.insert(0, SOURCE_ROOT)

from nvflare.apis.event_type import EventType
from nvflare.apis.fl_constant import FLContextKey, SystemComponents
from nvflare.apis.job_def import JobMetaKey
from nvflare.apis.job_launcher_spec import JobHandleSpec, JobLauncherSpec, JobReturnCode, add_launcher
from nvflare.apis.workspace import Workspace
from nvflare.app_common.resource_consumers.list_resource_consumer import ListResourceConsumer
from nvflare.app_common.resource_managers.list_resource_manager import ListResourceManager
from nvflare.private.admin_defs import Message
from nvflare.private.defs import RequestHeader, TrainingTopic
from nvflare.private.fed.client.client_engine import ClientEngine
from nvflare.private.fed.client.scheduler_cmds import CheckResourceProcessor, StartJobProcessor
from nvflare.private.scheduler_constants import ShareableHeader


SITE_NAME = "site-1"
FIRST_JOB = "cr26-job-1"
SECOND_JOB = "cr26-job-2"
RESOURCE_SPEC = {"gpu": 1}


class ExplodingFreeResourceManager(ListResourceManager):
    """A supported ResourceManagerSpec whose free operation fails before deallocation."""

    def __init__(self):
        super().__init__({"gpu": [0]}, expiration_period=30)
        self.free_calls = 0
        self.free_args = None

    def free_resources(self, resources: dict, token: str, fl_ctx):
        self.free_calls += 1
        self.free_args = {"resources": resources, "token": token}
        raise RuntimeError("CR-26 injected free_resources failure")


class ImmediateExitHandle(JobHandleSpec):
    def __init__(self):
        self.wait_calls = 0
        self.terminate_calls = 0

    def terminate(self):
        self.terminate_calls += 1

    def poll(self):
        return JobReturnCode.SUCCESS

    def wait(self):
        self.wait_calls += 1


class ImmediateExitLauncher(JobLauncherSpec):
    """A minimal public JobLauncherSpec: launch succeeds and the job exits cleanly."""

    def __init__(self):
        super().__init__()
        self.handle = None
        self.launch_calls = 0

    def handle_event(self, event_type: str, fl_ctx):
        if event_type == EventType.BEFORE_JOB_LAUNCH:
            add_launcher(self, fl_ctx)

    def launch_job(self, job_meta: dict, fl_ctx):
        self.launch_calls += 1
        self.handle = ImmediateExitHandle()
        return self.handle


class FakeCell:
    def get_internal_listener_url(self):
        return "grpc://parent-listener"

    def get_internal_listener_params(self):
        return {}

    def get_fqcn(self):
        return SITE_NAME


class FakeClient:
    def __init__(self, components):
        self.client_name = SITE_NAME
        self.client_args = {}
        self.secure_train = False
        self.components = components
        self.cell = FakeCell()
        self.token = "token"
        self.token_signature = "signature"
        self.ssid = "ssid"
        self.multi_gpu = True
        self.sent_shutdown_requests = 0
        self.engine = None

    def send_request_before_shutdown(self, **_kwargs):
        self.sent_shutdown_requests += 1
        return None


def prepare_workspace(root_dir: str, job_id: str, job_meta: dict) -> Workspace:
    os.makedirs(os.path.join(root_dir, "startup"), exist_ok=True)
    os.makedirs(os.path.join(root_dir, "local"), exist_ok=True)
    workspace = Workspace(root_dir, site_name=SITE_NAME)
    os.makedirs(workspace.get_app_dir(job_id), exist_ok=True)
    os.makedirs(os.path.dirname(workspace.get_job_meta_path(job_id)), exist_ok=True)
    with open(workspace.get_job_meta_path(job_id), "w", encoding="utf-8") as f:
        json.dump(job_meta, f)
    return workspace


def install_workspace_context(engine: ClientEngine, workspace: Workspace):
    with engine.new_context() as fl_ctx:
        fl_ctx.set_prop(FLContextKey.WORKSPACE_OBJECT, workspace, private=True, sticky=True)
        fl_ctx.set_prop(
            FLContextKey.SERVER_CONFIG,
            [{"service": {"scheme": "grpc", "target": "server:8002"}}],
            private=True,
            sticky=True,
        )


def check_resource(engine: ClientEngine, job_id: str):
    req = Message(topic=TrainingTopic.CHECK_RESOURCE, body=dict(RESOURCE_SPEC))
    req.set_header(RequestHeader.JOB_ID, job_id)
    reply = CheckResourceProcessor().process(req, engine)
    return (
        reply.body.get_header(ShareableHeader.IS_RESOURCE_ENOUGH),
        reply.body.get_header(ShareableHeader.RESOURCE_RESERVE_TOKEN),
    )


def start_job(engine: ClientEngine, job_id: str, job_meta: dict, token: str):
    req = Message(topic=TrainingTopic.START_JOB, body=dict(RESOURCE_SPEC))
    req.set_header(RequestHeader.JOB_ID, job_id)
    req.set_header(RequestHeader.JOB_META, job_meta)
    req.set_header(ShareableHeader.RESOURCE_RESERVE_TOKEN, token)
    return StartJobProcessor().process(req, engine)


def wait_for_cleanup_exception(exceptions, manager: ExplodingFreeResourceManager, timeout_s=5.0):
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if manager.free_calls and exceptions:
            return
        time.sleep(0.02)


def main():
    original_excepthook = threading.excepthook
    thread_exceptions = []

    def capture_thread_exception(args):
        thread_exceptions.append(
            f"{args.thread.name}:{args.exc_type.__name__}:{args.exc_value}"
        )

    threading.excepthook = capture_thread_exception

    try:
        with tempfile.TemporaryDirectory(prefix="cr26-workspace-") as workspace_root:
            job_meta = {JobMetaKey.JOB_ID.value: FIRST_JOB}
            workspace = prepare_workspace(workspace_root, FIRST_JOB, job_meta)

            manager = ExplodingFreeResourceManager()
            launcher = ImmediateExitLauncher()
            components = {
                SystemComponents.RESOURCE_MANAGER: manager,
                SystemComponents.RESOURCE_CONSUMER: ListResourceConsumer(),
                "cr26_immediate_launcher": launcher,
            }
            client = FakeClient(components)
            args = SimpleNamespace(workspace=workspace_root, set=[])
            engine = ClientEngine(client, args=args, rank=0, workers=1)
            client.engine = engine
            install_workspace_context(engine, workspace)

            first_enough, first_token = check_resource(engine, FIRST_JOB)
            print(f"first_check_is_resource_enough={first_enough}")
            print(f"first_reservation_token_present={bool(first_token)}")

            start_reply = start_job(engine, FIRST_JOB, dict(job_meta), first_token)
            print(f"start_reply_body={start_reply.body}")

            wait_for_cleanup_exception(thread_exceptions, manager)

            run_keys_after_exit = engine.get_all_job_ids()
            second_enough, second_token = check_resource(engine, SECOND_JOB)
            resource_snapshot = manager.report_resources(engine.new_context())

            print(f"launcher_launch_calls={launcher.launch_calls}")
            print(f"handle_wait_calls={launcher.handle.wait_calls if launcher.handle else 'no-handle'}")
            print(f"free_resources_calls={manager.free_calls}")
            print(f"thread_exception={thread_exceptions[0] if thread_exceptions else 'NONE'}")
            print(f"run_processes_after_child_exit={run_keys_after_exit}")
            print(f"second_check_is_resource_enough={second_enough}")
            print(f"second_reservation_token_present={bool(second_token)}")
            print(f"resource_snapshot={resource_snapshot}")

            reproduced = (
                first_enough is True
                and bool(first_token)
                and launcher.launch_calls == 1
                and launcher.handle is not None
                and launcher.handle.wait_calls == 1
                and manager.free_calls == 1
                and bool(thread_exceptions)
                and FIRST_JOB in run_keys_after_exit
                and second_enough is False
            )

            if not reproduced:
                print("CR26_REPRODUCED=no")
                return 1

            print(
                "CR26_REPRODUCED=yes: cleanup exception killed the waiter before "
                "registry removal and before the allocated GPU was returned"
            )
            return 0
    finally:
        threading.excepthook = original_excepthook


if __name__ == "__main__":
    raise SystemExit(main())
