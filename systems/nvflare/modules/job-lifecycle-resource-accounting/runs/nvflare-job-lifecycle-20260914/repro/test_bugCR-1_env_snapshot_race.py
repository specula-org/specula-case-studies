#!/usr/bin/env python3
"""Reproduce CR-1: process-global CUDA_VISIBLE_DEVICES crosses job allocation identity.

Escalation level: Level 1 timing assistance.  The inputs are normal
CHECK_RESOURCE/START_JOB messages with distinct reservation tokens; the harness
only delays job-A after resource consumption so job-B can consume its own
allocation before job-A's ProcessJobLauncher snapshots os.environ.
"""

import json
import os
import shlex
import sys
import tempfile
import threading
from pathlib import Path


SOURCE_REPO = Path(
    os.environ.get(
        "NVFLARE_SOURCE_REPO",
        "/home/ubuntu/nvflare-job-lifecycle-20260914/specula/runs/"
        "nvflare-job-lifecycle-20260914/nvflare-job-lifecycle/"
        ".specula-output/confirmation/CR-1/worktree",
    )
)
sys.path.insert(0, str(SOURCE_REPO))

# Keep the pre-existing Specula probes inert; they are not part of this repro.
for name in ("NVFLARE_LIFECYCLE_RAW", "NVFLARE_LIFECYCLE_SCENARIO", "NVFLARE_LIFECYCLE_GATE"):
    os.environ.pop(name, None)

from nvflare.apis.fl_constant import FLContextKey, JobConstants, SystemComponents
from nvflare.apis.fl_context import FLContext
from nvflare.app_common.job_launcher.process_launcher import ProcessJobLauncher
from nvflare.app_common.resource_consumers.list_resource_consumer import ListResourceConsumer
from nvflare.app_common.resource_managers.list_resource_manager import ListResourceManager
from nvflare.private.admin_defs import Message
from nvflare.private.defs import RequestHeader, TrainingTopic
from nvflare.private.fed.client.client_engine_internal_spec import ClientEngineInternalSpec
from nvflare.private.fed.client.scheduler_cmds import CheckResourceProcessor, StartJobProcessor
from nvflare.private.scheduler_constants import ShareableHeader


class Context:
    def __init__(self, engine):
        self.engine = engine
        self.fl_ctx = FLContext()

    def __enter__(self):
        self.fl_ctx.set_prop(FLContextKey.CURRENT_JOB_ID, "", private=True, sticky=False)
        return self.fl_ctx

    def __exit__(self, exc_type, exc, tb):
        return False


class WorkspaceStub:
    def get_app_custom_dir(self, job_id):
        return ""


class EnvEchoLauncher(ProcessJobLauncher):
    def __init__(self, output_dir):
        super().__init__()
        self.output_dir = Path(output_dir)

    def get_command(self, job_meta, fl_ctx):
        job_id = job_meta[JobConstants.JOB_ID]
        output_path = self.output_dir / f"{job_id}.json"
        code = (
            "import json, os, sys; "
            "open(sys.argv[1], 'w', encoding='utf-8').write("
            "json.dumps({'job_id': sys.argv[2], "
            "'cuda_visible_devices': os.environ.get('CUDA_VISIBLE_DEVICES', '')}) + '\\n')"
        )
        return " ".join(
            [
                shlex.quote(sys.executable),
                "-c",
                shlex.quote(code),
                shlex.quote(str(output_path)),
                shlex.quote(job_id),
            ]
        )


class EngineHarness(ClientEngineInternalSpec):
    def __init__(self, output_dir, delay_job_a):
        self.resource_manager = ListResourceManager(resources={"gpu": [0, 1]}, expiration_period=30)
        self.resource_consumer = ListResourceConsumer()
        self.launcher = EnvEchoLauncher(output_dir)
        self.delay_job_a = delay_job_a
        self.job_a_in_start = threading.Event()
        self.allow_job_a_launch = threading.Event()
        self.launch_records = {}

    def new_context(self):
        return Context(self)

    def fire_event(self, event_type, fl_ctx):
        return None

    def add_component(self, component_id, component):
        return None

    def get_component(self, component_id):
        if component_id == SystemComponents.RESOURCE_MANAGER:
            return self.resource_manager
        if component_id == SystemComponents.RESOURCE_CONSUMER:
            return self.resource_consumer
        raise KeyError(component_id)

    def start_app(self, job_id, job_meta, allocated_resource=None, token=None, resource_manager=None):
        if job_id == "job-A":
            self.job_a_in_start.set()
        if job_id == "job-A" and self.delay_job_a:
            if not self.allow_job_a_launch.wait(timeout=10):
                raise RuntimeError("timed out waiting to release job-A launch")

        fl_ctx = FLContext()
        fl_ctx.set_prop(FLContextKey.WORKSPACE_OBJECT, WorkspaceStub(), private=True, sticky=False)
        fl_ctx.set_prop(FLContextKey.JOB_PROCESS_ARGS, {}, private=True, sticky=False)
        handle = self.launcher.launch_job(job_meta, fl_ctx)
        handle.wait()
        self.launch_records[job_id] = {
            "allocated_resource": allocated_resource,
            "token": token,
        }
        return "Start the client app..."

    def get_engine_status(self):
        return "running"

    def get_client_name(self):
        return "site-1"

    def deploy_app(self, app_name, job_id, job_meta, client_name, app_data):
        return ""

    def notify_job_status(self, job_id, job_status):
        return None

    def abort_app(self, job_id):
        return ""

    def abort_task(self, job_id):
        return ""

    def delete_run(self, job_id):
        return ""

    def shutdown(self):
        return ""

    def restart(self):
        return ""

    def get_all_job_ids(self):
        return []


def make_check_request(job_id):
    req = Message(topic=TrainingTopic.CHECK_RESOURCE, body={"gpu": 1})
    req.set_header(RequestHeader.JOB_ID, job_id)
    return req


def make_start_request(job_id, token):
    req = Message(topic=TrainingTopic.START_JOB, body={"gpu": 1})
    req.set_header(RequestHeader.JOB_ID, job_id)
    req.set_header(RequestHeader.JOB_META, {JobConstants.JOB_ID: job_id})
    req.set_header(ShareableHeader.RESOURCE_RESERVE_TOKEN, token)
    return req


def reserve(engine, job_id):
    reply = CheckResourceProcessor().process(make_check_request(job_id), engine)
    enough = reply.body.get_header(ShareableHeader.IS_RESOURCE_ENOUGH)
    token = reply.body.get_header(ShareableHeader.RESOURCE_RESERVE_TOKEN)
    if not enough or not token:
        raise AssertionError(f"{job_id} did not reserve resources: enough={enough}, token={token!r}")
    return token


def run_start(processor, engine, req, replies, key):
    replies[key] = processor.process(req, engine)


def run_scenario(label, delay_job_a):
    os.environ.pop("CUDA_VISIBLE_DEVICES", None)
    os.environ.pop("CUDA_DEVICE_ORDER", None)
    with tempfile.TemporaryDirectory(prefix=f"nvflare-cr1-{label.lower()}-") as tmp:
        engine = EngineHarness(tmp, delay_job_a=delay_job_a)
        token_a = reserve(engine, "job-A")
        token_b = reserve(engine, "job-B")

        start_a = make_start_request("job-A", token_a)
        start_b = make_start_request("job-B", token_b)
        processor = StartJobProcessor()
        replies = {}

        thread_a = threading.Thread(target=run_start, args=(processor, engine, start_a, replies, "job-A"))
        thread_b = threading.Thread(target=run_start, args=(processor, engine, start_b, replies, "job-B"))

        thread_a.start()
        if delay_job_a:
            if not engine.job_a_in_start.wait(timeout=10):
                raise AssertionError("job-A did not reach start_app after consume()")
            thread_b.start()
            thread_b.join(timeout=10)
            if thread_b.is_alive():
                raise AssertionError("job-B did not finish")

            engine.allow_job_a_launch.set()
        else:
            thread_b.start()

        thread_a.join(timeout=10)
        thread_b.join(timeout=10)
        if thread_a.is_alive() or thread_b.is_alive():
            raise AssertionError(f"{label} did not finish: A alive={thread_a.is_alive()}, B alive={thread_b.is_alive()}")

        child_records = {}
        for job_id in ("job-A", "job-B"):
            path = Path(tmp) / f"{job_id}.json"
            child_records[job_id] = json.loads(path.read_text(encoding="utf-8"))

        observed = {
            "level": label,
            "timing_assistance": delay_job_a,
            "tokens_distinct": token_a != token_b,
            "allocations": engine.launch_records,
            "child_env": child_records,
            "reply_bodies": {k: v.body for k, v in replies.items()},
            "parent_cuda_after_starts": os.environ.get("CUDA_VISIBLE_DEVICES", ""),
        }

        allocated_a = engine.launch_records["job-A"]["allocated_resource"]["gpu"]
        allocated_b = engine.launch_records["job-B"]["allocated_resource"]["gpu"]
        cuda_a = child_records["job-A"]["cuda_visible_devices"]
        triggered = allocated_a != allocated_b and cuda_a != str(allocated_a[0])
        return observed, triggered


def main():
    old_cuda = os.environ.pop("CUDA_VISIBLE_DEVICES", None)
    old_order = os.environ.pop("CUDA_DEVICE_ORDER", None)
    try:
        for label, delay_job_a in (("LEVEL0_NO_DELAY", False), ("LEVEL1_DELAY_AFTER_CONSUME", True)):
            observed, triggered = run_scenario(label, delay_job_a)
            print(f"{label} observation:")
            print(json.dumps(observed, indent=2, sort_keys=True))
            allocated_a = observed["allocations"]["job-A"]["allocated_resource"]["gpu"]
            allocated_b = observed["allocations"]["job-B"]["allocated_resource"]["gpu"]
            cuda_a = observed["child_env"]["job-A"]["cuda_visible_devices"]
            cuda_b = observed["child_env"]["job-B"]["cuda_visible_devices"]
            if triggered:
                print(
                    f"BUG_TRIGGERED at {label}: job-A child inherited CUDA_VISIBLE_DEVICES="
                    f"{cuda_a!r} despite allocation {allocated_a}; job-B allocation {allocated_b}, "
                    f"job-B child env {cuda_b!r}."
                )
                return 0
            print(
                f"BUG_NOT_TRIGGERED at {label}: job-A allocation {allocated_a}, env {cuda_a!r}; "
                f"job-B allocation {allocated_b}, env {cuda_b!r}."
            )
        return 1
    finally:
        if old_cuda is None:
            os.environ.pop("CUDA_VISIBLE_DEVICES", None)
        else:
            os.environ["CUDA_VISIBLE_DEVICES"] = old_cuda
        if old_order is None:
            os.environ.pop("CUDA_DEVICE_ORDER", None)
        else:
            os.environ["CUDA_DEVICE_ORDER"] = old_order


if __name__ == "__main__":
    raise SystemExit(main())
