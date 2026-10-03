#!/usr/bin/env python3
"""Reproduce MC-11 against the pinned NVFlare worktree.

The test drives the real JobRunner startup/completion path and the real
FederatedServer.process_job_failure handler. The harness controls only the
environment edges: scheduler selection, client replies, and the timing of a
clean server-job process exit.
"""

from __future__ import annotations

import logging
import os
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
from unittest.mock import patch


SOURCE = (
    "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/"
    "gpt-continuation/nvflare-job/.specula-output/confirmation/MC-11/worktree"
)
sys.path.insert(0, SOURCE)

from nvflare.apis.client import Client  # noqa: E402
from nvflare.apis.event_type import EventType  # noqa: E402
from nvflare.apis.fl_constant import FLContextKey, RunProcessKey, SiteType, SystemComponents  # noqa: E402
from nvflare.apis.fl_context import FLContextManager  # noqa: E402
from nvflare.apis.job_def import Job, JobMetaKey, RunStatus  # noqa: E402
from nvflare.apis.job_launcher_spec import JobReturnCode  # noqa: E402
from nvflare.apis.job_scheduler_spec import DispatchInfo  # noqa: E402
from nvflare.fuel.common.exit_codes import ProcessExitCode  # noqa: E402
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey  # noqa: E402
from nvflare.fuel.f3.cellnet.defs import ReturnCode as F3ReturnCode  # noqa: E402
from nvflare.private.admin_defs import Message, MsgHeader, ReturnCode, ok_reply  # noqa: E402
from nvflare.private.defs import CellMessageHeaderKeys, JobFailureMsgKey, new_cell_message  # noqa: E402
from nvflare.private.fed.server.fed_server import FederatedServer  # noqa: E402
from nvflare.private.fed.server.job_runner import JobRunner  # noqa: E402
from nvflare.private.fed.server.message_send import ClientReply  # noqa: E402
from nvflare.private.fed.server.server_state import HotState  # noqa: E402


JOB_ID = "job-mc11"
CLIENT_NAME = "site-1"
CLIENT_TOKEN = "token-site-1"


class RecordingJobManager:
    def __init__(self, job: Job):
        self.job = job
        self.history = []
        self.lock = threading.Lock()

    def get_job(self, jid, fl_ctx):
        assert jid == self.job.job_id
        return self.job

    def get_jobs_to_schedule(self, fl_ctx):
        with self.lock:
            if self.job.meta.get(JobMetaKey.STATUS) == RunStatus.SUBMITTED:
                return [self.job]
        return []

    def set_status(self, job_id, status, fl_ctx):
        assert job_id == self.job.job_id
        with self.lock:
            self.job.meta[JobMetaKey.STATUS] = status
            self.history.append(status.value if hasattr(status, "value") else str(status))

    def update_meta(self, job_id, meta, fl_ctx):
        assert job_id == self.job.job_id
        with self.lock:
            self.job.meta.update(meta)

    def save_workspace(self, job_id, ws_dirs, fl_ctx):
        return f"memory://{job_id}"


class OneJobScheduler:
    def __init__(self, job: Job):
        self.job = job
        self.used = False

    def schedule_job(self, job_manager, job_candidates, fl_ctx):
        if self.used or self.job not in job_candidates:
            return None, None
        self.used = True
        return self.job, {CLIENT_NAME: DispatchInfo("client_app", {}, CLIENT_TOKEN)}


class FakeWorkspace:
    def __init__(self, root):
        self.root = root

    def get_run_dir(self, job_id):
        return os.path.join(self.root, "server", job_id, "run")

    def get_result_root(self, job_id):
        return os.path.join(self.root, "server", job_id, "result")

    def get_log_root(self, job_id):
        return os.path.join(self.root, "server", job_id, "log")

    def get_audit_root(self, job_id):
        return os.path.join(self.root, "server", job_id, "audit")


class FakeAdminServer:
    def __init__(self, engine):
        self.timeout = 1.0
        self.sai = SimpleNamespace(new_context=engine.new_context)
        self.engine = engine

    def send_requests(self, requests, fl_ctx, timeout_secs=2.0, optional=False):
        replies = []
        for token, req in requests.items():
            client = self.engine.client_manager.clients[token]
            replies.append(ClientReply(token, client.name, req, ok_reply()))
        return replies

    def send_requests_and_get_reply_dict(self, requests, timeout_secs=1.0):
        return {token: ok_reply() for token in requests}


class FakeEngine:
    def __init__(self, root, job_manager, runner):
        self.root = root
        self.job_manager = job_manager
        self.job_runner = runner
        self.lock = threading.Lock()
        self.run_processes = {}
        self.exception_run_processes = {}
        self.client = Client(CLIENT_NAME, CLIENT_TOKEN)
        self.client_manager = SimpleNamespace(clients={CLIENT_TOKEN: self.client})
        self.server = SimpleNamespace(server_state=HotState())
        self.server.admin_server = FakeAdminServer(self)
        self.ctx_mgr = FLContextManager(engine=self, identity_name=SiteType.SERVER)
        self.workspace = FakeWorkspace(root)
        self.failure_reply_code = None
        self.failure_report_sent = False
        self.events = []

    def new_context(self):
        return self.ctx_mgr.new_context()

    def get_component(self, component_id):
        if component_id == SystemComponents.JOB_MANAGER:
            return self.job_manager
        return None

    def get_clients(self):
        return list(self.client_manager.clients.values())

    def get_job_clients(self, client_sites):
        return {CLIENT_TOKEN: self.client}

    def validate_targets(self, client_sites):
        valid = [self.client for name in client_sites if name == CLIENT_NAME]
        invalid = [name for name in client_sites if name != CLIENT_NAME]
        return valid, invalid

    def get_workspace(self):
        return self.workspace

    def fire_event(self, event_type, fl_ctx):
        self.events.append(event_type)

    def start_app_on_server(self, fl_ctx, job=None, job_clients=None, snapshot=None):
        with self.lock:
            self.run_processes[job.job_id] = {
                RunProcessKey.JOB_ID: job.job_id,
                RunProcessKey.PARTICIPANTS: job_clients,
            }
        return ""

    def _simulate_clean_server_job_exit(self, job_id):
        with self.lock:
            self.run_processes.pop(job_id, None)

    def _send_client_failure(self, job_id):
        request = new_cell_message(
            {
                CellMessageHeaderKeys.TOKEN: CLIENT_TOKEN,
                MessageHeaderKey.ORIGIN: CLIENT_NAME,
            },
            {
                JobFailureMsgKey.JOB_ID: job_id,
                JobFailureMsgKey.CODE: ProcessExitCode.EXCEPTION,
                JobFailureMsgKey.REASON: "client process failed during startup",
            },
        )
        server_facade = SimpleNamespace(
            client_manager=SimpleNamespace(
                clients={CLIENT_TOKEN: self.client},
                is_from_authorized_client=lambda token: token == CLIENT_TOKEN,
            ),
            engine=self,
            logger=logging.getLogger("mc11.repro.fed_server"),
        )
        reply = FederatedServer.process_job_failure(server_facade, request)
        self.failure_reply_code = reply.get_header(MessageHeaderKey.RETURN_CODE)
        self.failure_report_sent = True

    def start_client_job(self, job, client_sites, fl_ctx):
        self._simulate_clean_server_job_exit(job.job_id)
        self._send_client_failure(job.job_id)
        reply = Message(topic="reply", body="ok")
        reply.set_header(MsgHeader.RETURN_CODE, ReturnCode.OK)
        return [ClientReply(CLIENT_TOKEN, CLIENT_NAME, Message(topic="start", body=""), reply)]

    def abort_app_on_server(self, job_id):
        with self.lock:
            self.run_processes.pop(job_id, None)
        return ""

    def remove_exception_process(self, job_id):
        with self.lock:
            self.exception_run_processes.pop(job_id, None)


def make_job(job_id=JOB_ID):
    meta = {
        JobMetaKey.JOB_ID: job_id,
        JobMetaKey.STATUS: RunStatus.SUBMITTED,
        JobMetaKey.DEPLOY_MAP: {"client_app": [CLIENT_NAME]},
        JobMetaKey.RESOURCE_SPEC: {},
        JobMetaKey.MIN_CLIENTS: 1,
        JobMetaKey.MANDATORY_CLIENTS: [],
    }
    return Job(
        job_id=job_id,
        resource_spec={},
        deploy_map={"client_app": [CLIENT_NAME]},
        meta=meta,
        min_sites=1,
        required_sites=[],
    )


def install_log_capture(runner: JobRunner, sink: list[str]):
    def capture(fl_ctx, msg, *args, **kwargs):
        sink.append(str(msg))

    runner.log_info = capture
    runner.log_warning = capture
    runner.log_debug = capture
    runner.log_error = capture
    runner.log_exception = capture


def wait_for_terminal(job_manager: RecordingJobManager, runner: JobRunner, timeout=7.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        with job_manager.lock:
            status = job_manager.job.meta.get(JobMetaKey.STATUS)
        status_value = status.value if hasattr(status, "value") else str(status)
        if status_value.startswith("FINISHED:") and JOB_ID not in runner.running_jobs:
            return status
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for terminal status; history={job_manager.history}")


def run_startup_gap_repro():
    with tempfile.TemporaryDirectory(prefix="mc11-startup-gap-") as root:
        job = make_job()
        runner = JobRunner(workspace_root=root)
        logs = []
        install_log_capture(runner, logs)
        job_manager = RecordingJobManager(job)
        engine = FakeEngine(root, job_manager, runner)
        runner.scheduler = OneJobScheduler(job)

        with engine.new_context() as fl_ctx:
            with patch.object(runner, "_deploy_job", return_value=(JOB_ID, [])):
                run_thread = threading.Thread(target=runner.run, args=(fl_ctx,), name="job-runner")
                run_thread.start()
                try:
                    final_status = wait_for_terminal(job_manager, runner)
                finally:
                    runner.stop()
                    run_thread.join(timeout=3.0)
                assert not run_thread.is_alive(), "JobRunner thread did not stop"

        lost_failure_log = any("can not be failed" in msg for msg in logs)
        assert engine.failure_report_sent, "client failure report was not sent"
        assert engine.failure_reply_code == F3ReturnCode.OK, engine.failure_reply_code
        assert lost_failure_log, logs
        assert final_status == RunStatus.FINISHED_COMPLETED, final_status
        assert JOB_ID not in engine.exception_run_processes
        assert not runner._pending_client_outcomes.get(JOB_ID)
        return {
            "status_history": job_manager.history,
            "failure_reply_code": engine.failure_reply_code,
            "lost_failure_log": lost_failure_log,
            "exception_record_present": JOB_ID in engine.exception_run_processes,
            "events": list(engine.events),
        }


def run_active_tracking_control():
    with tempfile.TemporaryDirectory(prefix="mc11-active-control-") as root:
        job = make_job()
        runner = JobRunner(workspace_root=root)
        logs = []
        install_log_capture(runner, logs)
        job_manager = RecordingJobManager(job)
        engine = FakeEngine(root, job_manager, runner)
        engine.start_app_on_server(None, job=job, job_clients={CLIENT_TOKEN: engine.client})
        runner.running_jobs[JOB_ID] = job
        runner._pending_client_outcomes[JOB_ID] = {CLIENT_NAME}

        engine._send_client_failure(JOB_ID)
        assert engine.failure_reply_code == F3ReturnCode.OK, engine.failure_reply_code
        assert JOB_ID in engine.exception_run_processes
        assert (
            engine.exception_run_processes[JOB_ID][RunProcessKey.PROCESS_RETURN_CODE]
            == ProcessExitCode.EXCEPTION
        )
        status = runner._get_finished_job_status(engine, job, engine.new_context())
        assert status == RunStatus.FINISHED_EXECUTION_EXCEPTION, status
        return {
            "failure_reply_code": engine.failure_reply_code,
            "recorded_exception_code": engine.exception_run_processes[JOB_ID][
                RunProcessKey.PROCESS_RETURN_CODE
            ],
            "classified_status": status,
            "pending_after_report": runner._pending_client_outcomes.get(JOB_ID),
        }


def main():
    imported = os.path.realpath(sys.modules["nvflare"].__file__)
    assert imported.startswith(os.path.realpath(SOURCE)), imported

    repro = run_startup_gap_repro()
    control = run_active_tracking_control()

    print("MC-11 startup-gap reproduction")
    print(f"worktree={SOURCE}")
    print(f"repro.failure_reply_code={repro['failure_reply_code']}")
    print(f"repro.fail_run_inactive_log={repro['lost_failure_log']}")
    print(f"repro.exception_record_present={repro['exception_record_present']}")
    print(f"repro.status_history={repro['status_history']}")
    print(f"active_control.failure_reply_code={control['failure_reply_code']}")
    print(f"active_control.recorded_exception_code={control['recorded_exception_code']}")
    print(f"active_control.classified_status={control['classified_status']}")
    print(f"active_control.pending_after_report={control['pending_after_report']}")
    print("RESULT=REPRODUCED")


if __name__ == "__main__":
    main()
