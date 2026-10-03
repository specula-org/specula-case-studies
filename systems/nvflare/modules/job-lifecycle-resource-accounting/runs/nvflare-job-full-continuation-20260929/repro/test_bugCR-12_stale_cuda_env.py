#!/usr/bin/env python3
"""CR-12 reproduction: empty-resource jobs inherit stale CUDA_VISIBLE_DEVICES.

This exercises the real client CHECK_RESOURCE/START_JOB processors, real
GPUResourceManager/GPUResourceConsumer, real ClientEngine.start_app /
JobExecutor path, and real ProcessJobLauncher.launch_job environment copy.

The only injected edge is the GPU hardware probe: this CI/container host has no
real GPUs, so the nvidia-smi helper functions are stubbed to represent a normal
two-GPU client site. Product source logic is not patched.
"""

import json
import logging
import os
import signal
import sys
import tempfile
import threading
import time
from pathlib import Path
from types import SimpleNamespace


SPECULA_OUTPUT = Path(__file__).resolve().parents[1]
SOURCE = SPECULA_OUTPUT / "confirmation" / "CR-12" / "worktree"
sys.path.insert(0, str(SOURCE))

import nvflare.app_common.resource_consumers.gpu_resource_consumer as gpu_consumer_mod  # noqa: E402
from nvflare.apis.event_type import EventType  # noqa: E402
from nvflare.apis.fl_component import FLComponent  # noqa: E402
from nvflare.apis.fl_constant import FLContextKey, MachineStatus, SystemComponents  # noqa: E402
from nvflare.apis.fl_context import FLContextManager  # noqa: E402
from nvflare.apis.workspace import Workspace  # noqa: E402
from nvflare.app_common.job_launcher.process_launcher import ProcessJobLauncher  # noqa: E402
from nvflare.app_common.resource_consumers.gpu_resource_consumer import GPUResourceConsumer  # noqa: E402
from nvflare.app_common.resource_managers.gpu_resource_manager import GPUResourceManager  # noqa: E402
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey, ReturnCode  # noqa: E402
from nvflare.fuel.f3.message import Message as CellMessage  # noqa: E402
from nvflare.private.admin_defs import Message  # noqa: E402
from nvflare.private.defs import RequestHeader, TrainingTopic  # noqa: E402
from nvflare.private.fed.client.client_engine import ClientEngine  # noqa: E402
from nvflare.private.fed.client.client_executor import JobExecutor  # noqa: E402
from nvflare.private.fed.client.scheduler_cmds import CheckResourceProcessor, StartJobProcessor  # noqa: E402
from nvflare.private.scheduler_constants import ShareableHeader  # noqa: E402
from nvflare.utils.job_launcher_utils import get_resource_manager_spec  # noqa: E402


logging.basicConfig(level=logging.WARNING)
SPAWNED_PIDS = []


def ok_reply():
    msg = CellMessage()
    msg.set_header(MessageHeaderKey.RETURN_CODE, ReturnCode.OK)
    return msg


class FakeCell:
    def __init__(self):
        self.sent = []

    def get_internal_listener_url(self):
        return "tcp://127.0.0.1:1"

    def get_internal_listener_params(self):
        return {}

    def get_fqcn(self):
        return "site-1"

    def fire_and_forget(self, **kwargs):
        self.sent.append({"kind": "fire_and_forget", "topic": kwargs.get("topic")})
        return {}

    def send_request(self, **kwargs):
        self.sent.append({"kind": "send_request", "topic": kwargs.get("topic")})
        return ok_reply()


class FakeFedClient:
    def __init__(self, components):
        self.client_name = "site-1"
        self.token = "token"
        self.token_signature = "sig"
        self.ssid = "ssid"
        self.cell = FakeCell()
        self.components = components
        self.engine = None
        self.secure_train = False
        self.status = None
        self.reports = []
        self.communicator = SimpleNamespace(heartbeat_done=False)

    def send_request_before_shutdown(self, **kwargs):
        self.reports.append(dict(kwargs["request"].payload))
        return ok_reply()


class EnvCaptureLauncher(ProcessJobLauncher):
    def __init__(self, child_script, out_dir):
        super().__init__()
        self.child_script = child_script
        self.out_dir = out_dir

    def get_command(self, job_meta, fl_ctx):
        job_id = job_meta["job_id"]
        out = self.out_dir / f"{job_id}.json"
        return f"{sys.executable} {self.child_script} {out} 0.15"

    def launch_job(self, job_meta, fl_ctx):
        handle = super().launch_job(job_meta, fl_ctx)
        SPAWNED_PIDS.append(handle.adapter.pid)
        return handle


def write_child_script(root):
    child = root / "record_env_child.py"
    child.write_text(
        "import json, os, sys, time\n"
        "out = sys.argv[1]\n"
        "sleep_s = float(sys.argv[2])\n"
        "with open(out, 'w') as f:\n"
        "    json.dump({'CUDA_VISIBLE_DEVICES': os.environ.get('CUDA_VISIBLE_DEVICES', '<unset>'), 'pid': os.getpid()}, f)\n"
        "time.sleep(sleep_s)\n",
        encoding="utf-8",
    )
    return child


def make_engine(workspace_root, resource_manager, resource_consumer, launcher):
    (workspace_root / "startup").mkdir(parents=True, exist_ok=True)
    (workspace_root / "local").mkdir(parents=True, exist_ok=True)

    components = {
        SystemComponents.RESOURCE_MANAGER: resource_manager,
        SystemComponents.RESOURCE_CONSUMER: resource_consumer,
    }
    client = FakeFedClient(components)

    engine = ClientEngine.__new__(ClientEngine)
    engine.client = client
    engine.client_name = client.client_name
    engine.args = SimpleNamespace(workspace=str(workspace_root), set=[])
    engine.rank = 0
    engine.logger = logging.getLogger("CR12ClientEngine")
    engine.client_executor = JobExecutor(client, str(workspace_root / "startup"))
    engine.admin_agent = None
    engine.cell = None
    engine.object_streamer = None
    engine.status = MachineStatus.STOPPED
    engine.fl_components = [component for component in (resource_manager, launcher) if isinstance(component, FLComponent)]
    engine.fl_ctx_mgr = FLContextManager(
        engine=engine,
        identity_name=client.client_name,
        job_id="",
        public_stickers={},
        private_stickers={
            FLContextKey.WORKSPACE_OBJECT: Workspace(str(workspace_root), site_name=client.client_name),
            FLContextKey.SERVER_CONFIG: [{"service": {"scheme": "tcp", "target": "127.0.0.1:1"}}],
            FLContextKey.ARGS: engine.args,
            FLContextKey.WORKSPACE_ROOT: str(workspace_root),
        },
    )
    client.engine = engine
    return engine


def deploy(workspace_root, job_meta):
    job_id = job_meta["job_id"]
    workspace = Workspace(str(workspace_root), site_name="site-1")
    app_dir = Path(workspace.get_app_dir(job_id))
    (app_dir / "custom").mkdir(parents=True, exist_ok=True)
    (app_dir / "config").mkdir(parents=True, exist_ok=True)
    Path(workspace.get_job_meta_path(job_id)).write_text(json.dumps(job_meta, indent=2), encoding="utf-8")


def check(engine, job_id, spec):
    req = Message(topic=TrainingTopic.CHECK_RESOURCE, body=spec)
    req.set_header(RequestHeader.JOB_ID, job_id)
    reply = CheckResourceProcessor().process(req, engine)
    return (
        reply.body.get_header(ShareableHeader.IS_RESOURCE_ENOUGH),
        reply.body.get_header(ShareableHeader.RESOURCE_RESERVE_TOKEN),
    )


def start(engine, job_meta, spec, token):
    req = Message(topic=TrainingTopic.START_JOB, body=spec)
    req.set_header(RequestHeader.JOB_ID, job_meta["job_id"])
    req.set_header(RequestHeader.JOB_META, job_meta)
    req.set_header(ShareableHeader.RESOURCE_RESERVE_TOKEN, token)
    return StartJobProcessor().process(req, engine).body


def wait_for_child(out_dir, job_id, timeout_s=5.0):
    path = out_dir / f"{job_id}.json"
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if path.exists():
            try:
                return json.loads(path.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                pass
        time.sleep(0.02)
    raise TimeoutError(f"child record not written for {job_id}")


def wait_until(predicate, timeout_s=5.0):
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.02)
    return False


def running_jobs(engine):
    with engine.client_executor.lock:
        return set(engine.client_executor.run_processes)


def run_job(engine, workspace_root, out_dir, job_meta):
    job_id = job_meta["job_id"]
    spec = get_resource_manager_spec(job_meta, "site-1")
    deploy(workspace_root, job_meta)
    ok, token = check(engine, job_id, spec)
    if not ok:
        raise AssertionError(f"resource check unexpectedly failed for {job_id}: {token}")
    reply = start(engine, job_meta, spec, token)
    try:
        child = wait_for_child(out_dir, job_id)
    except TimeoutError as e:
        raise TimeoutError(
            f"{e}; start_reply={reply!r}; running_jobs={sorted(running_jobs(engine))}; "
            f"child_outputs={sorted(p.name for p in out_dir.glob('*.json'))}"
        ) from e
    if not wait_until(lambda: job_id not in running_jobs(engine), timeout_s=10.0):
        raise AssertionError(f"{job_id} did not finish")
    return {"rm_spec": spec, "start_reply": reply, "child": child, "parent_env_after": os.environ.get("CUDA_VISIBLE_DEVICES", "<unset>")}


def main():
    if not (SOURCE / "nvflare").is_dir():
        raise SystemExit(f"source tree not found: {SOURCE}")

    original_env = os.environ.get("CUDA_VISIBLE_DEVICES")
    os.environ.pop("CUDA_VISIBLE_DEVICES", None)

    # GPU hardware probe edge: simulate an ordinary 2-GPU client host.
    gpu_consumer_mod.get_host_gpu_ids = lambda: [0, 1]
    gpu_consumer_mod.get_host_gpu_memory_free = lambda unit="MiB": [16384.0, 16384.0]

    tmp = Path(tempfile.mkdtemp(prefix="cr12-stale-cuda-"))
    workspace_root = tmp / "workspace"
    out_dir = tmp / "children"
    out_dir.mkdir(parents=True)
    child_script = write_child_script(tmp)

    resource_manager = GPUResourceManager(num_of_gpus=2, mem_per_gpu_in_GiB=16, expiration_period=300, ignore_host=True)
    resource_consumer = GPUResourceConsumer()
    launcher = EnvCaptureLauncher(child_script=child_script, out_dir=out_dir)
    engine = make_engine(workspace_root, resource_manager, resource_consumer, launcher)

    try:
        engine.fire_event(EventType.SYSTEM_START, engine.new_context())

        # Control: if the GPU consumer is called with an empty allocation, it
        # writes the expected empty CUDA binding. The real START_JOB path skips
        # this call because {} is falsy.
        os.environ["CUDA_VISIBLE_DEVICES"] = "stale-control"
        resource_consumer.consume({})
        empty_consume_control = os.environ.get("CUDA_VISIBLE_DEVICES")
        assert empty_consume_control == ""
        os.environ.pop("CUDA_VISIBLE_DEVICES", None)

        zero_before = run_job(
            engine,
            workspace_root,
            out_dir,
            {"job_id": "job-zero-before", "resource_spec": {"site-1": {"num_of_gpus": 0, "mem_per_gpu_in_GiB": 0}}},
        )

        gpu_job = run_job(
            engine,
            workspace_root,
            out_dir,
            {"job_id": "job-gpu", "resource_spec": {"site-1": {"num_of_gpus": 1, "mem_per_gpu_in_GiB": 16}}},
        )

        zero_after = run_job(
            engine,
            workspace_root,
            out_dir,
            {"job_id": "job-zero-after", "resource_spec": {"site-1": {"num_of_gpus": 0, "mem_per_gpu_in_GiB": 0}}},
        )

        summary = {
            "source": str(SOURCE),
            "hardware_probe_stub": "2 GPUs, 16 GiB each",
            "empty_consume_control": empty_consume_control,
            "zero_before": zero_before,
            "gpu_job": gpu_job,
            "zero_after": zero_after,
            "resource_report_after": resource_manager.report_resources(engine.new_context()),
        }

        print("CR-12 reproduction output")
        print(json.dumps(summary, indent=2, sort_keys=True, default=str))

        assert zero_before["rm_spec"] == {}, zero_before
        assert zero_before["child"]["CUDA_VISIBLE_DEVICES"] == "<unset>", zero_before
        assert gpu_job["child"]["CUDA_VISIBLE_DEVICES"] == "0", gpu_job
        assert gpu_job["parent_env_after"] == "0", gpu_job
        assert zero_after["rm_spec"] == {}, zero_after
        assert zero_after["child"]["CUDA_VISIBLE_DEVICES"] == "0", zero_after
        print("RESULT: REPRODUCED - later zero/empty-allocation job inherited stale CUDA_VISIBLE_DEVICES=0")
    finally:
        engine.fire_event(EventType.SYSTEM_END, engine.new_context())
        for pid in SPAWNED_PIDS:
            try:
                os.killpg(os.getpgid(pid), signal.SIGKILL)
            except Exception:
                pass
        if original_env is None:
            os.environ.pop("CUDA_VISIBLE_DEVICES", None)
        else:
            os.environ["CUDA_VISIBLE_DEVICES"] = original_env


if __name__ == "__main__":
    main()
