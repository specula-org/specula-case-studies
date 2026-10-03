#!/usr/bin/env python3
"""CR-17 reproduction: UNSAFE_COMPONENT during startup is finalized as completed.

Level 1 timing assistance. The test runs the real JobRunner.run loop, the real
DefaultJobScheduler, and the real FederatedServer.process_job_failure handler.
Only deployment/network/process edges are fake: they provide one scheduled job,
two connected clients, and a deterministic client terminal report while
_start_run is still waiting for START_JOB replies.
"""

import json
import logging
import os
import sys
import tempfile
import threading
import time
from types import SimpleNamespace

SOURCE = (
    "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/"
    "gpt-continuation/nvflare-job/.specula-output/confirmation/CR-17/worktree"
)
sys.path.insert(0, SOURCE)

from nvflare.apis.client import Client
from nvflare.apis.event_type import EventType
from nvflare.apis.fl_constant import FLContextKey, ReservedKey, RunProcessKey, SystemComponents
from nvflare.apis.fl_context import FLContext
from nvflare.apis.job_def import Job, JobMetaKey, RunStatus
from nvflare.apis.server_engine_spec import ServerEngineSpec
from nvflare.apis.workspace import Workspace
from nvflare.app_common.job_schedulers.job_scheduler import DefaultJobScheduler
from nvflare.fuel.common.exit_codes import ProcessExitCode
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey
from nvflare.private.admin_defs import Message, ok_reply
from nvflare.private.defs import CellMessageHeaderKeys, JobFailureMsgKey, TrainingTopic, new_cell_message
from nvflare.private.fed.server.fed_server import FederatedServer
from nvflare.private.fed.server.job_runner import JobRunner
from nvflare.private.fed.server.message_send import ClientReply
from nvflare.private.fed.server.server_state import HotState

logging.basicConfig(level=logging.WARNING)


class MemoryJobManager:
    def __init__(self, job):
        self.job = job
        self.status_history = []
        self.status_event = threading.Event()
        self.lock = threading.Lock()

    def get_jobs_to_schedule(self, fl_ctx):
        with self.lock:
            if self.job.meta[JobMetaKey.STATUS.value] == RunStatus.SUBMITTED:
                return [self.job]
            return []

    def get_job(self, job_id, fl_ctx):
        if job_id != self.job.job_id:
            return None
        return self.job

    def set_status(self, job_id, status, fl_ctx):
        if job_id != self.job.job_id:
            raise KeyError(job_id)
        with self.lock:
            self.job.meta[JobMetaKey.STATUS.value] = status
            self.status_history.append(status.value if isinstance(status, RunStatus) else str(status))
            if str(status).startswith("RunStatus.FINISHED") or str(status).startswith("FINISHED"):
                self.status_event.set()

    def update_meta(self, job_id, meta, fl_ctx):
        self.job.meta.update(meta)

    def refresh_meta(self, job, meta_keys, fl_ctx):
        return None

    def save_workspace(self, job_id, ws_dirs, fl_ctx):
        return "not-used"


class FakeAdminServer:
    def __init__(self, engine):
        self.sai = engine
        self.timeout = 2.0
        self.abort_requests = []

    def send_requests(self, requests, fl_ctx, timeout_secs=2.0, optional=False):
        replies = []
        for token, req in requests.items():
            client = self.sai.client_manager.clients[token]
            self.abort_requests.append({"token": token, "job": req.get_header("job_id")})
            replies.append(ClientReply(token, client.name, req, ok_reply()))
        return replies


class FakeEngine(ServerEngineSpec):
    def __init__(self, workspace_root):
        os.makedirs(os.path.join(workspace_root, "startup"), exist_ok=True)
        os.makedirs(os.path.join(workspace_root, "local"), exist_ok=True)
        self.workspace = Workspace(root_dir=workspace_root, site_name="server")
        self.clients_by_token = {
            "token-1": Client("site-1", "token-1"),
            "token-2": Client("site-2", "token-2"),
        }
        self.clients_by_name = {c.name: c for c in self.clients_by_token.values()}
        self.client_manager = SimpleNamespace(
            clients=self.clients_by_token,
            is_from_authorized_client=lambda token: token in self.clients_by_token,
        )
        self.lock = threading.Lock()
        self.run_processes = {}
        self.exception_run_processes = {}
        self.events = []
        self.server_abort_calls = []
        self.failure_replies = []
        self.components = {}
        self.job_runner = None
        self.server = FederatedServer.__new__(FederatedServer)
        self.server.engine = self
        self.server.client_manager = self.client_manager
        self.server.logger = logging.getLogger("FederatedServer")
        self.server.server_state = HotState(host="localhost", port="8002")
        self.server.admin_server = FakeAdminServer(self)
        self._unsafe_reported = False

    def _ctx(self):
        ctx = FLContext()
        ctx.put(ReservedKey.ENGINE, self, private=True, sticky=False)
        ctx.put(ReservedKey.IDENTITY_NAME, "server", private=True, sticky=False)
        return ctx

    def validate_targets(self, target_names):
        clients = []
        invalid = []
        for name in target_names:
            client = self.clients_by_name.get(name)
            if client:
                clients.append(client)
            else:
                invalid.append(name)
        return clients, invalid

    def fire_event(self, event_type, fl_ctx):
        data = fl_ctx.get_prop(FLContextKey.EVENT_DATA)
        job_id = data.get(JobMetaKey.JOB_ID.value) if isinstance(data, dict) else None
        self.events.append((event_type, job_id))
        scheduler = self.components.get(SystemComponents.JOB_SCHEDULER)
        if scheduler:
            scheduler.handle_event(event_type, fl_ctx)

    def get_clients(self):
        return list(self.clients_by_token.values())

    def sync_clients_from_main_process(self):
        return None

    def update_job_run_status(self):
        return None

    def new_context(self):
        return self._ctx()

    def get_workspace(self):
        return self.workspace

    def add_component(self, component_id, component):
        self.components[component_id] = component

    def get_component(self, component_id):
        return self.components.get(component_id)

    def register_aux_message_handler(self, topic, message_handle_func):
        raise NotImplementedError

    def send_aux_request(self, targets, topic, request, timeout, fl_ctx, optional=False, secure=False):
        raise NotImplementedError

    def multicast_aux_requests(self, topic, target_requests, timeout, fl_ctx, optional=False, secure=False):
        raise NotImplementedError

    def get_widget(self, widget_id):
        return None

    def persist_components(self, fl_ctx, completed):
        return None

    def restore_components(self, snapshot, fl_ctx):
        return None

    def get_client_name_from_token(self, token):
        return self.clients_by_token[token].name

    def check_client_resources(self, job, resource_reqs, fl_ctx):
        return {site: (True, f"reserve-{site}") for site in resource_reqs}

    def cancel_client_resources(self, resource_check_results, resource_reqs, fl_ctx):
        return None

    def get_job_clients(self, client_sites):
        return {self.clients_by_name[name].token: self.clients_by_name[name] for name in client_sites}

    def start_app_on_server(self, fl_ctx, job=None, job_clients=None, snapshot=None):
        with self.lock:
            self.run_processes[job.job_id] = {
                RunProcessKey.JOB_ID: job.job_id,
                RunProcessKey.PARTICIPANTS: job_clients,
            }
        return ""

    def abort_app_on_server(self, job_id, turn_to_cold=False):
        self.server_abort_calls.append(job_id)
        with self.lock:
            self.run_processes.pop(job_id, None)
        return ""

    def remove_exception_process(self, job_id):
        with self.lock:
            self.exception_run_processes.pop(job_id, None)

    def start_client_job(self, job, client_sites, fl_ctx):
        if not self._unsafe_reported:
            self._unsafe_reported = True
            self._report_client_outcome("site-1", job.job_id, ProcessExitCode.UNSAFE_COMPONENT, "unsafe component")
            # The second client exits after the unsafe stop and reports a normal terminal outcome.
            self._report_client_outcome("site-2", job.job_id, 0, None)

        replies = []
        for name in client_sites:
            client = self.clients_by_name[name]
            replies.append(ClientReply(client.token, name, Message(TrainingTopic.START_JOB, ""), ok_reply()))
        return replies

    def _report_client_outcome(self, client_name, job_id, code, reason):
        client = self.clients_by_name[client_name]
        request = new_cell_message(
            {
                CellMessageHeaderKeys.TOKEN: client.token,
                MessageHeaderKey.ORIGIN: client_name,
            },
            {
                JobFailureMsgKey.JOB_ID: job_id,
                JobFailureMsgKey.CODE: code,
                JobFailureMsgKey.REASON: reason,
            },
        )
        reply = self.server.process_job_failure(request)
        self.failure_replies.append(
            {
                "client": client_name,
                "code": code,
                "return_code": reply.get_header(MessageHeaderKey.RETURN_CODE),
            }
        )


def wait_until(predicate, timeout=8.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return False


def main():
    job_id = "job-cr17"
    meta = {
        JobMetaKey.JOB_ID.value: job_id,
        JobMetaKey.JOB_NAME.value: "cr17-unsafe-startup",
        JobMetaKey.STATUS.value: RunStatus.SUBMITTED,
        JobMetaKey.DEPLOY_MAP.value: {"app": ["server", "site-1", "site-2"]},
        JobMetaKey.MIN_CLIENTS.value: 1,
        JobMetaKey.RESOURCE_SPEC.value: {},
        JobMetaKey.SCHEDULE_COUNT.value: 0,
        JobMetaKey.LAST_SCHEDULE_TIME.value: 0.0,
        JobMetaKey.SCHEDULE_HISTORY.value: [],
        JobMetaKey.SUBMIT_TIME.value: 1.0,
    }
    job = Job(
        job_id=job_id,
        resource_spec={},
        deploy_map=meta[JobMetaKey.DEPLOY_MAP.value],
        meta=meta,
        min_sites=1,
        required_sites=[],
    )

    with tempfile.TemporaryDirectory(prefix="cr17-nvflare-") as tmp:
        engine = FakeEngine(tmp)
        job_manager = MemoryJobManager(job)
        scheduler = DefaultJobScheduler(max_jobs=1, min_schedule_interval=0.0)
        runner = JobRunner(workspace_root=tmp)
        runner.scheduler = scheduler
        runner._deploy_job = lambda ready_job, sites, fl_ctx: (ready_job.job_id, [])
        engine.job_runner = runner
        engine.add_component(SystemComponents.JOB_MANAGER, job_manager)
        engine.add_component(SystemComponents.JOB_SCHEDULER, scheduler)

        runner_thread = threading.Thread(target=runner.run, args=(engine.new_context(),), name="JobRunner.run")
        runner_thread.start()
        try:
            if not job_manager.status_event.wait(8.0):
                raise AssertionError(f"timed out waiting for terminal status; history={job_manager.status_history}")

            runner.ask_to_stop = True
            runner_thread.join(timeout=4.0)
            if runner_thread.is_alive():
                raise AssertionError("JobRunner.run did not stop")

            final_status = job.meta[JobMetaKey.STATUS.value]
            final_status_value = final_status.value if isinstance(final_status, RunStatus) else str(final_status)
            unsafe_marker_after_report = bool(engine.server_abort_calls) and not any(
                j.run_aborted for j in runner.running_jobs.values()
            )
            result = {
                "level": 1,
                "unsafe_report_replies": engine.failure_replies,
                "server_abort_calls": engine.server_abort_calls,
                "events": [(e.value if hasattr(e, "value") else e, jid) for e, jid in engine.events],
                "status_history": job_manager.status_history,
                "final_status": final_status_value,
                "expected_status": RunStatus.FINISHED_ABORTED.value,
                "wrong_status_observed_by": "JobRunner._job_complete_process -> job_manager.set_status",
                "unsafe_marker_missed_before_running_jobs": unsafe_marker_after_report,
            }
            print(json.dumps(result, indent=2, sort_keys=True))

            assert engine.server_abort_calls == [job_id], "unsafe report did not abort the server job"
            assert final_status == RunStatus.FINISHED_COMPLETED, (
                "CR-17 no longer reproduces: expected the buggy FINISHED_COMPLETED status, "
                f"got {final_status_value}"
            )
            print("CR-17 reproduced: unsafe startup abort finalized as FINISHED:COMPLETED")
        finally:
            runner.ask_to_stop = True
            runner_thread.join(timeout=4.0)


if __name__ == "__main__":
    main()
