#!/usr/bin/env python3
"""Reproduce CR-20: a client ABORT can be dropped before JobExecutor registers a start.

The test uses the normal client-side START_JOB and ABORT request processors.  A
timing gate is installed as an FLComponent at BEFORE_JOB_LAUNCH, before
JobExecutor.start_app inserts the pending STARTING handle into run_processes.
No NVFlare source is modified.
"""

import copy
import json
import logging
import os
import signal
import shlex
import sys
import tempfile
import threading
import time
from pathlib import Path
from types import SimpleNamespace

SOURCE = Path(
    "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/"
    "nvflare-job/.specula-output/confirmation/CR-20/worktree"
)
sys.path.insert(0, str(SOURCE))

from nvflare.apis.event_type import EventType  # noqa: E402
from nvflare.apis.fl_component import FLComponent  # noqa: E402
from nvflare.apis.fl_constant import FLContextKey, JobConstants, MachineStatus, RunProcessKey, SystemComponents  # noqa: E402
from nvflare.apis.fl_context import FLContextManager  # noqa: E402
from nvflare.apis.job_launcher_spec import add_launcher  # noqa: E402
from nvflare.apis.workspace import Workspace  # noqa: E402
from nvflare.app_common.job_launcher.process_launcher import ProcessJobLauncher  # noqa: E402
from nvflare.app_common.resource_consumers.list_resource_consumer import ListResourceConsumer  # noqa: E402
from nvflare.app_common.resource_managers.list_resource_manager import ListResourceManager  # noqa: E402
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey, ReturnCode  # noqa: E402
from nvflare.fuel.f3.message import Message as CellMessage  # noqa: E402
from nvflare.private.admin_defs import Message  # noqa: E402
from nvflare.private.defs import RequestHeader, TrainingTopic  # noqa: E402
from nvflare.private.fed.client.client_engine import ClientEngine  # noqa: E402
from nvflare.private.fed.client.client_executor import JobExecutor  # noqa: E402
from nvflare.private.fed.client.scheduler_cmds import CheckResourceProcessor, StartJobProcessor  # noqa: E402
from nvflare.private.fed.client.training_cmds import AbortAppProcessor  # noqa: E402
from nvflare.private.scheduler_constants import ShareableHeader  # noqa: E402


logging.basicConfig(level=logging.WARNING, format="%(asctime)s %(levelname)s %(name)s %(message)s")


def ok_cell_reply():
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
        self.sent.append({"kind": "fire_and_forget", "topic": kwargs.get("topic"), "target": kwargs.get("targets")})

    def send_request(self, **kwargs):
        self.sent.append({"kind": "send_request", "topic": kwargs.get("topic"), "target": kwargs.get("target")})
        return ok_cell_reply()


class FakeClient:
    def __init__(self, components):
        self.client_name = "site-1"
        self.token = "token"
        self.token_signature = "sig"
        self.ssid = "ssid"
        self.cell = FakeCell()
        self.components = components
        self.engine = None
        self.secure_train = False
        self.multi_gpu = False
        self.reports = []

    def send_request_before_shutdown(self, **kwargs):
        self.reports.append(dict(kwargs["request"].payload))
        return ok_cell_reply()


class GateableProcessLauncher(ProcessJobLauncher):
    def __init__(self, workspace_root, *, gate_before_registration=False, gate_in_launch=False):
        super().__init__()
        self.workspace_root = Path(workspace_root)
        self.gate_before_registration = gate_before_registration
        self.gate_in_launch = gate_in_launch
        self.before_registration_reached = threading.Event()
        self.before_registration_release = threading.Event()
        self.launch_reached = threading.Event()
        self.launch_release = threading.Event()
        self.pids = []

    def handle_event(self, event_type: str, fl_ctx):
        if event_type == EventType.BEFORE_JOB_LAUNCH:
            if self.gate_before_registration:
                self.before_registration_reached.set()
                self.before_registration_release.wait(10.0)
            add_launcher(self, fl_ctx)

    def get_command(self, job_meta, fl_ctx) -> str:
        job_id = job_meta[JobConstants.JOB_ID]
        out_path = self.workspace_root / f"child_{job_id}.json"
        child_code = (
            "import json, os, time; "
            f"open({str(out_path)!r}, 'w', encoding='utf-8').write(json.dumps({{'pid': os.getpid()}})); "
            "time.sleep(60)"
        )
        return f"{shlex.quote(sys.executable)} -c {shlex.quote(child_code)}"

    def launch_job(self, job_meta: dict, fl_ctx):
        if self.gate_in_launch:
            self.launch_reached.set()
            self.launch_release.wait(10.0)
        handle = super().launch_job(job_meta, fl_ctx)
        self.pids.append(handle.adapter.pid)
        return handle


def make_engine(workspace_root, launcher):
    rm = ListResourceManager({"gpu": [0]}, expiration_period=300)
    consumer = ListResourceConsumer()
    components = {
        SystemComponents.RESOURCE_MANAGER: rm,
        SystemComponents.RESOURCE_CONSUMER: consumer,
    }
    client = FakeClient(components)
    engine = ClientEngine.__new__(ClientEngine)
    engine.client = client
    engine.client_name = client.client_name
    engine.args = SimpleNamespace(workspace=str(workspace_root), set=[])
    engine.rank = 0
    engine.logger = logging.getLogger("ClientEngine(repro)")
    engine.client_executor = JobExecutor(client, os.path.join(str(workspace_root), "startup"))
    engine.admin_agent = None
    engine.cell = None
    engine.object_streamer = None
    engine.status = MachineStatus.STOPPED
    workspace = Workspace(str(workspace_root), site_name=client.client_name)
    engine.fl_ctx_mgr = FLContextManager(
        engine=engine,
        identity_name=client.client_name,
        job_id="",
        public_stickers={},
        private_stickers={
            FLContextKey.WORKSPACE_OBJECT: workspace,
            FLContextKey.SERVER_CONFIG: [{"service": {"scheme": "tcp", "target": "127.0.0.1:1"}}],
            FLContextKey.ARGS: engine.args,
            FLContextKey.WORKSPACE_ROOT: str(workspace_root),
        },
    )
    engine.fl_components = [launcher]
    client.engine = engine
    return engine, rm


def deploy_minimal_job(workspace_root, job_id, job_meta):
    for name in ("startup", "local"):
        (workspace_root / name).mkdir(parents=True, exist_ok=True)
    workspace = Workspace(str(workspace_root), site_name="site-1")
    Path(workspace.get_app_custom_dir(job_id)).mkdir(parents=True, exist_ok=True)
    Path(workspace.get_app_config_dir(job_id)).mkdir(parents=True, exist_ok=True)
    with open(workspace.get_job_meta_path(job_id), "w", encoding="utf-8") as f:
        json.dump(job_meta, f)


def check_resources(engine, job_id, resource_spec):
    req = Message(topic=TrainingTopic.CHECK_RESOURCE, body=resource_spec)
    req.set_header(RequestHeader.JOB_ID, job_id)
    reply = CheckResourceProcessor().process(req, engine)
    return reply.body.get_header(ShareableHeader.IS_RESOURCE_ENOUGH), reply.body.get_header(
        ShareableHeader.RESOURCE_RESERVE_TOKEN
    )


def start_job(engine, job_meta, resource_spec, token):
    req = Message(topic=TrainingTopic.START_JOB, body=resource_spec)
    req.set_header(RequestHeader.JOB_ID, job_meta[JobConstants.JOB_ID])
    req.set_header(RequestHeader.JOB_META, copy.deepcopy(job_meta))
    req.set_header(ShareableHeader.RESOURCE_RESERVE_TOKEN, token)
    return StartJobProcessor().process(req, engine).body


def abort_job(engine, job_id):
    req = Message(topic=TrainingTopic.ABORT, body="")
    req.set_header(RequestHeader.JOB_ID, job_id)
    return AbortAppProcessor().process(req, engine).body


def read_child(workspace_root, job_id, timeout=5.0):
    path = workspace_root / f"child_{job_id}.json"
    end = time.time() + timeout
    while time.time() < end:
        if path.exists():
            with open(path, encoding="utf-8") as f:
                return json.load(f)
        time.sleep(0.05)
    return None


def pid_alive(pid):
    if not pid:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    try:
        with open(f"/proc/{pid}/stat", encoding="utf-8") as f:
            state = f.read().split(")")[-1].split()[0]
        return state != "Z"
    except FileNotFoundError:
        return False


def registered_jobs(engine):
    with engine.client_executor.lock:
        return {
            job_id: data.get(RunProcessKey.STATUS)
            for job_id, data in engine.client_executor.run_processes.items()
        }


def wait_unregistered(engine, job_id, timeout=10.0):
    end = time.time() + timeout
    while time.time() < end:
        if job_id not in registered_jobs(engine):
            return True
        time.sleep(0.05)
    return False


def cleanup(engine, launcher, job_id):
    try:
        engine.abort_app(job_id, heartbeat_cleanup=True)
    except Exception:
        pass
    wait_unregistered(engine, job_id, timeout=10.0)
    for pid in launcher.pids:
        if pid_alive(pid):
            try:
                os.killpg(os.getpgid(pid), signal.SIGKILL)
            except Exception:
                pass


def scenario_level0_control():
    with tempfile.TemporaryDirectory(prefix="cr20-l0-") as tmp:
        workspace_root = Path(tmp)
        job_id = "job-l0"
        job_meta = {JobConstants.JOB_ID: job_id, "resource_spec": {"site-1": {"gpu": 1}}}
        deploy_minimal_job(workspace_root, job_id, job_meta)
        launcher = GateableProcessLauncher(workspace_root)
        engine, rm = make_engine(workspace_root, launcher)
        ok, token = check_resources(engine, job_id, {"gpu": 1})
        start_reply = start_job(engine, job_meta, {"gpu": 1}, token)
        child = read_child(workspace_root, job_id)
        abort_reply = abort_job(engine, job_id)
        wait_unregistered(engine, job_id, timeout=10.0)
        alive_after_abort = pid_alive(child["pid"]) if child else False
        result = {
            "resource_check_ok": ok,
            "start_reply": start_reply,
            "abort_reply": abort_reply,
            "child_started": bool(child),
            "child_alive_after_abort": alive_after_abort,
            "registered_after_abort": registered_jobs(engine),
            "rm_resources": rm.report_resources(None),
        }
        cleanup(engine, launcher, job_id)
        return result


def scenario_level1_bug():
    with tempfile.TemporaryDirectory(prefix="cr20-l1-bug-") as tmp:
        workspace_root = Path(tmp)
        job_id = "job-l1-bug"
        job_meta = {JobConstants.JOB_ID: job_id, "resource_spec": {"site-1": {"gpu": 1}}}
        deploy_minimal_job(workspace_root, job_id, job_meta)
        launcher = GateableProcessLauncher(workspace_root, gate_before_registration=True)
        engine, rm = make_engine(workspace_root, launcher)
        ok, token = check_resources(engine, job_id, {"gpu": 1})
        holder = {}
        th = threading.Thread(target=lambda: holder.setdefault("start_reply", start_job(engine, job_meta, {"gpu": 1}, token)))
        th.start()
        if not launcher.before_registration_reached.wait(10.0):
            raise RuntimeError("START did not reach BEFORE_JOB_LAUNCH gate")
        state_at_abort = {
            "registered": registered_jobs(engine),
            "rm_resources": rm.report_resources(None),
        }
        abort_reply = abort_job(engine, job_id)
        state_after_abort = {"registered": registered_jobs(engine)}
        launcher.before_registration_release.set()
        th.join(10.0)
        child = read_child(workspace_root, job_id)
        time.sleep(0.5)
        alive_after_late_start = pid_alive(child["pid"]) if child else False
        result = {
            "resource_check_ok": ok,
            "state_at_abort": state_at_abort,
            "abort_reply": abort_reply,
            "state_after_abort": state_after_abort,
            "start_reply": holder.get("start_reply"),
            "child_started_after_abort": bool(child),
            "child_alive_after_late_start": alive_after_late_start,
            "registered_after_late_start": registered_jobs(engine),
            "cp_to_cj_messages": list(engine.client.cell.sent),
        }
        cleanup(engine, launcher, job_id)
        result["after_cleanup"] = {
            "registered": registered_jobs(engine),
            "rm_resources": rm.report_resources(None),
            "reports": list(engine.client.reports),
        }
        return result


def scenario_level1_fixed_control():
    with tempfile.TemporaryDirectory(prefix="cr20-l1-control-") as tmp:
        workspace_root = Path(tmp)
        job_id = "job-l1-control"
        job_meta = {JobConstants.JOB_ID: job_id, "resource_spec": {"site-1": {"gpu": 1}}}
        deploy_minimal_job(workspace_root, job_id, job_meta)
        launcher = GateableProcessLauncher(workspace_root, gate_in_launch=True)
        engine, rm = make_engine(workspace_root, launcher)
        ok, token = check_resources(engine, job_id, {"gpu": 1})
        holder = {}
        th = threading.Thread(target=lambda: holder.setdefault("start_reply", start_job(engine, job_meta, {"gpu": 1}, token)))
        th.start()
        if not launcher.launch_reached.wait(10.0):
            raise RuntimeError("START did not reach launch_job gate")
        state_at_abort = {
            "registered": registered_jobs(engine),
            "rm_resources": rm.report_resources(None),
        }
        abort_reply = abort_job(engine, job_id)
        launcher.launch_release.set()
        th.join(10.0)
        child = read_child(workspace_root, job_id)
        wait_unregistered(engine, job_id, timeout=10.0)
        result = {
            "resource_check_ok": ok,
            "state_at_abort": state_at_abort,
            "abort_reply": abort_reply,
            "start_reply": holder.get("start_reply"),
            "child_started": bool(child),
            "child_alive_after_pending_abort": pid_alive(child["pid"]) if child else False,
            "registered_after_pending_abort": registered_jobs(engine),
            "rm_resources": rm.report_resources(None),
        }
        cleanup(engine, launcher, job_id)
        return result


def main():
    import nvflare

    report = {
        "nvflare_import": nvflare.__file__,
        "source": str(SOURCE),
        "level0_control_no_timing": scenario_level0_control(),
        "level1_abort_before_registration": scenario_level1_bug(),
        "level1_control_abort_after_registration": scenario_level1_fixed_control(),
    }
    print(json.dumps(report, indent=2, default=str))

    bug = report["level1_abort_before_registration"]
    control = report["level1_control_abort_after_registration"]
    if not bug["child_alive_after_late_start"]:
        raise SystemExit("BUG NOT TRIGGERED: child was not alive after abort-before-registration")
    if control["child_alive_after_pending_abort"]:
        raise SystemExit("CONTROL FAILED: pending-handle abort after registration did not kill child")
    print("CR-20 REPRODUCED: Level 1 abort before registration was dropped and the late child stayed alive.")


if __name__ == "__main__":
    main()
