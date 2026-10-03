#!/usr/bin/env python3
"""Reproduce MC-8 with real NVFlare client resource and process-launch code.

The test drives the normal client-side CHECK_RESOURCE -> START_JOB processors.
The only stubs are the network edge and the job command chosen by a
ProcessJobLauncher subclass.  The launched leader process starts a same-process
group child and exits successfully; the real JobExecutor waiter then frees the
allocation while the descendant is still alive.
"""

import json
import logging
import os
import shlex
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from types import SimpleNamespace

SOURCE = Path(
    "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/"
    "gpt-continuation/nvflare-job/.specula-output/confirmation/MC-8/worktree"
)
sys.path.insert(0, str(SOURCE))

from nvflare.apis.event_type import EventType  # noqa: E402
from nvflare.apis.fl_constant import FLContextKey, SystemComponents  # noqa: E402
from nvflare.apis.job_def import JobMetaKey  # noqa: E402
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
from nvflare.private.fed.client.scheduler_cmds import CheckResourceProcessor, StartJobProcessor  # noqa: E402
from nvflare.private.scheduler_constants import ShareableHeader  # noqa: E402


logging.basicConfig(level=logging.WARNING)


def ok_reply():
    reply = CellMessage()
    reply.set_header(MessageHeaderKey.RETURN_CODE, ReturnCode.OK)
    return reply


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


class FakeFederatedClient:
    def __init__(self, components):
        self.client_name = "site-1"
        self.client_args = {}
        self.token = "token"
        self.token_signature = "signature"
        self.ssid = "ssid"
        self.secure_train = False
        self.components = components
        self.cell = FakeCell()
        self.engine = None
        self.reports = []
        self.multi_gpu = False

    def send_request_before_shutdown(self, **kwargs):
        self.reports.append(kwargs["request"].payload)
        return ok_reply()


class ScriptLauncher(ProcessJobLauncher):
    def __init__(self, commands):
        super().__init__()
        self.commands = commands
        self.handles = {}

    def handle_event(self, event_type: str, fl_ctx):
        if event_type == EventType.BEFORE_JOB_LAUNCH:
            add_launcher(self, fl_ctx)

    def get_command(self, job_meta, fl_ctx):
        return self.commands[job_meta[JobMetaKey.JOB_ID.value]]

    def launch_job(self, job_meta, fl_ctx):
        handle = super().launch_job(job_meta, fl_ctx)
        self.handles[job_meta[JobMetaKey.JOB_ID.value]] = handle
        return handle


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    try:
        stat = Path(f"/proc/{pid}/stat").read_text().split(")")[-1].split()[0]
        return stat != "Z"
    except FileNotFoundError:
        return False


def wait_until(predicate, timeout=10.0, step=0.05):
    end = time.time() + timeout
    while time.time() < end:
        if predicate():
            return True
        time.sleep(step)
    return False


def read_json(path, timeout=10.0):
    path = Path(path)
    if not wait_until(path.exists, timeout=timeout):
        raise RuntimeError(f"timed out waiting for {path}")
    end = time.time() + timeout
    while time.time() < end:
        try:
            return json.loads(path.read_text())
        except json.JSONDecodeError:
            time.sleep(0.02)
    raise RuntimeError(f"timed out reading complete JSON from {path}")


def write_job_scripts(tmp):
    leader = tmp / "leader_with_descendant.py"
    simple = tmp / "simple_job.py"
    leader.write_text(
        r'''
import json
import os
import subprocess
import sys
import textwrap
import time

out = sys.argv[1]
sleep_secs = sys.argv[2]
grandchild_out = out + ".grandchild.json"
grandchild_code = r"""
import json
import os
import sys
import time

out = sys.argv[1]
sleep_secs = float(sys.argv[2])
info = {
    "pid": os.getpid(),
    "ppid": os.getppid(),
    "pgid": os.getpgid(0),
    "sid": os.getsid(0),
    "cuda": os.environ.get("CUDA_VISIBLE_DEVICES", "<unset>"),
    "started": time.time(),
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(info, f)
time.sleep(sleep_secs)
"""
p = subprocess.Popen([sys.executable, "-c", grandchild_code, grandchild_out, sleep_secs])
info = {
    "pid": os.getpid(),
    "pgid": os.getpgid(0),
    "sid": os.getsid(0),
    "cuda": os.environ.get("CUDA_VISIBLE_DEVICES", "<unset>"),
    "grandchild_pid": p.pid,
    "grandchild_file": grandchild_out,
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(info, f)
# Exit cleanly without waiting for the same-process-group descendant.
''',
        encoding="utf-8",
    )
    simple.write_text(
        r'''
import json
import os
import sys
import time

out = sys.argv[1]
info = {
    "pid": os.getpid(),
    "pgid": os.getpgid(0),
    "sid": os.getsid(0),
    "cuda": os.environ.get("CUDA_VISIBLE_DEVICES", "<unset>"),
    "started": time.time(),
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(info, f)
time.sleep(0.5)
''',
        encoding="utf-8",
    )
    return leader, simple


def deploy_meta(workspace_root, job_meta):
    job_id = job_meta[JobMetaKey.JOB_ID.value]
    workspace = Workspace(str(workspace_root), site_name="site-1")
    app_dir = Path(workspace.get_app_dir(job_id))
    app_dir.mkdir(parents=True, exist_ok=True)
    meta_path = Path(workspace.get_job_meta_path(job_id))
    meta_path.parent.mkdir(parents=True, exist_ok=True)
    meta_path.write_text(json.dumps(job_meta), encoding="utf-8")


def check_resource(engine, job_id, spec):
    req = Message(topic=TrainingTopic.CHECK_RESOURCE, body=spec)
    req.set_header(RequestHeader.JOB_ID, job_id)
    reply = CheckResourceProcessor().process(req, engine)
    return (
        reply.body.get_header(ShareableHeader.IS_RESOURCE_ENOUGH),
        reply.body.get_header(ShareableHeader.RESOURCE_RESERVE_TOKEN),
    )


def start_job(engine, job_meta, spec, token):
    req = Message(topic=TrainingTopic.START_JOB, body=spec)
    req.set_header(RequestHeader.JOB_ID, job_meta[JobMetaKey.JOB_ID.value])
    req.set_header(RequestHeader.JOB_META, job_meta)
    req.set_header(ShareableHeader.RESOURCE_RESERVE_TOKEN, token)
    return StartJobProcessor().process(req, engine).body


def rm_free_list(resource_manager):
    report = resource_manager.report_resources(None)
    return list(report["resources"]["gpu"])


def main():
    with tempfile.TemporaryDirectory(prefix="nvflare-mc8-") as td:
        tmp = Path(td)
        workspace_root = tmp / "workspace"
        (workspace_root / "startup").mkdir(parents=True)
        (workspace_root / "local").mkdir(parents=True)
        leader_script, simple_script = write_job_scripts(tmp)

        out_a = tmp / "job_a.json"
        out_b = tmp / "job_b.json"
        commands = {
            "job-a": f"{shlex.quote(sys.executable)} {shlex.quote(str(leader_script))} {shlex.quote(str(out_a))} 20",
            "job-b": f"{shlex.quote(sys.executable)} {shlex.quote(str(simple_script))} {shlex.quote(str(out_b))}",
        }
        launcher = ScriptLauncher(commands)
        resource_manager = ListResourceManager({"gpu": [0]}, expiration_period=300)
        resource_consumer = ListResourceConsumer()
        components = {
            SystemComponents.RESOURCE_MANAGER: resource_manager,
            SystemComponents.RESOURCE_CONSUMER: resource_consumer,
            "script_launcher": launcher,
        }
        fake_client = FakeFederatedClient(components)
        args = SimpleNamespace(workspace=str(workspace_root), set=[])
        engine = ClientEngine(fake_client, args=args, rank=0)
        fake_client.engine = engine
        ws = Workspace(str(workspace_root), site_name="site-1")
        with engine.new_context() as fl_ctx:
            fl_ctx.set_prop(FLContextKey.WORKSPACE_OBJECT, ws, private=True, sticky=True)
            fl_ctx.set_prop(
                FLContextKey.SERVER_CONFIG,
                [{"service": {"scheme": "tcp", "target": "127.0.0.1:1"}}],
                private=True,
                sticky=True,
            )
            fl_ctx.set_prop(FLContextKey.ARGS, args, private=True, sticky=True)

        meta_a = {
            JobMetaKey.JOB_ID.value: "job-a",
            JobMetaKey.RESOURCE_SPEC.value: {"site-1": {"gpu": 1}},
        }
        meta_b = {
            JobMetaKey.JOB_ID.value: "job-b",
            JobMetaKey.RESOURCE_SPEC.value: {"site-1": {"gpu": 1}},
        }
        deploy_meta(workspace_root, meta_a)
        deploy_meta(workspace_root, meta_b)

        ok_a, token_a = check_resource(engine, "job-a", {"gpu": 1})
        start_a = start_job(engine, meta_a, {"gpu": 1}, token_a)
        leader_info = read_json(out_a)
        grandchild_info = read_json(leader_info["grandchild_file"])
        same_group = leader_info["pgid"] == grandchild_info["pgid"]
        child_pid = grandchild_info["pid"]
        pgid = grandchild_info["pgid"]

        waiter_freed = wait_until(
            lambda: rm_free_list(resource_manager) == [0] and "job-a" not in engine.client_executor.run_processes,
            timeout=10.0,
        )
        descendant_alive_at_free = alive(child_pid)

        ok_b, token_b = check_resource(engine, "job-b", {"gpu": 1})
        free_after_b_reserve = rm_free_list(resource_manager)
        start_b = start_job(engine, meta_b, {"gpu": 1}, token_b)
        job_b_info = read_json(out_b)
        descendant_alive_when_b_started = alive(child_pid)

        # Show that the post-reap handle cannot recover the group through the
        # leader PID.  The child is cleaned up below using the PGID captured
        # before the leader was reaped.
        launcher.handles["job-a"].terminate()
        descendant_alive_after_reaped_handle_terminate = alive(child_pid)
        job_b_finished_normally = wait_until(
            lambda: "job-b" not in engine.client_executor.run_processes,
            timeout=5.0,
        )

        cleanup_errors = []
        try:
            os.killpg(pgid, signal.SIGKILL)
        except Exception as exc:
            cleanup_errors.append(f"killpg({pgid}) failed: {exc!r}")
        try:
            b_handle = launcher.handles.get("job-b")
            if b_handle and not job_b_finished_normally:
                b_handle.terminate()
        except Exception as exc:
            cleanup_errors.append(f"job-b terminate failed: {exc!r}")

        result = {
            "source_commit": subprocess.check_output(["git", "-C", str(SOURCE), "rev-parse", "HEAD"], text=True).strip(),
            "level": "1 (normal client request processors plus timing observation; no state injection or product patch)",
            "job_a_check_ok": ok_a,
            "job_a_start_reply": start_a,
            "job_a_leader": leader_info,
            "job_a_grandchild": grandchild_info,
            "same_process_group": same_group,
            "waiter_freed_and_unregistered": waiter_freed,
            "resource_pool_after_job_a_waiter": rm_free_list(resource_manager),
            "descendant_alive_at_free": descendant_alive_at_free,
            "job_b_check_ok_while_descendant_alive": ok_b,
            "job_b_reserved_token": bool(token_b),
            "resource_pool_after_job_b_reserve": free_after_b_reserve,
            "job_b_start_reply": start_b,
            "job_b_process": job_b_info,
            "descendant_alive_when_job_b_started": descendant_alive_when_b_started,
            "descendant_alive_after_reaped_handle_terminate": descendant_alive_after_reaped_handle_terminate,
            "job_b_finished_normally_before_cleanup": job_b_finished_normally,
            "reports_sent_to_server": fake_client.reports,
            "cleanup_errors": cleanup_errors,
        }
        print(json.dumps(result, indent=2, sort_keys=True))

        assert ok_a is True
        assert same_group is True
        assert waiter_freed is True
        assert descendant_alive_at_free is True
        assert ok_b is True
        assert job_b_info["cuda"] == "0"
        assert descendant_alive_when_b_started is True
        assert descendant_alive_after_reaped_handle_terminate is True


if __name__ == "__main__":
    main()
