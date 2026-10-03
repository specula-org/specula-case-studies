#!/usr/bin/env python3
"""Reproduce MC-2: deleting a listed job kills the only JobRunner scheduling loop.

Level 0 uses the normal admin delete without timing assistance. Level 1 widens the
real list-then-get_meta race by pausing immediately before the filesystem-backed
get_meta call for the listed job, then running the normal delete_job command.
"""

from __future__ import annotations

import os
import sys
import tempfile
import threading
import time
import traceback
from types import SimpleNamespace


SOURCE = (
    "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/"
    "gpt-continuation/nvflare-job/.specula-output/confirmation/MC-2/worktree"
)
sys.path.insert(0, SOURCE)

import nvflare  # noqa: E402

assert os.path.realpath(nvflare.__file__).startswith(SOURCE), nvflare.__file__

from nvflare.apis.client import Client  # noqa: E402
from nvflare.apis.fl_constant import SystemComponents  # noqa: E402
from nvflare.apis.fl_context import FLContextManager  # noqa: E402
from nvflare.apis.impl.job_def_manager import SimpleJobDefManager  # noqa: E402
from nvflare.apis.job_def import JobMetaKey, RunStatus  # noqa: E402
from nvflare.apis.server_engine_spec import ServerEngineSpec  # noqa: E402
from nvflare.app_common.storages.filesystem_storage import FilesystemStorage  # noqa: E402
from nvflare.private.fed.server.job_cmds import JobCommandModule  # noqa: E402
from nvflare.private.fed.server.job_runner import JobRunner  # noqa: E402
from nvflare.private.fed.server.server_state import HotState  # noqa: E402


class GateableFilesystemStorage(FilesystemStorage):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.pause_uri = None
        self.pause_once = False
        self.pause_reached = threading.Event()
        self.resume = threading.Event()

    def arm_before_get_meta(self, uri: str):
        self.pause_uri = uri
        self.pause_once = True
        self.pause_reached.clear()
        self.resume.clear()

    def get_meta(self, uri: str) -> dict:
        if self.pause_once and uri == self.pause_uri:
            self.pause_once = False
            self.pause_reached.set()
            if not self.resume.wait(timeout=10.0):
                raise TimeoutError("timing gate was not released")
        return super().get_meta(uri)


class RecordingScheduler:
    def __init__(self):
        self.calls = []
        self.lock = threading.Lock()

    def schedule_job(self, job_manager, job_candidates, fl_ctx):
        with self.lock:
            self.calls.append([j.job_id for j in job_candidates])
        return None, None

    @property
    def call_count(self) -> int:
        with self.lock:
            return len(self.calls)


class FakeConn:
    def __init__(self, engine):
        self.app_ctx = engine
        self.props = {}
        self.out = []

    def get_prop(self, key, default=None):
        return self.props.get(key, default)

    def set_prop(self, key, value):
        self.props[key] = value

    def append_string(self, text, meta=None):
        self.out.append(("string", text))

    def append_success(self, text, meta=None):
        self.out.append(("success", text))

    def append_error(self, text, meta=None):
        self.out.append(("error", text))


class FakeEngine:
    def __init__(self, root_dir: str):
        self.server = SimpleNamespace(server_state=HotState())
        self.storage = GateableFilesystemStorage(root_dir="/", uri_root="/")
        self.job_def_manager = SimpleJobDefManager(uri_root=os.path.join(root_dir, "jobs"))
        self.scheduler = RecordingScheduler()
        self.components = {
            "job_store": self.storage,
            SystemComponents.JOB_MANAGER: self.job_def_manager,
            SystemComponents.JOB_SCHEDULER: self.scheduler,
        }
        self.clients = [Client("site-1", "token-site-1")]
        self.fl_ctx_mgr = FLContextManager(
            engine=self,
            identity_name="server",
            job_id="",
            public_stickers={},
            private_stickers={},
        )
        self.run_processes = {}
        self.exception_run_processes = {}
        self.lock = threading.Lock()

    def get_component(self, component_id: str):
        return self.components.get(component_id)

    def get_clients(self):
        return list(self.clients)

    def new_context(self):
        return self.fl_ctx_mgr.new_context()

    def remove_exception_process(self, job_id):
        self.exception_run_processes.pop(job_id, None)

    def fire_event(self, event_type, fl_ctx):
        return None


ServerEngineSpec.register(FakeEngine)


def submit_job(engine: FakeEngine, name: str) -> str:
    meta = {
        JobMetaKey.JOB_NAME.value: name,
        JobMetaKey.DEPLOY_MAP.value: {"app": ["server", "site-1"]},
        JobMetaKey.RESOURCE_SPEC.value: {},
        JobMetaKey.MIN_CLIENTS.value: 1,
        JobMetaKey.SCHEDULE_COUNT.value: 0,
        JobMetaKey.LAST_SCHEDULE_TIME.value: 0,
        JobMetaKey.SCHEDULE_HISTORY.value: [],
    }
    with engine.new_context() as fl_ctx:
        created = engine.job_def_manager.create(meta, b"dummy job bytes", fl_ctx)
    return created[JobMetaKey.JOB_ID.value]


def get_status(engine: FakeEngine, job_id: str):
    with engine.new_context() as fl_ctx:
        job = engine.job_def_manager.get_job(job_id, fl_ctx)
    return None if job is None else job.meta.get(JobMetaKey.STATUS.value)


def admin_delete_job(engine: FakeEngine, job_id: str):
    with engine.new_context() as fl_ctx:
        job = engine.job_def_manager.get_job(job_id, fl_ctx)
    conn = FakeConn(engine)
    conn.set_prop(JobCommandModule.JOB_ID, job_id)
    conn.set_prop(JobCommandModule.JOB, job)
    JobCommandModule().delete_job(conn, ["delete_job", job_id])
    return conn.out


def run_runner(engine: FakeEngine, runner: JobRunner):
    result = {"exception": None, "traceback": None}

    def target():
        try:
            runner.run(engine.new_context())
        except BaseException as e:
            result["exception"] = f"{type(e).__name__}: {e}"
            result["traceback"] = traceback.format_exc()

    t = threading.Thread(target=target, name="JobRunner.run", daemon=True)
    t.start()
    return t, result


def wait_for(predicate, timeout=5.0, step=0.05):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(step)
    return predicate()


def level0_control():
    with tempfile.TemporaryDirectory(prefix="mc2-level0-") as root:
        engine = FakeEngine(root)
        runner = JobRunner(workspace_root=os.path.join(root, "workspace"))
        runner.scheduler = engine.scheduler
        job_a = submit_job(engine, "level0-delete-before-scan")
        thread, result = run_runner(engine, runner)

        delete_reply = admin_delete_job(engine, job_a)
        time.sleep(1.4)
        job_b = submit_job(engine, "level0-later-job")
        base_calls = engine.scheduler.call_count
        wait_for(lambda: engine.scheduler.call_count > base_calls, timeout=3.0)

        alive = thread.is_alive()
        delta = engine.scheduler.call_count - base_calls
        status_b = get_status(engine, job_b)
        runner.ask_to_stop = True
        thread.join(timeout=3.0)
        return {
            "delete_reply": delete_reply,
            "runner_alive": alive,
            "runner_exception": result["exception"],
            "later_schedule_calls": delta,
            "later_status": status_b,
        }


def level1_trigger():
    with tempfile.TemporaryDirectory(prefix="mc2-level1-") as root:
        engine = FakeEngine(root)
        runner = JobRunner(workspace_root=os.path.join(root, "workspace"))
        runner.scheduler = engine.scheduler
        job_a = submit_job(engine, "level1-listed-then-deleted")
        engine.storage.arm_before_get_meta(engine.job_def_manager.job_uri(job_a))
        thread, result = run_runner(engine, runner)

        if not engine.storage.pause_reached.wait(timeout=5.0):
            runner.ask_to_stop = True
            raise AssertionError("runner did not reach the get_meta timing gate")

        delete_reply = admin_delete_job(engine, job_a)
        engine.storage.resume.set()
        if not wait_for(lambda: not thread.is_alive(), timeout=5.0):
            runner.ask_to_stop = True
            raise AssertionError("runner thread did not terminate after deleted listed job")

        job_b = submit_job(engine, "level1-later-eligible-job")
        calls_before = engine.scheduler.call_count
        time.sleep(2.4)
        calls_after = engine.scheduler.call_count
        status_b = get_status(engine, job_b)
        runner.ask_to_stop = True

        return {
            "delete_reply": delete_reply,
            "runner_alive": thread.is_alive(),
            "runner_exception": result["exception"],
            "scheduler_calls_after_later_job": calls_after - calls_before,
            "later_status": status_b,
            "traceback_first_line": (result["traceback"] or "").splitlines()[-1] if result["traceback"] else "",
        }


def main():
    print(f"nvflare_import={os.path.realpath(nvflare.__file__)}")

    l0 = level0_control()
    print(
        "LEVEL0 no timing: "
        f"runner_alive={l0['runner_alive']} "
        f"exception={l0['runner_exception']} "
        f"later_schedule_calls={l0['later_schedule_calls']} "
        f"later_status={l0['later_status']}"
    )
    print(f"LEVEL0 delete_reply={l0['delete_reply']}")

    l1 = level1_trigger()
    print(
        "LEVEL1 timing-assisted delete-after-list-before-get_meta: "
        f"runner_alive={l1['runner_alive']} "
        f"exception={l1['runner_exception']} "
        f"scheduler_calls_after_later_job={l1['scheduler_calls_after_later_job']} "
        f"later_status={l1['later_status']}"
    )
    print(f"LEVEL1 delete_reply={l1['delete_reply']}")
    print(f"LEVEL1 traceback_last_line={l1['traceback_first_line']}")

    assert l0["runner_alive"], "control runner should stay alive"
    assert l0["later_schedule_calls"] > 0, "control later job should be considered"
    assert l1["runner_alive"] is False, "bug: runner thread must terminate"
    assert l1["runner_exception"] and "StorageException" in l1["runner_exception"], l1
    assert l1["scheduler_calls_after_later_job"] == 0, "later job should not be considered after runner death"
    assert l1["later_status"] == RunStatus.SUBMITTED.value, "later job remains stuck SUBMITTED"
    print("RESULT: REPRODUCED MC-2")


if __name__ == "__main__":
    main()
