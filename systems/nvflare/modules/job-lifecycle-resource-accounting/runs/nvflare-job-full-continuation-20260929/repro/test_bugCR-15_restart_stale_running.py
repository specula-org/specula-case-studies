#!/usr/bin/env python3
"""CR-15 reproduction: aborted running job remains RUNNING after local parent restart."""

from __future__ import annotations

import contextlib
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace
from threading import Lock


WORKTREE = Path(
    "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/gpt-continuation/"
    "nvflare-job/.specula-output/confirmation/CR-15/worktree"
)

sys.path.insert(0, str(WORKTREE))

from nvflare.apis.client import Client  # noqa: E402
from nvflare.apis.fl_constant import FLContextKey, RunProcessKey, SystemComponents  # noqa: E402
from nvflare.apis.fl_context import FLContext, FLContextManager  # noqa: E402
from nvflare.apis.impl.job_def_manager import SimpleJobDefManager  # noqa: E402
from nvflare.apis.job_def import JobMetaKey, RunStatus  # noqa: E402
from nvflare.apis.server_engine_spec import ServerEngineSpec  # noqa: E402
from nvflare.apis.storage import StorageSpec  # noqa: E402
from nvflare.app_common.storages.filesystem_storage import FilesystemStorage  # noqa: E402
from nvflare.private.fed.server.job_runner import JobRunner  # noqa: E402
from nvflare.tool.job.job_cli import _is_terminal_job_status  # noqa: E402


class _NoopContext:
    def __enter__(self):
        return FLContext()

    def __exit__(self, exc_type, exc, tb):
        return False


class _FakeSai:
    def new_context(self):
        return _NoopContext()


class _FakeAdminServer:
    timeout = 0.1
    sai = _FakeSai()

    def send_requests(self, requests, fl_ctx, timeout_secs, optional=False):
        return []


class _FakeServer:
    admin_server = _FakeAdminServer()


class _FakeClientManager:
    clients = {}


class FakeEngine(ServerEngineSpec):
    def __init__(self, workspace: Path, store: StorageSpec, job_manager: SimpleJobDefManager):
        self.workspace = workspace
        self.components = {
            "job_store": store,
            SystemComponents.JOB_MANAGER: job_manager,
        }
        self.server = _FakeServer()
        self.client_manager = _FakeClientManager()
        self.run_processes = {}
        self.exception_run_processes = {}
        self.lock = Lock()
        self.job_runner: JobRunner | None = None
        self.abort_calls = []
        self.ctx_mgr = FLContextManager(engine=self, identity_name="server")

    def validate_targets(self, target_names: list[str]) -> tuple[list[Client], list[str]]:
        return [], []

    def new_context(self) -> FLContext:
        return self.ctx_mgr.new_context()

    def get_workspace(self):
        return SimpleNamespace(root_dir=str(self.workspace))

    def add_component(self, component_id: str, component):
        self.components[component_id] = component

    def get_component(self, component_id: str) -> object:
        return self.components.get(component_id)

    def abort_app_on_server(self, job_id: str, turn_to_cold: bool = False) -> str:
        self.abort_calls.append(job_id)
        self.run_processes.pop(job_id, None)
        return ""

    def fire_event(self, event_type: str, fl_ctx: FLContext):
        pass

    def get_clients(self) -> list[Client]:
        return []

    def sync_clients_from_main_process(self):
        pass

    def update_job_run_status(self):
        pass

    def register_aux_message_handler(self, topic: str, message_handle_func):
        pass

    def send_aux_request(self, targets, topic, request, timeout, fl_ctx, optional=False, secure=False) -> dict:
        return {}

    def multicast_aux_requests(self, topic, target_requests, timeout, fl_ctx, optional=False, secure=False) -> dict:
        return {}

    def get_widget(self, widget_id: str):
        return None

    def persist_components(self, fl_ctx: FLContext, completed: bool):
        pass

    def restore_components(self, snapshot, fl_ctx: FLContext):
        pass

    def start_client_job(self, job, client_sites, fl_ctx: FLContext):
        return []

    def check_client_resources(self, job, resource_reqs, fl_ctx: FLContext):
        return {}

    def cancel_client_resources(self, resource_check_results, fl_ctx: FLContext):
        pass

    def get_client_name_from_token(self, token: str) -> str:
        return ""


def _make_store(tmp: Path):
    store = FilesystemStorage(str(tmp / "store"), uri_root="/")
    manager = SimpleJobDefManager(uri_root="jobs")
    return store, manager


def _create_running_job(engine: FakeEngine, manager: SimpleJobDefManager, label: str):
    ctx = engine.new_context()
    meta = manager.create(
        {
            JobMetaKey.JOB_NAME.value: label,
            JobMetaKey.DEPLOY_MAP.value: {"server_app": ["server"]},
            JobMetaKey.RESOURCE_SPEC.value: {},
            JobMetaKey.MIN_CLIENTS.value: 0,
        },
        b"job payload",
        ctx,
    )
    job_id = meta[JobMetaKey.JOB_ID.value]
    manager.set_status(job_id, RunStatus.DISPATCHED, ctx)
    manager.set_status(job_id, RunStatus.RUNNING, ctx)
    return job_id, manager.get_job(job_id, ctx)


def _status(manager: SimpleJobDefManager, engine: FakeEngine, job_id: str) -> str:
    job = manager.get_job(job_id, engine.new_context())
    return job.meta[JobMetaKey.STATUS.value]


def _count_external_callers() -> int:
    cmd = [
        "rg",
        "-n",
        "update_unfinished_jobs|update_abnormal_finished_jobs|restore_running_job|pause_server_jobs",
        str(WORKTREE / "nvflare"),
        str(WORKTREE / "tests"),
        str(WORKTREE / "docs"),
        "-g",
        "*.py",
        "-g",
        "*.rst",
        "-g",
        "*.md",
    ]
    out = subprocess.run(cmd, text=True, capture_output=True, check=False)
    if out.returncode not in (0, 1):
        raise RuntimeError(out.stderr or out.stdout)
    caller_lines = []
    for line in out.stdout.splitlines():
        code = line.split(":", 2)[-1].strip()
        if code.startswith("def update_unfinished_jobs"):
            continue
        if code.startswith("def update_abnormal_finished_jobs"):
            continue
        if code.startswith("def restore_running_job"):
            continue
        if code.startswith("def pause_server_jobs"):
            continue
        caller_lines.append(line)
    return len(caller_lines)


def main() -> int:
    commit = subprocess.check_output(["git", "-C", str(WORKTREE), "rev-parse", "HEAD"], text=True).strip()
    with tempfile.TemporaryDirectory(prefix="cr15-repro-") as td:
        tmp = Path(td)
        store, manager = _make_store(tmp)

        old_engine = FakeEngine(tmp / "workspace", store, manager)
        old_runner = JobRunner(str(tmp / "workspace"))
        old_engine.job_runner = old_runner
        old_runner.scheduler = SimpleNamespace(remove_scheduled_job=lambda job_id: None)

        job_id, job = _create_running_job(old_engine, manager, "cr15-running")
        old_runner.running_jobs[job_id] = job
        old_engine.run_processes[job_id] = {RunProcessKey.PARTICIPANTS: {}}

        abort_msg = old_runner.stop_run(job_id, old_engine.new_context())
        run_aborted = old_runner.running_jobs[job_id].run_aborted
        old_runner.stop_all_runs(old_engine.new_context())
        status_after_shutdown = _status(manager, old_engine, job_id)

        new_engine = FakeEngine(tmp / "workspace", store, manager)
        new_runner = JobRunner(str(tmp / "workspace"))
        new_runner.scheduler = SimpleNamespace(remove_scheduled_job=lambda job_id: None)
        new_engine.job_runner = new_runner

        status_after_fresh_parent = _status(manager, new_engine, job_id)
        restart_abort_msg = new_runner.mark_run_aborted(job_id, new_engine.new_context())
        terminal_seen_by_cli_wait = _is_terminal_job_status(status_after_fresh_parent)
        delete_guard_would_reject = status_after_fresh_parent in {
            RunStatus.DISPATCHED.value,
            RunStatus.RUNNING.value,
        }
        running_jobs_by_status = manager.get_jobs_by_status(
            [RunStatus.RUNNING, RunStatus.DISPATCHED], new_engine.new_context()
        )

        # Positive control: the shipped helper would reconcile the state if ordinary startup called it.
        control_store, control_manager = _make_store(tmp / "control")
        control_engine = FakeEngine(tmp / "control-workspace", control_store, control_manager)
        control_runner = JobRunner(str(tmp / "control-workspace"))
        control_engine.job_runner = control_runner
        control_job_id, _ = _create_running_job(control_engine, control_manager, "cr15-control")
        control_before = _status(control_manager, control_engine, control_job_id)
        control_runner.update_unfinished_jobs(control_engine.new_context())
        control_after = _status(control_manager, control_engine, control_job_id)

        print(f"source_commit={commit}")
        print(f"level=2_state_injection_with_reachable_precondition")
        print(
            "reachable_sequence="
            "submit job -> scheduler writes DISPATCHED/RUNNING -> admin abort_job on RUNNING job "
            "calls JobRunner.stop_run -> shutdown server is allowed because job.run_aborted=True "
            "-> FederatedServer.fl_shutdown calls engine.stop_all_jobs/JobRunner.stop_all_runs "
            "-> parent restarts with empty run_processes/running_jobs and same persisted store"
        )
        print(f"external_reconciliation_callers={_count_external_callers()}")
        print(f"job_id={job_id}")
        print(f"abort_msg_before_shutdown={abort_msg!r}")
        print(f"run_aborted_before_shutdown={run_aborted}")
        print(f"status_after_shutdown={status_after_shutdown}")
        print(f"fresh_parent_run_processes={list(new_engine.run_processes)}")
        print(f"fresh_parent_running_jobs={list(new_runner.running_jobs)}")
        print(f"status_after_fresh_parent_start={status_after_fresh_parent}")
        print(f"abort_after_restart_msg={restart_abort_msg!r}")
        print(f"delete_guard_would_reject_running={delete_guard_would_reject}")
        print(f"cli_wait_sees_terminal={terminal_seen_by_cli_wait}")
        print(f"jobs_by_running_or_dispatched_after_restart={[j.job_id for j in running_jobs_by_status]}")
        print(f"manual_helper_control_before={control_before}")
        print(f"manual_helper_control_after={control_after}")

        failed = []
        if abort_msg != "":
            failed.append("initial supported abort did not succeed")
        if not run_aborted:
            failed.append("abort did not set Job.run_aborted")
        if status_after_shutdown != RunStatus.RUNNING.value:
            failed.append("shutdown unexpectedly published a terminal status")
        if status_after_fresh_parent != RunStatus.RUNNING.value:
            failed.append("fresh parent reconciled stale RUNNING status")
        if "is not running" not in restart_abort_msg:
            failed.append("fresh parent abort did not observe empty process tables")
        if not delete_guard_would_reject:
            failed.append("delete guard would not reject stale RUNNING")
        if terminal_seen_by_cli_wait:
            failed.append("CLI wait would treat stale RUNNING as terminal")
        if [j.job_id for j in running_jobs_by_status] != [job_id]:
            failed.append("job manager did not expose stale RUNNING/DISPATCHED job")
        if control_after != RunStatus.ABANDONED.value:
            failed.append("manual update_unfinished_jobs control did not abandon stale job")

        if failed:
            print("RESULT=FAIL")
            for item in failed:
                print(f"failure={item}")
            return 1

        print("RESULT=BUG_REPRODUCED")
        return 0


if __name__ == "__main__":
    with contextlib.suppress(KeyboardInterrupt):
        raise SystemExit(main())
    raise SystemExit(130)
