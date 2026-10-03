#!/usr/bin/env python3
"""Reproduce CR-10 against pinned NVFlare source.

The harness uses real NVFlare job-runner, scheduler, client-manager,
admin-command, and federated-server outcome handling code. It stubs only the
deployment/process edges needed to avoid starting an actual FL cluster.
"""

import logging
import os
import sys
import tempfile
import threading
from types import MethodType, SimpleNamespace
from unittest.mock import patch


SOURCE = (
    "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/"
    "gpt-continuation/nvflare-job/.specula-output/confirmation/CR-10/worktree"
)
sys.path.insert(0, SOURCE)

from nvflare.apis.client import Client
from nvflare.apis.event_type import EventType
from nvflare.apis.fl_constant import FLContextKey, RunProcessKey, SystemComponents
from nvflare.apis.job_def import Job, JobMetaKey
from nvflare.apis.job_scheduler_spec import DispatchInfo
from nvflare.app_common.job_schedulers.job_scheduler import DefaultJobScheduler
from nvflare.fuel.common.exit_codes import ProcessExitCode
from nvflare.fuel.f3.cellnet.core_cell import Message as CellMessage
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey
from nvflare.private.admin_defs import Message as AdminMessage
from nvflare.private.admin_defs import MsgHeader, ReturnCode
from nvflare.private.defs import CellMessageHeaderKeys, JobFailureMsgKey
from nvflare.private.fed.server.client_manager import ClientManager
from nvflare.private.fed.server.fed_server import FederatedServer
from nvflare.private.fed.server.job_runner import JobRunner
from nvflare.private.fed.server.message_send import ClientReply
from nvflare.private.fed.server.server_engine import ServerEngine
from nvflare.private.fed.server.training_cmds import TrainingCommandModule


JOB_ID = "job-cr10"
CLIENT_NAME = "site-1"
TOKEN = "token-site-1"


class FakeContext:
    def __init__(self, engine=None):
        self.engine = engine
        self.props = {}

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def get_engine(self):
        return self.engine

    def set_prop(self, key, value, *args, **kwargs):
        self.props[key] = value

    def get_prop(self, key, default=None):
        return self.props.get(key, default)

    def remove_prop(self, key):
        self.props.pop(key, None)


class FakeJobManager:
    def __init__(self):
        self.status_updates = []

    def set_status(self, job_id, status, fl_ctx):
        value = status.value if hasattr(status, "value") else str(status)
        self.status_updates.append((job_id, value))


class FakeAdminServer:
    def __init__(self):
        self.dead_tokens = []

    def client_dead(self, token):
        self.dead_tokens.append(token)


class FakeServer:
    def __init__(self, client_manager):
        self.client_manager = client_manager
        self.admin_server = FakeAdminServer()
        self.removed_client_data = []

    def remove_client_data(self, token):
        self.removed_client_data.append(token)


class FakeAdminConnection:
    TARGET_CLIENT_TOKENS = "target_client_tokens"

    def __init__(self, engine):
        self.app_ctx = engine
        self.records = []
        self.props = {}

    def append_dict(self, data, meta=None):
        self.records.append(("dict", data))

    def append_error(self, message, meta=None):
        self.records.append(("error", message))

    def append_success(self, message, meta=None):
        self.records.append(("success", message))

    def get_prop(self, key, default=None):
        return self.props.get(key, default)


def no_log(*args, **kwargs):
    return None


def one_completion_pass(runner, engine, monotonic_value):
    runner.ask_to_stop = False

    def stop_after_sleep(_seconds):
        runner.ask_to_stop = True

    with patch("nvflare.private.fed.server.job_runner.time.monotonic", return_value=monotonic_value):
        with patch("nvflare.private.fed.server.job_runner.time.sleep", side_effect=stop_after_sleep):
            runner._job_complete_process(engine)


def make_started_job_system(tmpdir):
    client = Client(CLIENT_NAME, TOKEN)
    client_manager = ClientManager(project_name="cr10")
    client_manager.clients[TOKEN] = client
    client_manager.name_to_clients[CLIENT_NAME] = client

    job_manager = FakeJobManager()
    scheduler = DefaultJobScheduler(max_jobs=1)
    scheduler.log_debug = no_log

    runner = JobRunner(tmpdir)
    runner.client_outcome_wait_timeout = 2.0
    runner.scheduler = scheduler
    runner._save_workspace = no_log
    runner.abort_client_run = no_log
    runner.log_debug = no_log
    runner.log_info = no_log
    runner.log_warning = no_log
    runner.log_error = no_log
    runner.log_exception = no_log

    engine = ServerEngine.__new__(ServerEngine)
    engine.server = FakeServer(client_manager)
    engine.client_manager = client_manager
    engine.job_runner = runner
    engine.run_processes = {}
    engine.exception_run_processes = {}
    engine.lock = threading.Lock()

    def new_context(self):
        return FakeContext(self)

    def get_component(self, component_id):
        if component_id == SystemComponents.JOB_MANAGER:
            return job_manager
        raise KeyError(component_id)

    def remove_exception_process(self, job_id):
        self.exception_run_processes.pop(job_id, None)

    def get_job_clients(self, client_sites):
        return {TOKEN: client}

    def start_app_on_server(self, fl_ctx, job, job_clients, **kwargs):
        self.run_processes[job.job_id] = {RunProcessKey.PARTICIPANTS: dict(job_clients)}
        return ""

    def start_client_job(self, job, client_sites, fl_ctx):
        request = AdminMessage(topic="start", body="")
        reply = AdminMessage(topic="start_reply", body="")
        reply.set_header(MsgHeader.RETURN_CODE, ReturnCode.OK)
        return [ClientReply(TOKEN, CLIENT_NAME, request, reply)]

    def notify_dead_job(self, job_id, client_name, reason):
        return None

    engine.new_context = MethodType(new_context, engine)
    engine.get_component = MethodType(get_component, engine)
    engine.remove_exception_process = MethodType(remove_exception_process, engine)
    engine.get_job_clients = MethodType(get_job_clients, engine)
    engine.start_app_on_server = MethodType(start_app_on_server, engine)
    engine.start_client_job = MethodType(start_client_job, engine)
    engine.notify_dead_job = MethodType(notify_dead_job, engine)

    def fire_event_with_data(event_type, fl_ctx, key, data):
        event_ctx = FakeContext(engine)
        event_ctx.set_prop(key, data)
        scheduler.handle_event(event_type, event_ctx)

    runner.fire_event_with_data = fire_event_with_data

    job = Job(
        job_id=JOB_ID,
        resource_spec={},
        deploy_map={"client-app": [CLIENT_NAME]},
        meta={JobMetaKey.JOB_ID.value: JOB_ID, JobMetaKey.JOB_NAME.value: "cr10"},
        min_sites=1,
        required_sites=[CLIENT_NAME],
    )
    dispatch = {CLIENT_NAME: DispatchInfo(app_name="client-app", resource_requirements={}, token=TOKEN)}
    fl_ctx = FakeContext(engine)

    # Same reachable state transition as JobRunner.run: _start_run creates
    # pending outcomes and fires JOB_STARTED, then run() records running_jobs.
    runner._start_run(JOB_ID, job, dispatch, fl_ctx)
    with runner.lock:
        runner.running_jobs[JOB_ID] = job
    job_manager.set_status(JOB_ID, "RUNNING", fl_ctx)

    return SimpleNamespace(
        client=client,
        client_manager=client_manager,
        engine=engine,
        job=job,
        job_manager=job_manager,
        runner=runner,
        scheduler=scheduler,
    )


def disabled_client_terminal_report_rc(system):
    fed_server = FederatedServer.__new__(FederatedServer)
    fed_server.client_manager = system.client_manager
    fed_server.engine = system.engine
    fed_server.logger = logging.getLogger("cr10-fed-server")
    request = CellMessage(
        headers={MessageHeaderKey.ORIGIN: CLIENT_NAME, CellMessageHeaderKeys.TOKEN: TOKEN},
        payload={
            JobFailureMsgKey.JOB_ID: JOB_ID,
            JobFailureMsgKey.CODE: 0,
            JobFailureMsgKey.REASON: "client finished after disable",
        },
    )
    reply = FederatedServer.process_job_failure(fed_server, request)
    return reply.get_header(MessageHeaderKey.RETURN_CODE)


def dead_client_control(tmpdir):
    client = Client(CLIENT_NAME, TOKEN)
    runner = JobRunner(tmpdir)
    runner._pending_client_outcomes["control-job"] = {CLIENT_NAME}

    engine = SimpleNamespace(
        job_runner=runner,
        run_processes={"control-job": {RunProcessKey.PARTICIPANTS: {TOKEN: client}}},
        exception_run_processes={},
        notify_dead_job=lambda job_id, client_name, reason: None,
    )
    fed_server = FederatedServer.__new__(FederatedServer)
    fed_server.engine = engine
    fed_server.logger = logging.getLogger("cr10-control")

    FederatedServer.notify_dead_client(fed_server, client)
    return sorted(runner._pending_client_outcomes.get("control-job", set()))


def main():
    with tempfile.TemporaryDirectory(prefix="cr10-repro-") as tmpdir:
        system = make_started_job_system(tmpdir)
        print(f"source={SOURCE}")
        print("level=2 reachable-state harness; product admin, job-runner, scheduler, and outcome handlers are real")
        print(
            "reachable_sequence=JobRunner.run->_start_run creates _pending_client_outcomes; "
            "JOB_STARTED fills DefaultJobScheduler.scheduled_jobs; run() records running_jobs"
        )
        print(f"pending_after_start={sorted(system.runner._pending_client_outcomes[JOB_ID])}")
        print(f"scheduled_jobs_after_start={list(system.scheduler.scheduled_jobs)}")

        conn = FakeAdminConnection(system.engine)
        TrainingCommandModule().disable_client(conn, ["disable_client", CLIENT_NAME])
        print(f"disable_command_records={conn.records}")
        print(f"removed_client_data={system.engine.server.removed_client_data}")
        print(f"admin_dead_tokens={system.engine.server.admin_server.dead_tokens}")
        print(f"authorized_after_disable={system.client_manager.is_from_authorized_client(TOKEN)}")
        print(f"disabled_after_disable={system.client_manager.is_client_disabled(CLIENT_NAME)}")
        print(f"pending_after_disable={sorted(system.runner._pending_client_outcomes[JOB_ID])}")

        terminal_rc = disabled_client_terminal_report_rc(system)
        print(f"disabled_old_token_terminal_report_return_code={terminal_rc}")
        print(f"pending_after_rejected_terminal_report={sorted(system.runner._pending_client_outcomes[JOB_ID])}")

        # The server-side job process has finished cleanly before the disabled
        # client can report its terminal outcome.
        system.engine.run_processes.pop(JOB_ID, None)

        statuses_before_wait = list(system.job_manager.status_updates)
        one_completion_pass(system.runner, system.engine, monotonic_value=0.0)
        first_pass_updates = system.job_manager.status_updates[len(statuses_before_wait) :]
        slot_full_before_deadline = system.scheduler._exceed_max_jobs(FakeContext(system.engine))
        print(f"first_completion_pass_status_updates={first_pass_updates}")
        print(f"outcome_deadline={system.runner._client_outcome_deadlines.get(JOB_ID)}")
        print(f"slot_full_before_deadline={slot_full_before_deadline}")
        print(f"scheduled_jobs_before_deadline={list(system.scheduler.scheduled_jobs)}")

        statuses_before_timeout = list(system.job_manager.status_updates)
        one_completion_pass(system.runner, system.engine, monotonic_value=2.0)
        timeout_updates = system.job_manager.status_updates[len(statuses_before_timeout) :]
        slot_full_after_deadline = system.scheduler._exceed_max_jobs(FakeContext(system.engine))
        print(f"timeout_completion_status_updates={timeout_updates}")
        print(f"slot_full_after_deadline={slot_full_after_deadline}")
        print(f"scheduled_jobs_after_deadline={list(system.scheduler.scheduled_jobs)}")
        print(f"pending_after_deadline={system.runner._pending_client_outcomes.get(JOB_ID)}")

        control_pending = dead_client_control(tmpdir)
        print(f"dead_client_control_pending_after_notify={control_pending}")

        assert sorted(system.runner._pending_client_outcomes.get(JOB_ID, [])) == []
        assert first_pass_updates == []
        assert slot_full_before_deadline is True
        assert timeout_updates == [(JOB_ID, "FINISHED:COMPLETED")]
        assert slot_full_after_deadline is False
        assert control_pending == []
        print("RESULT: BUG REPRODUCED")


if __name__ == "__main__":
    main()
