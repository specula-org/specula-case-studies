#!/usr/bin/env python3
"""Reproduce CR-11 with real NVFlare resource processors and process launcher.

The test stubs only host GPU discovery/free-memory readings so it can run on a
non-GPU confirmation host. The race itself uses the pinned implementation:
CheckResourceProcessor, StartJobProcessor, GPUResourceManager,
GPUResourceConsumer, and ProcessJobLauncher.
"""

import json
import os
import shlex
import sys
import tempfile
import threading
from pathlib import Path

SOURCE_ROOT = Path(
    "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/"
    "gpt-continuation/nvflare-job/.specula-output/confirmation/CR-11/worktree"
)
if str(SOURCE_ROOT) not in sys.path:
    sys.path.insert(0, str(SOURCE_ROOT))

from nvflare.apis.fl_constant import FLContextKey, JobConstants, ReservedKey, SystemComponents
from nvflare.apis.fl_context import FLContext
from nvflare.app_common.job_launcher.process_launcher import ProcessJobLauncher
from nvflare.app_common.resource_consumers.gpu_resource_consumer import GPUResourceConsumer
import nvflare.app_common.resource_consumers.gpu_resource_consumer as gpu_consumer_mod
from nvflare.app_common.resource_managers.gpu_resource_manager import GPUResourceManager
from nvflare.private.admin_defs import Message
from nvflare.private.defs import RequestHeader, TrainingTopic
from nvflare.private.fed.client.client_engine_internal_spec import ClientEngineInternalSpec
from nvflare.private.fed.client.scheduler_cmds import CheckResourceProcessor, StartJobProcessor
from nvflare.private.scheduler_constants import ShareableHeader


RESOURCE_SPEC = {"num_of_gpus": 1, "mem_per_gpu_in_GiB": 16}


class ContextFactory:
    def __init__(self, engine):
        self.engine = engine
        self.ctx = None

    def __enter__(self):
        self.ctx = FLContext()
        self.ctx.put(ReservedKey.ENGINE, self.engine, private=True, sticky=False)
        return self.ctx

    def __exit__(self, exc_type, exc, tb):
        return False


class FakeWorkspace:
    def get_app_custom_dir(self, job_id):
        return ""


class EnvCaptureLauncher(ProcessJobLauncher):
    def __init__(self, helper_path: Path, output_dir: Path):
        super().__init__()
        self.helper_path = helper_path
        self.output_dir = output_dir

    def get_command(self, job_meta: dict, fl_ctx: FLContext):
        job_id = job_meta[JobConstants.JOB_ID]
        return "{} {} {} {}".format(
            shlex.quote(sys.executable),
            shlex.quote(str(self.helper_path)),
            shlex.quote(str(self.output_dir)),
            shlex.quote(job_id),
        )


class RecordingGPUResourceConsumer(GPUResourceConsumer):
    def __init__(self, b_consumed_event=None):
        super().__init__()
        self.b_consumed_event = b_consumed_event
        self.records = []
        self.lock = threading.Lock()

    def consume(self, resources: dict):
        super().consume(resources)
        cuda = os.environ.get("CUDA_VISIBLE_DEVICES")
        keys = tuple(resources.keys())
        with self.lock:
            self.records.append({"resources": list(keys), "cuda": cuda})
        if self.b_consumed_event is not None and keys == (1,):
            self.b_consumed_event.set()


class FakeClientEngine(ClientEngineInternalSpec):
    def __init__(self, launcher, resource_manager, resource_consumer, gate_first_job=False):
        self.launcher = launcher
        self.resource_manager = resource_manager
        self.resource_consumer = resource_consumer
        self.gate_first_job = gate_first_job
        self.workspace = FakeWorkspace()
        self.handles = {}
        self.allocated = {}
        self.a_entered_start_app = threading.Event()
        self.b_consumed = resource_consumer.b_consumed_event or threading.Event()

    def new_context(self):
        return ContextFactory(self)

    def get_component(self, component_id):
        if component_id == SystemComponents.RESOURCE_MANAGER:
            return self.resource_manager
        if component_id == SystemComponents.RESOURCE_CONSUMER:
            return self.resource_consumer
        return None

    def add_component(self, component_id: str, component):
        if component_id == SystemComponents.RESOURCE_MANAGER:
            self.resource_manager = component
        elif component_id == SystemComponents.RESOURCE_CONSUMER:
            self.resource_consumer = component

    def start_app(
        self,
        job_id: str,
        job_meta: dict,
        allocated_resource=None,
        token=None,
        resource_manager=None,
    ) -> str:
        self.allocated[job_id] = dict(allocated_resource or {})
        with self.new_context() as fl_ctx:
            fl_ctx.set_prop(FLContextKey.WORKSPACE_OBJECT, self.workspace, private=True, sticky=False)
            fl_ctx.set_prop(FLContextKey.JOB_PROCESS_ARGS, {}, private=True, sticky=False)

            if self.gate_first_job and job_id == "job-A":
                self.a_entered_start_app.set()
                if not self.b_consumed.wait(timeout=10):
                    raise RuntimeError("timing gate timed out waiting for job-B consumer")

            self.handles[job_id] = self.launcher.launch_job(job_meta, fl_ctx)
        return "OK"

    def fire_event(self, event_type: str, fl_ctx: FLContext):
        return None

    def get_engine_status(self):
        return "running"

    def get_client_name(self) -> str:
        return "site-1"

    def deploy_app(self, app_name: str, job_id: str, job_meta: dict, client_name: str, app_data) -> str:
        return ""

    def notify_job_status(self, job_id: str, job_status):
        return None

    def abort_app(self, job_id: str) -> str:
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
        return list(self.handles.keys())


def make_child_helper(tmpdir: Path) -> Path:
    helper = tmpdir / "capture_cuda_env.py"
    helper.write_text(
        "\n".join(
            [
                "import json, os, sys",
                "from pathlib import Path",
                "out_dir = Path(sys.argv[1])",
                "job_id = sys.argv[2]",
                "payload = {'job_id': job_id, 'cuda_visible_devices': os.environ.get('CUDA_VISIBLE_DEVICES')}",
                "(out_dir / (job_id + '.json')).write_text(json.dumps(payload, sort_keys=True))",
            ]
        )
        + "\n"
    )
    return helper


def reserve_job(engine, job_id):
    req = Message(topic=TrainingTopic.CHECK_RESOURCE, body=dict(RESOURCE_SPEC))
    req.set_header(RequestHeader.JOB_ID, job_id)
    reply = CheckResourceProcessor().process(req, engine)
    enough = reply.body.get_header(ShareableHeader.IS_RESOURCE_ENOUGH)
    token = reply.body.get_header(ShareableHeader.RESOURCE_RESERVE_TOKEN)
    if not enough:
        raise RuntimeError(f"{job_id}: resource check failed; token/reason={token!r}")
    return token


def start_job(engine, job_id, token):
    job_meta = {JobConstants.JOB_ID: job_id}
    req = Message(topic=TrainingTopic.START_JOB, body=dict(RESOURCE_SPEC))
    req.set_header(RequestHeader.JOB_ID, job_id)
    req.set_header(RequestHeader.JOB_META, job_meta)
    req.set_header(ShareableHeader.RESOURCE_RESERVE_TOKEN, token)
    reply = StartJobProcessor().process(req, engine)
    if isinstance(reply.body, str) and reply.body.startswith("ERROR"):
        raise RuntimeError(f"{job_id}: {reply.body}")
    return reply.body


def wait_for_children(engine):
    for handle in engine.handles.values():
        handle.wait()


def read_child_results(output_dir: Path):
    result = {}
    for path in sorted(output_dir.glob("job-*.json")):
        data = json.loads(path.read_text())
        result[data["job_id"]] = data["cuda_visible_devices"]
    return result


def build_engine(tmpdir: Path, output_dir: Path, gate_first_job: bool):
    b_consumed = threading.Event()
    launcher = EnvCaptureLauncher(make_child_helper(tmpdir), output_dir)
    resource_manager = GPUResourceManager(num_of_gpus=2, mem_per_gpu_in_GiB=16, ignore_host=True)
    resource_consumer = RecordingGPUResourceConsumer(b_consumed_event=b_consumed)
    return FakeClientEngine(
        launcher=launcher,
        resource_manager=resource_manager,
        resource_consumer=resource_consumer,
        gate_first_job=gate_first_job,
    )


def run_level0(tmpdir: Path):
    output_dir = tmpdir / "level0"
    output_dir.mkdir()
    engine = build_engine(tmpdir, output_dir, gate_first_job=False)
    token_a = reserve_job(engine, "job-A")
    token_b = reserve_job(engine, "job-B")

    barrier = threading.Barrier(3)
    errors = []

    def target(job_id, token):
        try:
            barrier.wait(timeout=5)
            start_job(engine, job_id, token)
        except Exception as exc:
            errors.append(f"{job_id}: {exc}")

    thread_a = threading.Thread(target=target, args=("job-A", token_a))
    thread_b = threading.Thread(target=target, args=("job-B", token_b))
    thread_a.start()
    thread_b.start()
    barrier.wait(timeout=5)
    thread_a.join(timeout=10)
    thread_b.join(timeout=10)
    if thread_a.is_alive() or thread_b.is_alive():
        errors.append("level0 thread join timed out")
    if errors:
        raise RuntimeError("; ".join(errors))
    wait_for_children(engine)
    return engine, read_child_results(output_dir)


def run_level1(tmpdir: Path):
    output_dir = tmpdir / "level1"
    output_dir.mkdir()
    engine = build_engine(tmpdir, output_dir, gate_first_job=True)
    token_a = reserve_job(engine, "job-A")
    token_b = reserve_job(engine, "job-B")
    errors = []

    def run_a():
        try:
            start_job(engine, "job-A", token_a)
        except Exception as exc:
            errors.append(f"job-A: {exc}")

    thread_a = threading.Thread(target=run_a)
    thread_a.start()
    if not engine.a_entered_start_app.wait(timeout=10):
        raise RuntimeError("job-A did not reach timing gate")

    try:
        start_job(engine, "job-B", token_b)
    except Exception as exc:
        errors.append(f"job-B: {exc}")

    thread_a.join(timeout=10)
    if thread_a.is_alive():
        errors.append("job-A thread join timed out")
    if errors:
        raise RuntimeError("; ".join(errors))
    wait_for_children(engine)
    return engine, read_child_results(output_dir)


def format_alloc(engine, job_id):
    return ",".join(str(k) for k in engine.allocated[job_id].keys())


def main():
    original_cuda = os.environ.get("CUDA_VISIBLE_DEVICES")
    original_ids = gpu_consumer_mod.get_host_gpu_ids
    original_free = gpu_consumer_mod.get_host_gpu_memory_free
    gpu_consumer_mod.get_host_gpu_ids = lambda: [0, 1]
    gpu_consumer_mod.get_host_gpu_memory_free = lambda unit="MiB": [16 * 1024, 16 * 1024]

    try:
        with tempfile.TemporaryDirectory(prefix="cr11-cuda-env-") as tmp:
            tmpdir = Path(tmp)
            print(f"SOURCE_IMPORT={SOURCE_ROOT / 'nvflare' / '__init__.py'}")
            print("GPU_HOST_STUB=ids:[0,1] free_mib:[16384,16384]")

            level0_engine, level0_child = run_level0(tmpdir)
            level0_a_expected = format_alloc(level0_engine, "job-A")
            level0_b_expected = format_alloc(level0_engine, "job-B")
            level0_mismatch = (
                level0_child.get("job-A") != level0_a_expected
                or level0_child.get("job-B") != level0_b_expected
            )
            print(
                "LEVEL0 normal concurrent start: "
                f"job-A allocated={level0_a_expected} child_cuda={level0_child.get('job-A')}; "
                f"job-B allocated={level0_b_expected} child_cuda={level0_child.get('job-B')}; "
                f"mismatch={level0_mismatch}"
            )

            level1_engine, level1_child = run_level1(tmpdir)
            level1_a_expected = format_alloc(level1_engine, "job-A")
            level1_b_expected = format_alloc(level1_engine, "job-B")
            a_wrong = level1_child.get("job-A") != level1_a_expected
            b_ok = level1_child.get("job-B") == level1_b_expected
            print(
                "LEVEL1 timing-assisted overlap: "
                f"job-A allocated={level1_a_expected} child_cuda={level1_child.get('job-A')}; "
                f"job-B allocated={level1_b_expected} child_cuda={level1_child.get('job-B')}; "
                f"job-A_mismatch={a_wrong}; job-B_matches={b_ok}"
            )
            print(
                "CONSUMER_RECORDS="
                + json.dumps(level1_engine.resource_consumer.records, sort_keys=True, separators=(",", ":"))
            )

            if a_wrong and b_ok:
                print("BUG TRIGGERED: job-A inherited job-B CUDA_VISIBLE_DEVICES through ProcessJobLauncher")
                print("ESCALATION: Level 1 timing assistance only; Level 2/3 not used")
                return 0

            print("BUG NOT TRIGGERED")
            return 1
    finally:
        gpu_consumer_mod.get_host_gpu_ids = original_ids
        gpu_consumer_mod.get_host_gpu_memory_free = original_free
        if original_cuda is None:
            os.environ.pop("CUDA_VISIBLE_DEVICES", None)
        else:
            os.environ["CUDA_VISIBLE_DEVICES"] = original_cuda


if __name__ == "__main__":
    raise SystemExit(main())
