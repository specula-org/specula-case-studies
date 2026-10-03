#!/usr/bin/env python3
"""Phase-3 CP (client parent) lifetime harness -- extended copy of evidence/harness/client_harness.py.

REAL product code exercised (pinned checkout, unmodified):
  - scheduler_cmds: CheckResourceProcessor, StartJobProcessor, CancelResourceProcessor
  - training_cmds: AbortAppProcessor, NotifyJobStatusProcessor
  - ClientEngine.start_app / abort_app / notify_job_status / shutdown (instance built with __new__; only the
    attributes those methods read are set)
  - JobExecutor (whole start_app -> _PendingJobHandle -> launch -> attach -> _wait_child_process_finish -> free path,
    abort_app, _terminate_job)
  - ProcessJobLauncher.launch_job (os.environ.copy + spawn_process/posix_spawn(setsid) + ProcessHandle/ProcessAdapter)
  - ListResourceManager / GPUResourceManager(ignore_host=True) (AutoCleanResourceManager base incl. expiry thread),
    ListResourceConsumer / GPUResourceConsumer
  - ClientAppRunner.notify_job_status / stop (CJ side, for the K7 variant)
STUBS (edges only):
  - FakeCell / FakeFedClient: network edge (fire_and_forget / send_request / send_request_before_shutdown record and
    return OK); no server.
  - StubCmdLauncher.get_command: returns a command running child_stub.py instead of the CJ module (process edge).
  - gpu_resource_consumer.get_host_gpu_ids / get_host_gpu_memory_free: nvidia-smi edge (2 GPUs x 16 GiB).
REPRODUCTION CONTROLS (timing only): Gate components/hooks that block on threading.Event at
  BEFORE_JOB_LAUNCH (before STARTING registration) or inside launch_job (after registration, before spawn).
"""
import argparse
import copy
import json
import os
import signal
import sys
import tempfile
import threading
import time
import traceback
from types import SimpleNamespace

SOURCE = "/home/experiment/runs/specula/nvflare-lite-full-opus55-20260925/full/source"
HERE = os.path.dirname(os.path.abspath(__file__))
import nvflare  # noqa: E402

assert os.path.realpath(nvflare.__file__).startswith(SOURCE), nvflare.__file__

import logging  # noqa: E402

import nvflare.app_common.resource_consumers.gpu_resource_consumer as gpu_consumer_mod  # noqa: E402
from nvflare.apis.event_type import EventType  # noqa: E402
from nvflare.apis.fl_component import FLComponent  # noqa: E402
from nvflare.apis.fl_constant import FLContextKey, MachineStatus, SystemComponents  # noqa: E402
from nvflare.apis.fl_context import FLContextManager  # noqa: E402
from nvflare.apis.workspace import Workspace  # noqa: E402
from nvflare.app_common.job_launcher.process_launcher import ProcessJobLauncher  # noqa: E402
from nvflare.app_common.resource_consumers.gpu_resource_consumer import GPUResourceConsumer  # noqa: E402
from nvflare.app_common.resource_consumers.list_resource_consumer import ListResourceConsumer  # noqa: E402
from nvflare.app_common.resource_managers.gpu_resource_manager import GPUResourceManager  # noqa: E402
from nvflare.app_common.resource_managers.list_resource_manager import ListResourceManager  # noqa: E402
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey, ReturnCode  # noqa: E402
from nvflare.fuel.f3.message import Message as CellMessage  # noqa: E402
from nvflare.private.admin_defs import Message  # noqa: E402
from nvflare.private.defs import RequestHeader, TrainingTopic  # noqa: E402
from nvflare.private.fed.client.client_engine import ClientEngine  # noqa: E402
from nvflare.private.fed.client.client_executor import JobExecutor  # noqa: E402
from nvflare.private.fed.client.client_status import ClientStatus  # noqa: E402
from nvflare.private.fed.client.scheduler_cmds import (  # noqa: E402
    CancelResourceProcessor,
    CheckResourceProcessor,
    StartJobProcessor,
)
from nvflare.private.fed.client.training_cmds import AbortAppProcessor, NotifyJobStatusProcessor  # noqa: E402
from nvflare.private.scheduler_constants import ShareableHeader  # noqa: E402
from nvflare.utils.job_launcher_utils import get_resource_manager_spec  # noqa: E402

logging.basicConfig(level=logging.WARNING, format="%(asctime)s %(threadName)s %(name)s %(levelname)s %(message)s")
T0 = time.time()
SPAWNED = []  # pids to clean up at the end


def ts():
    return round(time.time() - T0, 3)


def ok_reply():
    m = CellMessage()
    m.set_header(MessageHeaderKey.RETURN_CODE, ReturnCode.OK)
    return m


class FakeCell:
    """Network edge: records CP->CJ/CP->server traffic."""

    def __init__(self):
        self.sent = []

    def get_internal_listener_url(self):
        return "tcp://127.0.0.1:1"

    def get_internal_listener_params(self):
        return {}

    def get_fqcn(self):
        return "site-1"

    def fire_and_forget(self, **kw):
        self.sent.append({"t": ts(), "kind": "fire_and_forget", "topic": kw.get("topic"), "targets": kw.get("targets")})
        return {}

    def send_request(self, **kw):
        self.sent.append({"t": ts(), "kind": "send_request", "topic": kw.get("topic"), "target": kw.get("target")})
        return ok_reply()


class FakeFedClient:
    def __init__(self, components):
        self.client_name = "site-1"
        self.token = "tok"
        self.token_signature = "sig"
        self.ssid = "ssid"
        self.cell = FakeCell()
        self.components = components
        self.engine = None
        self.reports = []
        self.communicator = SimpleNamespace(heartbeat_done=False)
        self.status = None
        self.secure_train = False

    def send_request_before_shutdown(self, **kw):
        self.reports.append({"t": ts(), "payload": dict(kw["request"].payload)})
        return ok_reply()

    def close(self):
        self.communicator.heartbeat_done = True
        return 0


class Gate(FLComponent):
    """Reproduction control: blocks the START_JOB thread at BEFORE_JOB_LAUNCH (i.e. before the STARTING entry is
    registered in JobExecutor.run_processes) until released."""

    def __init__(self):
        super().__init__()
        self.armed_for = set()
        self.reached = {}
        self.release = {}

    def arm(self, job_id):
        self.armed_for.add(job_id)
        self.reached[job_id] = threading.Event()
        self.release[job_id] = threading.Event()

    def handle_event(self, event_type, fl_ctx):
        if event_type == EventType.BEFORE_JOB_LAUNCH:
            meta = fl_ctx.get_prop(FLContextKey.JOB_META) or {}
            jid = meta.get("job_id")
            if jid in self.armed_for:
                self.reached[jid].set()
                self.release[jid].wait(30)


class StubCmdLauncher(ProcessJobLauncher):
    """Real ProcessJobLauncher.launch_job (env copy + spawn_process); only get_command is replaced (process edge).
    Optional in-launch gate = reproduction control after STARTING registration and before the spawn."""

    def __init__(self, out_dir, child_secs=30.0, grandchild_secs=0.0):
        super().__init__()
        self.out_dir = out_dir
        self.child_secs = child_secs
        self.grandchild_secs = grandchild_secs
        self.launch_gates = {}

    def arm_launch_gate(self, job_id):
        self.launch_gates[job_id] = (threading.Event(), threading.Event())
        return self.launch_gates[job_id]

    def get_command(self, job_meta, fl_ctx):
        jid = job_meta.get("job_id")
        out = os.path.join(self.out_dir, f"child_{jid}.json")
        cmd = f"{sys.executable} {os.path.join(HERE, 'child_stub.py')} {out} {self.child_secs}"
        if self.grandchild_secs:
            cmd += f" {self.grandchild_secs}"
        return cmd

    def launch_job(self, job_meta, fl_ctx):
        jid = job_meta.get("job_id")
        g = self.launch_gates.get(jid)
        if g:
            g[0].set()
            g[1].wait(30)
        h = super().launch_job(job_meta, fl_ctx)
        SPAWNED.append(h.adapter.pid)
        return h


def make_engine(ws_root, rm, consumer, extra_components=()):
    for d in ("startup", "local"):
        os.makedirs(os.path.join(ws_root, d), exist_ok=True)
    comps = {SystemComponents.RESOURCE_MANAGER: rm}
    if consumer is not None:
        comps[SystemComponents.RESOURCE_CONSUMER] = consumer
    client = FakeFedClient(comps)
    ce = ClientEngine.__new__(ClientEngine)
    ce.client = client
    ce.client_name = "site-1"
    ce.args = SimpleNamespace(workspace=ws_root, set=[])
    ce.rank = 0
    ce.logger = logging.getLogger("ClientEngine(harness)")
    ce.client_executor = JobExecutor(client, os.path.join(ws_root, "startup"))
    ce.admin_agent = None
    ce.cell = None
    ce.object_streamer = None
    ce.status = MachineStatus.STOPPED
    ws = Workspace(ws_root, site_name="site-1")
    ce.fl_ctx_mgr = FLContextManager(
        engine=ce,
        identity_name="site-1",
        job_id="",
        public_stickers={},
        private_stickers={
            FLContextKey.WORKSPACE_OBJECT: ws,
            FLContextKey.SERVER_CONFIG: [{"service": {"scheme": "tcp", "target": "127.0.0.1:1"}}],
            FLContextKey.ARGS: ce.args,
            FLContextKey.WORKSPACE_ROOT: ws_root,
        },
    )
    ce.fl_components = [rm] + list(extra_components)
    client.engine = ce
    return ce


def deploy(ws_root, job_meta):
    """Stands in for AppDeployer (DEPLOY): app dir + deployed meta.json."""
    jid = job_meta["job_id"]
    os.makedirs(os.path.join(ws_root, jid, "app_site-1", "custom"), exist_ok=True)
    with open(os.path.join(ws_root, jid, "meta.json"), "w") as f:
        json.dump(job_meta, f)


def check(ce, job_id, spec):
    req = Message(topic=TrainingTopic.CHECK_RESOURCE, body=spec)
    req.set_header(RequestHeader.JOB_ID, job_id)
    reply = CheckResourceProcessor().process(req, ce)
    return (
        reply.body.get_header(ShareableHeader.IS_RESOURCE_ENOUGH),
        reply.body.get_header(ShareableHeader.RESOURCE_RESERVE_TOKEN),
    )


def start(ce, job_meta, spec, token):
    req = Message(topic=TrainingTopic.START_JOB, body=spec)
    req.set_header(RequestHeader.JOB_ID, job_meta["job_id"])
    req.set_header(RequestHeader.JOB_META, copy.deepcopy(job_meta))
    req.set_header(ShareableHeader.RESOURCE_RESERVE_TOKEN, token)
    return StartJobProcessor().process(req, ce).body


def abort(ce, job_id):
    req = Message(topic=TrainingTopic.ABORT, body="")
    req.set_header(RequestHeader.JOB_ID, job_id)
    return AbortAppProcessor().process(req, ce).body


def notify(ce, job_id, status):
    req = Message(topic=TrainingTopic.NOTIFY_JOB_STATUS, body="")
    req.set_header(RequestHeader.JOB_ID, job_id)
    req.set_header(RequestHeader.JOB_STATUS, status)
    return NotifyJobStatusProcessor().process(req, ce).body


def rm_state(rm):
    d = rm.report_resources(None)
    res = d["resources"]
    if isinstance(res, list):
        res = {str(x["gpu_id"]): x["memory"] for x in res}
    return {"free": res, "reserved_tokens": len(d["reserved_resources"])}


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    # zombie check
    try:
        with open(f"/proc/{pid}/stat") as f:
            st = f.read().split(")")[-1].split()[0]
        return st != "Z"
    except FileNotFoundError:
        return False


def read_child(out_dir, jid, wait=10.0):
    p = os.path.join(out_dir, f"child_{jid}.json")
    end = time.time() + wait
    while time.time() < end:
        if os.path.exists(p):
            try:
                with open(p) as f:
                    return json.load(f)
            except json.JSONDecodeError:
                pass
        time.sleep(0.05)
    return None


def registered(ce):
    ex = ce.client_executor
    with ex.lock:
        return {k: v.get("_status") for k, v in ex.run_processes.items()}


def wait_until(pred, timeout=15.0, step=0.05):
    end = time.time() + timeout
    while time.time() < end:
        if pred():
            return True
        time.sleep(step)
    return False


# ----------------------------------------------------------------------------------------------------------------
def scenario_f1_abort_before_registration(report):
    """ABORT processed while START_JOB is between allocate and STARTING registration (held at BEFORE_JOB_LAUNCH)."""
    r = report.setdefault("F1_abort_before_registration", {})
    ws = tempfile.mkdtemp(prefix="nvf-cl-f1-")
    rm = ListResourceManager({"gpu": [0, 1]}, expiration_period=300)
    gate = Gate()
    launcher = StubCmdLauncher(ws, child_secs=60.0)
    ce = make_engine(ws, rm, ListResourceConsumer(), extra_components=[gate, launcher])
    ce.fire_event(EventType.SYSTEM_START, ce.new_context())
    meta = {"job_id": "job-F1", "resource_spec": {"site-1": {"gpu": 1}}}
    deploy(ws, meta)
    ok, tok = check(ce, "job-F1", {"gpu": 1})
    r["check"] = [ok, bool(tok)]
    gate.arm("job-F1")
    res = {}
    th = threading.Thread(target=lambda: res.setdefault("start_reply", start(ce, meta, {"gpu": 1}, tok)), daemon=True)
    th.start()
    assert gate.reached["job-F1"].wait(10)
    r["state_when_abort_arrives"] = {"t": ts(), "registered": registered(ce), "rm": rm_state(rm)}
    r["abort_reply"] = abort(ce, "job-F1")
    r["registered_after_abort"] = registered(ce)
    gate.release["job-F1"].set()
    th.join(20)
    r["start_reply"] = res.get("start_reply")
    child = read_child(ws, "job-F1")
    r["child_launched"] = child is not None
    time.sleep(3.0)
    r["3s_later"] = {
        "t": ts(),
        "child_alive": bool(child) and alive(child["pid"]),
        "registered": registered(ce),
        "rm": rm_state(rm),
        "cp_to_cj_messages": [m for m in ce.client.cell.sent],
    }
    # compensation: heartbeat reconciliation (only if the server no longer runs the job) -> abort_app(heartbeat_cleanup)
    t_hb = ts()
    r["heartbeat_cleanup_reply"] = ce.abort_app("job-F1", heartbeat_cleanup=True)
    wait_until(lambda: "job-F1" not in registered(ce), timeout=15)
    r["after_heartbeat_cleanup"] = {
        "t_start": t_hb,
        "t_end": ts(),
        "child_alive": bool(child) and alive(child["pid"]),
        "registered": registered(ce),
        "rm": rm_state(rm),
        "reports": ce.client.reports,
    }
    ce.fire_event(EventType.SYSTEM_END, ce.new_context())


def scenario_f1_control_abort_after_registration(report):
    """Control: ABORT processed after STARTING registration but before the spawn (pending handle) is honoured."""
    r = report.setdefault("F1c_abort_after_registration", {})
    ws = tempfile.mkdtemp(prefix="nvf-cl-f1c-")
    rm = ListResourceManager({"gpu": [0, 1]}, expiration_period=300)
    launcher = StubCmdLauncher(ws, child_secs=60.0)
    ce = make_engine(ws, rm, ListResourceConsumer(), extra_components=[launcher])
    ce.fire_event(EventType.SYSTEM_START, ce.new_context())
    meta = {"job_id": "job-F1c", "resource_spec": {"site-1": {"gpu": 1}}}
    deploy(ws, meta)
    ok, tok = check(ce, "job-F1c", {"gpu": 1})
    reached, release = launcher.arm_launch_gate("job-F1c")
    res = {}
    th = threading.Thread(target=lambda: res.setdefault("start_reply", start(ce, meta, {"gpu": 1}, tok)), daemon=True)
    th.start()
    assert reached.wait(10)
    r["state_when_abort_arrives"] = {"registered": registered(ce), "rm": rm_state(rm)}
    r["abort_reply"] = abort(ce, "job-F1c")
    release.set()
    th.join(20)
    r["start_reply"] = res.get("start_reply")
    child = read_child(ws, "job-F1c", wait=5)
    wait_until(lambda: "job-F1c" not in registered(ce), timeout=15)
    r["after"] = {
        "child_record": child,
        "child_alive": bool(child) and alive(child["pid"]),
        "registered": registered(ce),
        "rm": rm_state(rm),
        "reports": ce.client.reports,
    }
    ce.fire_event(EventType.SYSTEM_END, ce.new_context())


def _patch_gpu_edge():
    gpu_consumer_mod.get_host_gpu_ids = lambda: [0, 1]
    gpu_consumer_mod.get_host_gpu_memory_free = lambda unit="MiB": [16384.0, 16384.0]


def scenario_f2_stale_cuda_env_sequential(report):
    """Default config (GPUResourceManager + GPUResourceConsumer): job A allocates GPU 1; job B requests no GPU
    (num_of_gpus: 0 -> {} after get_resource_manager_spec) -> consume() skipped -> B inherits A's binding."""
    r = report.setdefault("F2_stale_env_sequential", {})
    _patch_gpu_edge()
    os.environ.pop("CUDA_VISIBLE_DEVICES", None)
    ws = tempfile.mkdtemp(prefix="nvf-cl-f2-")
    rm = GPUResourceManager(num_of_gpus=2, mem_per_gpu_in_GiB=16, expiration_period=300, ignore_host=True)
    launcher = StubCmdLauncher(ws, child_secs=20.0)
    ce = make_engine(ws, rm, GPUResourceConsumer(), extra_components=[launcher])
    ce.fire_event(EventType.SYSTEM_START, ce.new_context())
    r["cp_env_initial"] = os.environ.get("CUDA_VISIBLE_DEVICES", "<unset>")
    # occupy GPU 0 fully with job Z so that job A lands on GPU 1 (makes the binding visible)
    meta_z = {"job_id": "job-Z", "resource_spec": {"site-1": {"num_of_gpus": 1, "mem_per_gpu_in_GiB": 16}}}
    meta_a = {"job_id": "job-A", "resource_spec": {"site-1": {"num_of_gpus": 1, "mem_per_gpu_in_GiB": 16}}}
    meta_b = {"job_id": "job-B", "resource_spec": {"site-1": {"num_of_gpus": 0}}}
    out = {}
    for meta in (meta_z, meta_a, meta_b):
        jid = meta["job_id"]
        spec = get_resource_manager_spec(meta, "site-1")
        deploy(ws, meta)
        ok, tok = check(ce, jid, spec)
        reply = start(ce, meta, spec, tok)
        child = read_child(ws, jid)
        out[jid] = {
            "rm_spec": spec,
            "check_ok": ok,
            "start_reply": reply,
            "child_CUDA_VISIBLE_DEVICES": child and child["CUDA_VISIBLE_DEVICES"],
            "cp_env_after_start": os.environ.get("CUDA_VISIBLE_DEVICES", "<unset>"),
            "rm_after_start": rm_state(rm),
        }
    r["jobs"] = out
    r["registered_concurrently"] = registered(ce)
    for jid in ("job-Z", "job-A", "job-B"):
        ce.abort_app(jid, heartbeat_cleanup=True)  # cleanup (STARTING -> immediate terminate)
    wait_until(lambda: not registered(ce), timeout=20)
    r["rm_after_cleanup"] = rm_state(rm)
    ce.fire_event(EventType.SYSTEM_END, ce.new_context())
    os.environ.pop("CUDA_VISIBLE_DEVICES", None)


def scenario_f2r_concurrent_start_env_race(report):
    """Two START_JOB handlers overlap on one CP: A consumes GPU0 and is held before launch (BEFORE_JOB_LAUNCH),
    B consumes GPU1 and launches, then A launches -> A's process is bound to B's GPU."""
    r = report.setdefault("F2r_concurrent_start_env_race", {})
    _patch_gpu_edge()
    os.environ.pop("CUDA_VISIBLE_DEVICES", None)
    ws = tempfile.mkdtemp(prefix="nvf-cl-f2r-")
    rm = GPUResourceManager(num_of_gpus=2, mem_per_gpu_in_GiB=16, expiration_period=300, ignore_host=True)
    gate = Gate()
    launcher = StubCmdLauncher(ws, child_secs=20.0)
    ce = make_engine(ws, rm, GPUResourceConsumer(), extra_components=[gate, launcher])
    ce.fire_event(EventType.SYSTEM_START, ce.new_context())
    meta_a = {"job_id": "job-A", "resource_spec": {"site-1": {"num_of_gpus": 1, "mem_per_gpu_in_GiB": 16}}}
    meta_b = {"job_id": "job-B", "resource_spec": {"site-1": {"num_of_gpus": 1, "mem_per_gpu_in_GiB": 16}}}
    specs = {}
    toks = {}
    for meta in (meta_a, meta_b):
        jid = meta["job_id"]
        specs[jid] = get_resource_manager_spec(meta, "site-1")
        deploy(ws, meta)
        toks[jid] = check(ce, jid, specs[jid])
    r["reservations"] = {k: v[0] for k, v in toks.items()}
    gate.arm("job-A")
    res = {}
    tha = threading.Thread(
        target=lambda: res.setdefault("A", start(ce, meta_a, specs["job-A"], toks["job-A"][1])), daemon=True
    )
    tha.start()
    assert gate.reached["job-A"].wait(10)
    r["cp_env_while_A_held"] = os.environ.get("CUDA_VISIBLE_DEVICES")
    res["B"] = start(ce, meta_b, specs["job-B"], toks["job-B"][1])
    gate.release["job-A"].set()
    tha.join(20)
    ca = read_child(ws, "job-A")
    cb = read_child(ws, "job-B")
    r["start_replies"] = res
    r["allocations_by_rm"] = rm_state(rm)
    r["child_env"] = {"job-A": ca and ca["CUDA_VISIBLE_DEVICES"], "job-B": cb and cb["CUDA_VISIBLE_DEVICES"]}
    for jid in ("job-A", "job-B"):
        ce.abort_app(jid, heartbeat_cleanup=True)
    wait_until(lambda: not registered(ce), timeout=20)
    r["rm_after_cleanup"] = rm_state(rm)
    ce.fire_event(EventType.SYSTEM_END, ce.new_context())
    os.environ.pop("CUDA_VISIBLE_DEVICES", None)


def scenario_k7_variant_parent_death(report):
    """K7 variant: the CJ's STARTED notification loop (ClientAppRunner.notify_job_status) is not interrupted by
    ClientAppRunner.stop(), which is what monitor_parent_process calls when the CP disappears (F7)."""
    from nvflare.private.fed.client.client_app_runner import ClientAppRunner

    r = report.setdefault("K7v_parent_death_during_start_notify", {})
    tries = {"n": 0}

    def send_request(**kw):
        tries["n"] += 1
        time.sleep(0.05)
        m = CellMessage()
        m.set_header(MessageHeaderKey.RETURN_CODE, ReturnCode.TARGET_UNREACHABLE)
        return m

    fc = SimpleNamespace(cell=SimpleNamespace(core_cell=SimpleNamespace(get_fqcn=lambda: "site-1.job-X")))
    fc.cell.send_request = send_request
    runner = ClientAppRunner()
    aborted = {"n": 0}
    runner.client_runner = SimpleNamespace(abort=lambda: aborted.__setitem__("n", aborted["n"] + 1))
    done = threading.Event()

    def target():
        runner.notify_job_status(fc, "job-X", ClientStatus.STARTED, timeout=0.05, retry_timeout=1.0)
        done.set()

    th = threading.Thread(target=target, daemon=True)
    th.start()
    time.sleep(0.5)
    runner.stop()  # what monitor_parent_process() does once the CP pid disappears
    n_at_stop = tries["n"]
    th.join(timeout=4.0)
    r["client_runner_abort_calls"] = aborted["n"]
    r["notify_returned_within_4s_after_stop"] = done.is_set()
    r["send_attempts_at_stop"] = n_at_stop
    r["send_attempts_4s_after_stop"] = tries["n"]


def scenario_s5_cp_shutdown_with_running_job(report):
    """ClientEngine.shutdown() with a running job: SYSTEM_END (expiry thread stops), shutdown thread closes the
    client; the CP never terminates the CJ nor frees its allocation; outstanding reservation no longer expires."""
    import nvflare.private.fed.client.client_engine as ce_mod

    r = report.setdefault("S5_cp_shutdown_with_running_job", {})
    ws = tempfile.mkdtemp(prefix="nvf-cl-s5-")
    rm = ListResourceManager({"gpu": [0, 1, 2]}, expiration_period=2)
    launcher = StubCmdLauncher(ws, child_secs=30.0)
    ce = make_engine(ws, rm, ListResourceConsumer(), extra_components=[launcher])
    ce.fire_event(EventType.SYSTEM_START, ce.new_context())
    meta = {"job_id": "job-S5", "resource_spec": {"site-1": {"gpu": 1}}}
    deploy(ws, meta)
    ok, tok = check(ce, "job-S5", {"gpu": 1})
    r["start_reply"] = start(ce, meta, {"gpu": 1}, tok)
    child = read_child(ws, "job-S5")
    ok2, tok2 = check(ce, "job-other", {"gpu": 1})  # an outstanding reservation (e.g. job not dispatched)
    r["before_shutdown"] = {"rm": rm_state(rm), "registered": registered(ce)}
    orig_security_close = ce_mod.security_close
    ce_mod.security_close = lambda: None  # process-global security teardown not needed in harness
    try:
        r["shutdown_reply"] = ce.shutdown()
    finally:
        pass
    time.sleep(4.0)  # > expiration_period (2 ticks) -- expiry thread has been stopped by SYSTEM_END
    r["4s_after_shutdown"] = {
        "client_status": ce.client.status,
        "heartbeat_done": ce.client.communicator.heartbeat_done,
        "child_alive": bool(child) and alive(child["pid"]),
        "registered": registered(ce),
        "rm": rm_state(rm),
        "cp_to_cj_messages": ce.client.cell.sent,
    }
    ce_mod.security_close = orig_security_close
    # cleanup
    ce.client_executor.abort_app("job-S5", heartbeat_cleanup=True)
    wait_until(lambda: not registered(ce), timeout=15)
    r["reports_after_cleanup"] = ce.client.reports


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--only", nargs="*")
    a = ap.parse_args()
    report = {"t0": T0}
    fns = [
        scenario_f1_abort_before_registration,
        scenario_f1_control_abort_after_registration,
        scenario_f2_stale_cuda_env_sequential,
        scenario_f2r_concurrent_start_env_race,
        scenario_k7_variant_parent_death,
        scenario_s5_cp_shutdown_with_running_job,
    ]
    for fn in fns:
        if a.only and fn.__name__ not in a.only:
            continue
        try:
            fn(report)
        except Exception as e:
            report[fn.__name__ + "_error"] = f"{type(e).__name__}: {e}\n{traceback.format_exc()}"
    for pid in SPAWNED:
        try:
            os.killpg(os.getpgid(pid), signal.SIGKILL)
        except Exception:
            pass
    txt = json.dumps(report, indent=2, default=str)
    print(txt)
    with open(a.out, "w") as f:
        f.write(txt + "\n")
    os._exit(0)


if __name__ == "__main__":
    main()
