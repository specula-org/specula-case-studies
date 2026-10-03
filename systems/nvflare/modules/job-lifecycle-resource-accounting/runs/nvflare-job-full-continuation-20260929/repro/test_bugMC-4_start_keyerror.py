#!/usr/bin/env python3
"""Reproduce MC-4: fail_run can pop START outcome tracking before _start_run narrows it.

This is a focused integration harness.  It exercises real NVFlare server
code for JobRunner.run/_start_run/fail_run and FederatedServer.process_job_failure.
Only the deployment, network fan-out, and process-launch edges are stubbed so the
timing window can be hit deterministically in one process.
"""

from __future__ import annotations

import json
import logging
import os
import sys
import tempfile
import threading
import time
from types import SimpleNamespace


SOURCE = (
    "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/"
    "nvflare-job/.specula-output/confirmation/MC-4/worktree"
)
sys.path.insert(0, SOURCE)

from nvflare.apis.client import Client  # noqa: E402
from nvflare.apis.event_type import EventType  # noqa: E402
from nvflare.apis.fl_constant import FLContextKey, RunProcessKey, SiteType, SystemComponents  # noqa: E402
from nvflare.apis.fl_context import FLContextManager  # noqa: E402
from nvflare.apis.job_def import Job, JobMetaKey, RunStatus  # noqa: E402
from nvflare.apis.job_scheduler_spec import DispatchInfo  # noqa: E402
from nvflare.apis.workspace import Workspace  # noqa: E402
from nvflare.fuel.common.exit_codes import ProcessExitCode  # noqa: E402
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey  # noqa: E402
from nvflare.fuel.f3.message import Message as CellMessage  # noqa: E402
from nvflare.private.admin_defs import Message  # noqa: E402
from nvflare.private.defs import CellMessageHeaderKeys, JobFailureMsgKey  # noqa: E402
from nvflare.private.fed.server.fed_server import FederatedServer  # noqa: E402
from nvflare.private.fed.server.job_runner import JobRunner  # noqa: E402
from nvflare.private.fed.server.server_state import HotState  # noqa: E402


assert os.path.realpath(__import__("nvflare").__file__).startswith(SOURCE)


logging.basicConfig(level=logging.CRITICAL)


class Reply:
    def __init__(self, client_name: str):
        self.client_name = client_name
        self.reply = Message(topic="reply_start_job", body="Start the client app.")


class FakeJobManager:
    def __init__(self, job: Job, trace: list[str]):
        self.job = job
        self.trace = trace
        self.status_history: list[str] = [RunStatus.SUBMITTED.value]
        self.job.meta[JobMetaKey.STATUS] = RunStatus.SUBMITTED
        self.job.meta[JobMetaKey.SCHEDULE_COUNT] = 1
        self.job.meta[JobMetaKey.LAST_SCHEDULE_TIME] = 0
        self.job.meta[JobMetaKey.SCHEDULE_HISTORY] = []

    def get_jobs_to_schedule(self, fl_ctx):
        return [self.job] if self.job.meta.get(JobMetaKey.STATUS) == RunStatus.SUBMITTED else []

    def get_job(self, jid, fl_ctx=None):
        assert jid == self.job.job_id
        return self.job

    def set_status(self, jid, status, fl_ctx):
        assert jid == self.job.job_id
        self.job.meta[JobMetaKey.STATUS] = status
        self.status_history.append(status.value)
        self.trace.append(f"set_status({jid}, {status.value})")

    def update_meta(self, jid, meta, fl_ctx):
        assert jid == self.job.job_id
        self.job.meta.update(meta)
        self.trace.append(f"update_meta({jid}, {sorted(meta)})")

    def save_workspace(self, jid, ws_dirs, fl_ctx):
        return os.path.join(tempfile.gettempdir(), f"{jid}.zip")


class FakeScheduler:
    def __init__(self, sites):
        self.sites = sites

    def schedule_job(self, job_manager, job_candidates, fl_ctx):
        if job_candidates:
            return job_candidates[0], self.sites
        return None, None

    def remove_scheduled_job(self, job_id):
        pass

    def restore_scheduled_job(self, job_id):
        pass


class FakeClientManager:
    def __init__(self, clients_by_token):
        self.clients = clients_by_token

    def get_clients(self):
        return self.clients

    def is_from_authorized_client(self, token):
        return token in self.clients


class FakeSai:
    def __init__(self, engine):
        self.engine = engine

    def new_context(self):
        return self.engine.new_context()


class FakeAdminServer:
    def __init__(self, engine):
        self.timeout = 0.1
        self.sai = FakeSai(engine)

    def send_requests(self, requests, fl_ctx, timeout_secs=None, optional=False):
        return []


class FakeEngine:
    def __init__(self, runner, job_manager, clients, workspace_root, trace, mode):
        os.makedirs(os.path.join(workspace_root, "startup"), exist_ok=True)
        os.makedirs(os.path.join(workspace_root, "local"), exist_ok=True)
        self.job_runner = runner
        self.job_manager = job_manager
        self.trace = trace
        self.mode = mode
        self.lock = threading.Lock()
        self.run_processes = {}
        self.exception_run_processes = {}
        self.client_manager = FakeClientManager({c.token: c for c in clients})
        self.server = SimpleNamespace(server_state=HotState(), admin_server=FakeAdminServer(self))
        self.workspace = Workspace(workspace_root, SiteType.SERVER)
        self.ctx_mgr = FLContextManager(
            engine=self,
            identity_name="server",
            job_id="",
            public_stickers={},
            private_stickers={
                FLContextKey.WORKSPACE_OBJECT: self.workspace,
                FLContextKey.WORKSPACE_ROOT: workspace_root,
            },
        )

    def new_context(self):
        return self.ctx_mgr.new_context()

    def get_clients(self):
        return list(self.client_manager.clients.values())

    def get_workspace(self):
        return self.workspace

    def get_component(self, component_id):
        if component_id == SystemComponents.JOB_MANAGER:
            return self.job_manager
        return None

    def get_job_clients(self, client_sites):
        by_name = {c.name: c for c in self.client_manager.clients.values()}
        return {by_name[name].token: by_name[name] for name in client_sites}

    def start_app_on_server(self, fl_ctx, job=None, job_clients=None, snapshot=None):
        self.run_processes[job.job_id] = {
            RunProcessKey.JOB_ID: job.job_id,
            RunProcessKey.PARTICIPANTS: dict(job_clients),
        }
        self.trace.append(f"start_app_on_server({job.job_id}) registered run_process")
        return ""

    def validate_targets(self, client_sites):
        by_name = {c.name: c for c in self.client_manager.clients.values()}
        clients = []
        invalid = []
        for name in client_sites:
            c = by_name.get(name)
            if c:
                clients.append(c)
            else:
                invalid.append(name)
        return clients, invalid

    def abort_app_on_server(self, job_id):
        self.trace.append(f"abort_app_on_server({job_id})")
        self.run_processes.pop(job_id, None)
        return ""

    def remove_exception_process(self, job_id):
        self.trace.append(f"remove_exception_process({job_id})")
        self.exception_run_processes.pop(job_id, None)

    def start_client_job(self, job, client_sites, fl_ctx):
        self.trace.append(f"start_client_job({job.job_id}) entered; pending={self.job_runner._pending_client_outcomes}")
        if self.mode == "failure_during_start":
            report_failure_via_real_handler(self, "site-1", job.job_id)
        return [Reply("site-1"), Reply("site-2")]


def report_failure_via_real_handler(engine: FakeEngine, client_name: str, job_id: str):
    token = {c.name: t for t, c in engine.client_manager.clients.items()}[client_name]
    fake_server = SimpleNamespace(
        client_manager=engine.client_manager,
        engine=engine,
        logger=logging.getLogger("FederatedServerHarness"),
    )
    request = CellMessage(
        headers={MessageHeaderKey.ORIGIN: client_name, CellMessageHeaderKeys.TOKEN: token},
        payload={
            JobFailureMsgKey.JOB_ID: job_id,
            JobFailureMsgKey.CODE: ProcessExitCode.EXCEPTION,
            JobFailureMsgKey.REASON: "deterministic client crash during START collection",
        },
    )
    engine.trace.append(f"process_job_failure({client_name}, {job_id}, EXCEPTION) begin")
    reply = FederatedServer.process_job_failure(fake_server, request)
    engine.trace.append(
        "process_job_failure end; "
        f"pending={engine.job_runner._pending_client_outcomes}; "
        f"exception_entry={engine.exception_run_processes.get(job_id)}; "
        f"reply_rc={reply.get_header(MessageHeaderKey.RETURN_CODE)}"
    )


def make_job(job_id: str) -> Job:
    meta = {
        JobMetaKey.JOB_ID: job_id,
        JobMetaKey.DEPLOY_MAP: {"app": [SiteType.SERVER, "site-1", "site-2"]},
        JobMetaKey.RESOURCE_SPEC: {},
        JobMetaKey.MIN_CLIENTS: 1,
    }
    return Job(
        job_id=job_id,
        resource_spec={},
        deploy_map={"app": [SiteType.SERVER, "site-1", "site-2"]},
        meta=meta,
        min_sites=1,
        required_sites=[],
    )


def run_scenario(mode: str):
    trace: list[str] = []
    root = tempfile.mkdtemp(prefix=f"mc4-{mode}-")
    runner = JobRunner(workspace_root=root)
    for name in ("log_info", "log_debug", "log_warning", "log_error", "log_exception"):
        setattr(runner, name, lambda fl_ctx, msg, _n=name: trace.append(f"{_n}: {msg}"))
    runner.fire_event = lambda event_type, fl_ctx: trace.append(f"event({event_type})")
    runner.fire_event_with_data = lambda event_type, fl_ctx, key, data: trace.append(f"event({event_type}, {data})")

    job = make_job(f"job-{mode}")
    manager = FakeJobManager(job, trace)
    clients = [Client("site-1", "tok-site-1"), Client("site-2", "tok-site-2")]
    sites = {
        SiteType.SERVER: DispatchInfo("app", {}, None),
        "site-1": DispatchInfo("app", {}, "reserve-1"),
        "site-2": DispatchInfo("app", {}, "reserve-2"),
    }
    engine = FakeEngine(runner, manager, clients, root, trace, mode)
    runner.scheduler = FakeScheduler(sites)
    runner._deploy_job = lambda ready_job, scheduled_sites, fl_ctx: (ready_job.job_id, [])

    with engine.new_context() as fl_ctx:
        fl_ctx.set_prop(FLContextKey.CURRENT_JOB_ID, job.job_id)

        out = {}

        def target():
            try:
                runner.run(fl_ctx)
            except BaseException as exc:  # should not happen for this bug; run() catches the KeyError path.
                out["runner_exception"] = f"{type(exc).__name__}: {exc}"

        thread = threading.Thread(target=target, name=f"JobRunner.run/{mode}")
        thread.start()

        def status():
            value = job.meta.get(JobMetaKey.STATUS)
            return value.value if hasattr(value, "value") else value

        deadline = time.time() + 15.0
        if mode == "failure_after_start":
            while time.time() < deadline and status() != RunStatus.RUNNING.value:
                time.sleep(0.05)
            if status() != RunStatus.RUNNING.value:
                raise RuntimeError("control did not reach RUNNING")
            report_failure_via_real_handler(engine, "site-1", job.job_id)
            while time.time() < deadline and not str(status()).startswith("FINISHED:"):
                time.sleep(0.05)
        else:
            while time.time() < deadline and status() != RunStatus.FAILED_TO_RUN.value:
                time.sleep(0.05)

        runner.ask_to_stop = True
        thread.join(timeout=10.0)
        if thread.is_alive():
            raise RuntimeError(f"runner thread did not stop in {mode}")

    return {
        "mode": mode,
        "final_status": job.meta.get(JobMetaKey.STATUS).value,
        "status_history": manager.status_history,
        "runner_exception": out.get("runner_exception"),
        "running_jobs": sorted(runner.running_jobs),
        "pending_client_outcomes": {k: sorted(v) for k, v in runner._pending_client_outcomes.items()},
        "exception_run_processes": {
            k: v.get(RunProcessKey.PROCESS_RETURN_CODE) for k, v in engine.exception_run_processes.items()
        },
        "trace": trace,
    }


def main():
    failing = run_scenario("failure_during_start")
    control = run_scenario("failure_after_start")

    reproduced = (
        failing["final_status"] == RunStatus.FAILED_TO_RUN.value
        and any("KeyError" in line for line in failing["trace"])
        and failing["exception_run_processes"]
        and control["final_status"] == RunStatus.FINISHED_EXECUTION_EXCEPTION.value
    )

    print("MC-4 reproduction result")
    print(json.dumps({"failing_window": failing, "after_start_control": control}, indent=2, default=str))
    if reproduced:
        print(
            "BUG TRIGGERED: failure during START collection raised KeyError and published "
            "FINISHED:FAILED_TO_RUN; the same failure after running_jobs insertion published "
            "FINISHED:EXECUTION_EXCEPTION."
        )
        return 0
    print("BUG NOT TRIGGERED")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
