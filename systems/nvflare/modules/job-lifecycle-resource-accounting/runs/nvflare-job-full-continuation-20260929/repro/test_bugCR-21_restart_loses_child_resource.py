#!/usr/bin/env python3
"""CR-21 reproduction: CP restart loses in-memory child resource ownership.

The state injection below models a real sequence:

1. A client job process has reported STOPPED to the client parent, but the
   parent still owns its process handle until _wait_child_process_finish()
   returns and calls resource_manager.free_resources().
2. The server restart/shutdown command path can legitimately have no
   job_runner.running_jobs at that point, so it sends TrainingTopic.RESTART.
3. The client parent restarts, losing the in-memory resource manager and
   run_processes map while the previous child process is still alive.

The observable consequence is on the next CHECK_RESOURCE request: the new
resource manager instance accepts the same single resource while the previous
child is still alive.
"""

import os
import signal
import subprocess
import sys
import tempfile
from pathlib import Path

SOURCE_ROOT = Path(
    "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/"
    "gpt-continuation/nvflare-job/.specula-output/confirmation/CR-21/worktree"
)
sys.path.insert(0, str(SOURCE_ROOT))

from nvflare.apis.fl_constant import SystemComponents  # noqa: E402
from nvflare.apis.fl_context import FLContext  # noqa: E402
from nvflare.apis.resource_manager_spec import ResourceManagerSpec  # noqa: E402
from nvflare.app_common.resource_managers.list_resource_manager import ListResourceManager  # noqa: E402
from nvflare.private.admin_defs import Message  # noqa: E402
from nvflare.private.defs import RequestHeader, TrainingTopic  # noqa: E402
from nvflare.private.fed.client.client_engine_internal_spec import ClientEngineInternalSpec  # noqa: E402
from nvflare.private.fed.client.client_status import ClientStatus  # noqa: E402
from nvflare.private.fed.client.scheduler_cmds import CheckResourceProcessor  # noqa: E402
from nvflare.private.fed.client.training_cmds import RestartClientProcessor  # noqa: E402
from nvflare.private.scheduler_constants import ShareableHeader  # noqa: E402


class FakeClientEngine(ClientEngineInternalSpec):
    def __init__(self, resource_manager: ResourceManagerSpec, live_jobs=None):
        self.resource_manager = resource_manager
        self.live_jobs = live_jobs or {}
        self.restart_calls = 0
        self.fired_events = []
        self.started_jobs = []

    def fire_event(self, event_type: str, fl_ctx: FLContext):
        self.fired_events.append(event_type)

    def new_context(self) -> FLContext:
        return FLContext()

    def add_component(self, component_id: str, component):
        if component_id == SystemComponents.RESOURCE_MANAGER:
            self.resource_manager = component

    def get_component(self, component_id: str) -> object:
        if component_id == SystemComponents.RESOURCE_MANAGER:
            return self.resource_manager
        return None

    def get_engine_status(self):
        return "running"

    def get_client_name(self) -> str:
        return "site-1"

    def deploy_app(self, app_name: str, job_id: str, job_meta: dict, client_name: str, app_data) -> str:
        return ""

    def start_app(self, job_id: str, job_meta: dict, allocated_resource=None, token=None, resource_manager=None) -> str:
        self.started_jobs.append((job_id, allocated_resource, token))
        return "Start the client app..."

    def notify_job_status(self, job_id: str, job_status):
        self.live_jobs[job_id] = job_status

    def abort_app(self, job_id: str) -> str:
        return "Abort signal has been sent to the client App."

    def abort_task(self, job_id: str) -> str:
        return "Abort signal has been sent to the current task."

    def delete_run(self, job_id: str) -> str:
        return f"Delete run folder: {job_id}."

    def shutdown(self) -> str:
        return "Shutdown the client..."

    def restart(self) -> str:
        self.restart_calls += 1
        return "Restart the client..."

    def get_all_job_ids(self) -> list:
        return list(self.live_jobs)


def reserve_and_allocate(manager: ListResourceManager, job_id: str, requirement: dict):
    fl_ctx = FLContext()
    enough, token = manager.check_resources(requirement, fl_ctx)
    assert enough, f"initial allocation for {job_id} should fit"
    allocated = manager.allocate_resources(requirement, token, fl_ctx)
    return token, allocated


def run_check_resource(engine: FakeClientEngine, job_id: str, requirement: dict):
    req = Message(topic=TrainingTopic.CHECK_RESOURCE, body=requirement)
    req.set_header(RequestHeader.JOB_ID, job_id)
    reply = CheckResourceProcessor().process(req, engine)
    body = reply.body
    return (
        body.get_header(ShareableHeader.IS_RESOURCE_ENOUGH),
        body.get_header(ShareableHeader.RESOURCE_RESERVE_TOKEN),
    )


def main() -> int:
    requirement = {"gpu": 1}

    with tempfile.TemporaryDirectory(prefix="cr21-") as tmp:
        child = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(60)"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        try:
            old_rm = ListResourceManager({"gpu": ["gpu0"]}, expiration_period=30)
            old_token, old_alloc = reserve_and_allocate(old_rm, "job-1", requirement)

            # Level 1 timing: a STOPPED-but-owned child is still visible to the
            # client parent, and the client restart processor still accepts the
            # restart message that the server sends after its running_jobs gate
            # has cleared.
            stopped_live = {"job-1": ClientStatus.STOPPED}
            old_engine = FakeClientEngine(resource_manager=old_rm, live_jobs=stopped_live)
            restart_reply = RestartClientProcessor().process(Message(topic=TrainingTopic.RESTART, body=""), old_engine)

            # Level 2 state injection: this is the state after the client parent
            # has restarted. The prior child is alive and still using gpu0, but
            # the new parent constructed a fresh in-memory resource manager from
            # the same static site configuration.
            new_rm = ListResourceManager({"gpu": ["gpu0"]}, expiration_period=30)
            new_engine = FakeClientEngine(resource_manager=new_rm)
            enough, new_token = run_check_resource(new_engine, "job-2", requirement)

            print("CR-21 reproduction")
            print(f"workdir={tmp}")
            print("level0_admin_guard=not_executed_full_cluster; source audit shows server restart/shutdown block only while running_jobs is non-empty")
            print(f"level1_restart_reply={restart_reply.body!r}")
            print(f"level1_restart_calls={old_engine.restart_calls}")
            print(f"old_child_pid={child.pid}")
            print(f"old_child_alive={child.poll() is None}")
            print(f"old_allocation_token={old_token}")
            print(f"old_allocation={old_alloc}")
            print(f"old_rm_report_after_allocation={old_rm.report_resources(FLContext())}")
            print(f"new_check_resource_enough={enough}")
            print(f"new_check_resource_token_nonempty={bool(new_token)}")
            print(f"new_rm_report_after_check={new_rm.report_resources(FLContext())}")

            if child.poll() is None and enough and new_token:
                print("BUG_TRIGGERED: CheckResourceProcessor accepted gpu0 for job-2 while job-1 child is still alive with gpu0")
                return 0

            print("BUG_NOT_TRIGGERED")
            return 1
        finally:
            if child.poll() is None:
                try:
                    os.killpg(os.getpgid(child.pid), signal.SIGKILL)
                except ProcessLookupError:
                    pass
                child.wait(timeout=5)


if __name__ == "__main__":
    raise SystemExit(main())
