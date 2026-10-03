#!/usr/bin/env python3
"""CR-23 reproduction: typed process exit code lost without _process_rc.txt."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
from contextlib import nullcontext
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock


SOURCE_ROOT = Path(
    os.environ.get(
        "NVFLARE_SOURCE_ROOT",
        "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/"
        "gpt-continuation/nvflare-job/.specula-output/confirmation/CR-23/worktree",
    )
)
sys.path.insert(0, str(SOURCE_ROOT))

from nvflare.apis.event_type import EventType
from nvflare.apis.fl_constant import FLContextKey, FLMetaKey, JobConstants, RunProcessKey
from nvflare.apis.job_launcher_spec import JobLauncherSpec, JobReturnCode, add_launcher
from nvflare.apis.workspace import Workspace
from nvflare.app_common.job_launcher.process_launcher import ProcessHandle
from nvflare.fuel.common.exit_codes import ProcessExitCode
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey, ReturnCode
from nvflare.private.defs import CellMessageHeaderKeys, JobFailureMsgKey
from nvflare.private.fed.client.client_executor import (
    _ABORT_REQUESTED_KEY,
    REPORTABLE_JOB_FAILURES,
    JobExecutor,
)
from nvflare.private.fed.client.client_status import ClientStatus
from nvflare.private.fed.server.fed_server import FederatedServer


class PropContext:
    def __init__(self, engine=None, props=None):
        self._engine = engine
        self.props = dict(props or {})

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        return False

    def get_engine(self):
        return self._engine

    def get_prop(self, key, default=None):
        return self.props.get(key, default)

    def set_prop(self, key, value, **_kwargs):
        self.props[key] = value

    def remove_prop(self, key):
        self.props.pop(key, None)


class FakeEngine:
    def __init__(self, launcher):
        self.launcher = launcher
        self.events = []

    def new_context(self):
        return PropContext(engine=self)

    def fire_event(self, event_type, fl_ctx):
        self.events.append(event_type)
        if event_type == EventType.BEFORE_JOB_LAUNCH:
            add_launcher(self.launcher, fl_ctx)


class FakeCell:
    def get_internal_listener_url(self):
        return "tcp://parent:8002"

    def get_internal_listener_params(self):
        return {}

    def get_fqcn(self):
        return "server.site-1"


class FakeReply:
    def get_header(self, key, default=None):
        if key == MessageHeaderKey.RETURN_CODE:
            return ReturnCode.OK
        return default


class FakeClient:
    def __init__(self, server):
        self.client_name = "site-1"
        self.token = "token-1"
        self.token_signature = "sig-1"
        self.ssid = "ssid-1"
        self.cell = FakeCell()
        self.server = server
        self.report_kwargs = None
        self.report_request = None

    def send_request_before_shutdown(self, **kwargs):
        self.report_kwargs = kwargs
        request = kwargs["request"]
        request.set_header(CellMessageHeaderKeys.TOKEN, self.token)
        request.set_header(MessageHeaderKey.ORIGIN, self.client_name)
        self.report_request = request
        return self.server.process_job_failure(request)


class UnsafeChildLauncher(JobLauncherSpec):
    def __init__(self, gate_file: Path):
        super().__init__()
        self.gate_file = gate_file
        self.process = None

    def launch_job(self, job_meta: dict, fl_ctx) -> ProcessHandle:
        workspace = fl_ctx.get_prop(FLContextKey.WORKSPACE_OBJECT)
        job_id = job_meta[JobConstants.JOB_ID]
        run_dir = Path(workspace.get_run_dir(job_id))
        child_code = r"""
import os
import sys
import time

from nvflare.fuel.common.excepts import ComponentNotAuthorized
from nvflare.fuel.f3.mpm import MainProcessMonitor as mpm

run_dir = sys.argv[1]
gate_file = sys.argv[2]

def main():
    deadline = time.time() + 10.0
    while not os.path.exists(gate_file):
        if time.time() > deadline:
            raise RuntimeError("test gate was not opened")
        time.sleep(0.02)
    raise ComponentNotAuthorized("blocked component from normal job process")

rc = mpm.run(main_func=main, run_dir=run_dir, shutdown_grace_time=0, cleanup_grace_time=0)
sys.exit(rc)
"""
        env = os.environ.copy()
        env["PYTHONPATH"] = str(SOURCE_ROOT) + os.pathsep + env.get("PYTHONPATH", "")
        self.process = subprocess.Popen(
            [sys.executable, "-c", child_code, str(run_dir), str(self.gate_file)],
            cwd=str(SOURCE_ROOT),
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        return ProcessHandle(process=self.process)


class MatrixJobHandle:
    def __init__(self, poll_code):
        self.poll_code = poll_code

    def wait(self):
        return None

    def poll(self):
        return self.poll_code


def make_server():
    server = object.__new__(FederatedServer)
    server.logger = MagicMock()
    client = SimpleNamespace(name="site-1")
    server.client_manager = SimpleNamespace(
        clients={"token-1": client},
        is_from_authorized_client=lambda token: token == "token-1",
    )
    job_runner = MagicMock()
    job_runner.is_client_outcome_pending.return_value = True
    fl_ctx = MagicMock()
    server.engine = SimpleNamespace(job_runner=job_runner, new_context=lambda: nullcontext(fl_ctx))
    return server, job_runner


def server_action_for_code(code):
    server, job_runner = make_server()
    request = FakeReport(code)
    server.process_job_failure(request)
    if job_runner.stop_run.called:
        return "stop_run"
    if job_runner.fail_run.called:
        args = job_runner.fail_run.call_args.args
        return f"fail_run({args[1]})"
    return "no_failure_action"


class FakeReport:
    def __init__(self, code):
        self.payload = {
            JobFailureMsgKey.JOB_ID: "job-1",
            JobFailureMsgKey.CODE: code,
            JobFailureMsgKey.REASON: REPORTABLE_JOB_FAILURES.get(code),
        }
        self.headers = {
            CellMessageHeaderKeys.TOKEN: "token-1",
            MessageHeaderKey.ORIGIN: "site-1",
        }

    def get_header(self, key, default=None):
        return self.headers.get(key, default)


def run_client_wait_row(tmp_root: Path, intended_code, launcher_code, rc_file_value, status):
    server, _job_runner = make_server()
    client = FakeClient(server)
    executor = JobExecutor(client=client, startup="startup")
    engine = MagicMock()
    fl_ctx = MagicMock()
    fl_ctx.get_engine.return_value = engine

    job_id = f"matrix-{intended_code}-{status}-{rc_file_value if rc_file_value is not None else 'none'}"
    run_dir = tmp_root / job_id
    run_dir.mkdir()
    if rc_file_value is not None:
        (run_dir / FLMetaKey.PROCESS_RC_FILE).write_text(f"{rc_file_value}\n", encoding="utf-8")
    executor.run_processes[job_id] = {
        RunProcessKey.JOB_HANDLE: MatrixJobHandle(launcher_code),
        RunProcessKey.STATUS: status,
        _ABORT_REQUESTED_KEY: False,
    }
    executor._wait_child_process_finish(
        client=client,
        job_id=job_id,
        allocated_resource=None,
        token=None,
        resource_manager=MagicMock(),
        workspace=str(tmp_root),
        fl_ctx=fl_ctx,
    )
    payload = client.report_request.payload
    code = payload[JobFailureMsgKey.CODE]
    return {
        "launcher_poll": launcher_code,
        "rc_file": rc_file_value,
        "status": status,
        "reported": code,
        "reason": payload[JobFailureMsgKey.REASON],
        "server_action": server_action_for_code(code),
    }


def run_matrix(tmp_root: Path):
    tmp_root.mkdir(parents=True)
    rows = []
    statuses = [ClientStatus.STARTING, ClientStatus.STARTED, ClientStatus.STOPPED]
    for intended_code in (
        ProcessExitCode.EXCEPTION,
        ProcessExitCode.UNSAFE_COMPONENT,
        ProcessExitCode.CONFIG_ERROR,
    ):
        for has_rc_file in (False, True):
            for status in statuses:
                row = run_client_wait_row(
                    tmp_root=tmp_root,
                    intended_code=intended_code,
                    launcher_code=JobReturnCode.EXECUTION_ERROR,
                    rc_file_value=intended_code if has_rc_file else None,
                    status=status,
                )
                row["intended_process_code"] = intended_code
                row["has_rc_file"] = has_rc_file
                rows.append(row)
    return rows


def run_unsafe_component_trigger(tmp_root: Path):
    workspace_root = tmp_root / "workspace"
    (workspace_root / "startup").mkdir(parents=True)
    (workspace_root / "local").mkdir()
    workspace = Workspace(str(workspace_root), site_name="site-1")
    job_id = "job-1"
    run_dir = Path(workspace.get_run_dir(job_id))
    run_dir.mkdir(parents=True)
    job_meta = {JobConstants.JOB_ID: job_id}
    Path(workspace.get_job_meta_path(job_id)).write_text(json.dumps(job_meta), encoding="utf-8")

    server, job_runner = make_server()
    gate_file = tmp_root / "open-gate"
    launcher = UnsafeChildLauncher(gate_file=gate_file)
    engine = FakeEngine(launcher=launcher)
    fl_ctx = PropContext(
        engine=engine,
        props={
            FLContextKey.WORKSPACE_OBJECT: workspace,
            FLContextKey.SERVER_CONFIG: [{"service": {"scheme": "grpc", "target": "parent:8002"}}],
        },
    )
    client = FakeClient(server)
    executor = JobExecutor(client=client, startup=str(workspace_root / "startup"))

    executor.start_app(
        client=client,
        job_id=job_id,
        job_meta=job_meta.copy(),
        args=SimpleNamespace(workspace=str(workspace_root), set=[]),
        allocated_resource=None,
        token=None,
        resource_manager=MagicMock(),
        fl_ctx=fl_ctx,
    )
    executor.notify_job_status(job_id, ClientStatus.STARTED)
    gate_file.write_text("go\n", encoding="utf-8")

    deadline = time.time() + 10.0
    while client.report_request is None and time.time() < deadline:
        time.sleep(0.02)
    if client.report_request is None:
        raise RuntimeError("client did not report terminal outcome")

    stdout, stderr = launcher.process.communicate(timeout=5)
    payload = client.report_request.payload
    server_action = "stop_run" if job_runner.stop_run.called else "fail_run"
    server_call_code = None
    if job_runner.fail_run.called:
        server_call_code = job_runner.fail_run.call_args.args[1]
    elif job_runner.stop_run.called:
        server_call_code = "stop"

    return {
        "raw_child_exit": launcher.process.returncode,
        "rc_file_exists": (run_dir / FLMetaKey.PROCESS_RC_FILE).exists(),
        "reported_code": payload[JobFailureMsgKey.CODE],
        "reported_reason": payload[JobFailureMsgKey.REASON],
        "server_action": server_action,
        "server_call_code": server_call_code,
        "expected_if_typed_preserved": server_action_for_code(ProcessExitCode.UNSAFE_COMPONENT),
        "child_stdout": stdout.strip(),
        "child_stderr_tail": "\n".join(stderr.strip().splitlines()[-4:]),
    }


def main():
    with tempfile.TemporaryDirectory(prefix="cr23-") as td:
        tmp_root = Path(td)
        matrix = run_matrix(tmp_root / "matrix")
        result = run_unsafe_component_trigger(tmp_root)

    print("CR-23 typed process return-code matrix")
    for row in matrix:
        if row["intended_process_code"] == ProcessExitCode.UNSAFE_COMPONENT:
            print(
                "MATRIX intended={intended_process_code} rc_file={has_rc_file} "
                "status={status} launcher_poll={launcher_poll} -> reported={reported} "
                "reason={reason} server_action={server_action}".format(**row)
            )

    print("CR-23 unsafe-component trigger")
    print(f"RAW_CHILD_EXIT={result['raw_child_exit']}")
    print(f"RC_FILE_EXISTS={result['rc_file_exists']}")
    print(f"CLIENT_REPORTED_CODE={result['reported_code']}")
    print(f"CLIENT_REPORTED_REASON={result['reported_reason']}")
    print(f"SERVER_ACTION={result['server_action']}")
    print(f"SERVER_CALL_CODE={result['server_call_code']}")
    print(f"EXPECTED_IF_TYPED_UNSAFE_PRESERVED={result['expected_if_typed_preserved']}")
    print(f"CHILD_STDERR_TAIL={result['child_stderr_tail']!r}")

    bug_triggered = (
        result["raw_child_exit"] == ProcessExitCode.UNSAFE_COMPONENT
        and not result["rc_file_exists"]
        and result["reported_code"] == ProcessExitCode.EXCEPTION
        and result["server_action"] == "fail_run"
    )
    print(f"BUG_TRIGGERED={bug_triggered}")
    if not bug_triggered:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
