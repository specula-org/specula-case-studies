#!/usr/bin/env python3
"""Reproduce CR-25: a delayed server-job heartbeat changes normal completion to aborted.

The timing window is reachable through the normal lifecycle:

1. JobRunner has inserted the job in running_jobs and persisted RUNNING.
2. The server-job process exits normally.
3. ServerEngine.wait_for_complete removes the job from run_processes.
4. Before JobRunner._job_complete_process publishes the terminal status, a valid
   SJ HEARTBEAT message that was sent/queued before the SJ exit is delivered.

This test uses real NVFlare heartbeat/completion code.  The harness only replaces
the network abort side effect and workspace archival, neither of which decides
the terminal status being checked here.
"""

from __future__ import annotations

import os
import shutil
import sys
import tempfile
from contextlib import contextmanager
from types import SimpleNamespace

SOURCE = (
    "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/"
    "gpt-continuation/nvflare-job/.specula-output/confirmation/CR-25/worktree"
)
sys.path.insert(0, SOURCE)

from nvflare.apis.fl_constant import ServerCommandNames, SystemComponents  # noqa: E402
from nvflare.apis.fl_context import FLContextManager  # noqa: E402
from nvflare.apis.impl.job_def_manager import SimpleJobDefManager  # noqa: E402
from nvflare.apis.job_def import JobMetaKey, RunStatus  # noqa: E402
from nvflare.app_common.storages.filesystem_storage import FilesystemStorage  # noqa: E402
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey  # noqa: E402
from nvflare.private.defs import CellMessageHeaderKeys, new_cell_message  # noqa: E402
from nvflare.private.fed.server.client_manager import ClientManager  # noqa: E402
from nvflare.private.fed.server.fed_server import FederatedServer  # noqa: E402
from nvflare.private.fed.server.job_runner import JobRunner  # noqa: E402
from nvflare.private.fed.server.server_engine import ServerEngine  # noqa: E402
from nvflare.private.fed.server import job_runner as job_runner_module  # noqa: E402


class MiniRunManager:
    def __init__(self, engine, components):
        self.ctx_mgr = FLContextManager(engine=engine, identity_name="server", job_id="")
        self.components = components

    def new_context(self):
        return self.ctx_mgr.new_context()

    def get_component(self, component_id):
        return self.components.get(component_id)

    def fire_event(self, event_type, fl_ctx):
        return None

    def add_handler(self, handler):
        return None


@contextmanager
def temp_cwd(path):
    old = os.getcwd()
    os.chdir(path)
    try:
        yield
    finally:
        os.chdir(old)


@contextmanager
def stop_completion_after_one_pass(runner):
    original_sleep = job_runner_module.time.sleep

    def patched_sleep(_seconds):
        runner.ask_to_stop = True

    job_runner_module.time.sleep = patched_sleep
    try:
        yield
    finally:
        job_runner_module.time.sleep = original_sleep


def make_env(tmp_dir):
    with temp_cwd(tmp_dir):
        store = FilesystemStorage(root_dir=tmp_dir, uri_root="/")
        job_manager = SimpleJobDefManager(uri_root="jobs")

    server = object.__new__(FederatedServer)
    server.logger = SimpleNamespace(info=lambda *a, **k: None, warning=lambda *a, **k: None)

    engine = ServerEngine(
        server=server,
        args=SimpleNamespace(set=[], workspace=tmp_dir),
        client_manager=ClientManager(),
        snapshot_persistor=None,
    )
    runner = JobRunner(workspace_root=tmp_dir)
    runner._save_workspace = lambda *a, **k: None
    runner._fire_job_lifecycle_event = lambda *a, **k: None
    engine.set_job_runner(runner, job_manager)
    engine.run_manager = MiniRunManager(
        engine,
        {
            "job_store": store,
            SystemComponents.JOB_MANAGER: job_manager,
        },
    )
    server.engine = engine

    # Network/process edge: in the real late-heartbeat case this tries to abort
    # an SJ that the parent no longer tracks.  It is not the status decision.
    engine.abort_app_on_server = lambda job_id: ""
    return server, engine, runner, job_manager


def create_running_job(engine, runner, job_manager, job_id):
    with engine.new_context() as fl_ctx:
        meta = {
            JobMetaKey.JOB_ID.value: job_id,
            JobMetaKey.JOB_NAME.value: job_id,
            JobMetaKey.JOB_FOLDER_NAME.value: job_id,
            JobMetaKey.DEPLOY_MAP.value: {"app": ["server"]},
            JobMetaKey.RESOURCE_SPEC.value: {},
            JobMetaKey.MIN_CLIENTS.value: 1,
            JobMetaKey.MANDATORY_CLIENTS.value: [],
        }
        job_manager.create(meta, b"dummy", fl_ctx)
        job_manager.set_status(job_id, RunStatus.RUNNING, fl_ctx)
        job = job_manager.get_job(job_id, fl_ctx)
        runner.running_jobs[job_id] = job
        return job


def deliver_sj_heartbeat(server, job_id):
    request = new_cell_message({CellMessageHeaderKeys.JOB_ID: job_id}, {})
    request.set_header(MessageHeaderKey.TOPIC, ServerCommandNames.HEARTBEAT)
    return server._listen_command(request)


def complete_once(engine, runner):
    runner.ask_to_stop = False
    with stop_completion_after_one_pass(runner):
        runner._job_complete_process(engine)


def read_status(engine, job_manager, job_id):
    with engine.new_context() as fl_ctx:
        return job_manager.get_job(job_id, fl_ctx).meta[JobMetaKey.STATUS.value]


def run_case(case_name, deliver_heartbeat):
    tmp_dir = tempfile.mkdtemp(prefix=f"cr25-{case_name}-")
    try:
        server, engine, runner, job_manager = make_env(tmp_dir)
        job_id = f"{case_name}-job"
        job = create_running_job(engine, runner, job_manager, job_id)

        # Emulates ServerEngine.wait_for_complete after a normal SJ exit:
        # run_processes has been popped and exception_run_processes is empty.
        engine.run_processes = {}
        engine.exception_run_processes = {}

        if deliver_heartbeat:
            deliver_sj_heartbeat(server, job_id)

        run_aborted_after_heartbeat = job.run_aborted
        complete_once(engine, runner)
        final_status = read_status(engine, job_manager, job_id)
        return final_status, run_aborted_after_heartbeat
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def main():
    control_status, control_run_aborted = run_case("control", deliver_heartbeat=False)
    trigger_status, trigger_run_aborted = run_case("trigger", deliver_heartbeat=True)

    print(f"CONTROL final_status={control_status} run_aborted={control_run_aborted}")
    print(f"TRIGGER final_status={trigger_status} run_aborted_after_heartbeat={trigger_run_aborted}")
    print("EXPECTED normal completion should remain FINISHED:COMPLETED.")
    print("BUG_TRIGGERED=" + str(trigger_status == RunStatus.FINISHED_ABORTED.value and trigger_run_aborted))

    if control_status != RunStatus.FINISHED_COMPLETED.value:
        raise SystemExit(f"control did not complete normally: {control_status}")
    if trigger_status != RunStatus.FINISHED_ABORTED.value or not trigger_run_aborted:
        raise SystemExit("delayed heartbeat did not mark the normal completion aborted")


if __name__ == "__main__":
    main()
