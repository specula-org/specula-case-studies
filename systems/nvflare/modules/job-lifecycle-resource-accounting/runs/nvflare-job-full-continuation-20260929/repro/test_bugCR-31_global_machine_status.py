#!/usr/bin/env python3
"""CR-31 reproduction: global MachineStatus races with real lifecycle state.

Run from the pinned NVFlare worktree:
  timeout 2m python3 ../../repro/test_bugCR-31_global_machine_status.py
"""

import inspect
import logging
import os
import sys
import tempfile
import threading
import time
import types
from unittest.mock import MagicMock


SOURCE = (
    "/home/ubuntu/specula-nvflare-gpt-continuation-20260926/framework/runs/"
    "gpt-continuation/nvflare-job/.specula-output/confirmation/CR-31/worktree"
)
if SOURCE not in sys.path:
    sys.path.insert(0, SOURCE)

from nvflare.apis.fl_constant import MachineStatus, RunProcessKey  # noqa: E402
from nvflare.apis.fl_context import FLContext  # noqa: E402
from nvflare.private.fed.server.fed_server import FederatedServer  # noqa: E402
import nvflare.private.fed.server.fed_server as fed_server_mod  # noqa: E402
from nvflare.private.fed.server.server_engine import ServerEngine  # noqa: E402
from nvflare.private.fed.server.server_engine_internal_spec import EngineInfo  # noqa: E402
from nvflare.private.fed.server.training_cmds import TrainingCommandModule  # noqa: E402


assert os.path.realpath(__import__("nvflare").__file__).startswith(SOURCE), __import__("nvflare").__file__


class FakeProcess:
    def wait(self):
        return None

    def poll(self):
        return 0


class Table:
    def __init__(self):
        self.rows = []

    def add_row(self, row, meta=None):
        self.rows.append((row, meta))


class CaptureConn:
    def __init__(self, engine):
        self.app_ctx = engine
        self.strings = []
        self.tables = []
        self.errors = []

    def append_string(self, text, meta=None):
        self.strings.append((text, meta))

    def append_table(self, cols, name=None):
        table = Table()
        self.tables.append((name, cols, table))
        return table

    def append_error(self, text, meta=None):
        self.errors.append((text, meta))


def parent_waiter_snapshot_case():
    """Reachable parent-side mismatch: one finished job writes STOPPED while another remains registered."""
    with tempfile.TemporaryDirectory(prefix="cr31-parent-") as root:
        os.makedirs(os.path.join(root, "startup"), exist_ok=True)
        os.makedirs(os.path.join(root, "local"), exist_ok=True)
        for job_id, app_name in (("job-a", "app-a"), ("job-b", "app-b")):
            run_dir = os.path.join(root, job_id)
            os.makedirs(run_dir, exist_ok=True)
            with open(os.path.join(run_dir, "fl_app.txt"), "w", encoding="utf-8") as f:
                f.write(app_name + "\n")

        engine = ServerEngine.__new__(ServerEngine)
        engine.args = types.SimpleNamespace(workspace=root)
        engine.engine_info = EngineInfo()
        engine.lock = threading.Lock()
        engine.logger = logging.getLogger("cr31.parent")
        engine.exception_run_processes = {}
        engine.run_processes = {
            "job-a": {RunProcessKey.PROCESS_FINISHED: True},
            "job-b": {RunProcessKey.PROCESS_FINISHED: False},
        }
        engine.client_manager = MagicMock()
        engine.client_manager.get_clients.return_value = {}

        engine.wait_for_complete(root, "job-a", FakeProcess())
        raw_after_wait = engine.engine_info.status.value
        remaining = sorted(engine.run_processes)
        direct_reader = engine.abort_app_on_clients(["site-1"])

        conn = CaptureConn(engine)
        TrainingCommandModule().check_status(conn, ["check_status", "server"])
        admin_status_line = conn.strings[0][0]
        derived_after_admin = engine.engine_info.status.value

        print("PARENT_WAIT_SNAPSHOT")
        print(f"  raw_after_wait_for_complete={raw_after_wait}")
        print(f"  remaining_run_processes={remaining}")
        print(f"  direct_stale_reader_abort_app_on_clients={direct_reader!r}")
        print(f"  admin_check_status_line={admin_status_line!r}")
        print(f"  derived_after_admin_check_status={derived_after_admin}")


class TracedEngineInfo:
    def __init__(self):
        self._status = MachineStatus.STOPPED
        self.history = []
        self.start_time = time.time()
        self.app_names = {}

    @property
    def status(self):
        return self._status

    @status.setter
    def status(self, value):
        frame = inspect.currentframe().f_back
        self.history.append(f"{os.path.basename(frame.f_code.co_filename)}:{frame.f_lineno}:{value.value}")
        self._status = value


class FakeEngine:
    def __init__(self):
        self.engine_info = TracedEngineInfo()
        self.asked_to_stop = False
        self.run_manager = None

    def set_run_manager(self, run_manager):
        self.run_manager = run_manager

    def set_configurator(self, conf):
        self.conf = conf

    def restore_components(self, snapshot, fl_ctx):
        raise AssertionError("snapshot path not used")

    def new_context(self):
        return FLContext()


class FakeRunManager:
    def __init__(self):
        self.handlers = []
        self.components = {}
        self.cell = None

    def add_handler(self, handler):
        self.handlers.append(handler)

    def add_component(self, component_id, component):
        self.components[component_id] = component

    def new_context(self):
        return FLContext()


class FakeServerRunner:
    run_delay = 0.05

    def __init__(self, config=None, job_id=None, engine=None):
        self.config = config
        self.job_id = job_id
        self.engine = engine

    def run(self):
        time.sleep(self.run_delay)


class DelayAfterStartThread:
    """Timing assistance: let the target thread run before start() returns."""

    def __init__(self, target=None, args=(), kwargs=None, daemon=None, name=None):
        self.thread = threading.Thread(target=target, args=args, kwargs=kwargs or {}, daemon=daemon, name=name)

    def start(self):
        self.thread.start()
        time.sleep(0.05)

    def join(self, timeout=None):
        return self.thread.join(timeout)

    def is_alive(self):
        return self.thread.is_alive()


def make_fed_server():
    srv = FederatedServer.__new__(FederatedServer)
    srv.engine = FakeEngine()
    srv.runner_config = types.SimpleNamespace(components={}, handlers=[])
    srv.cell = None
    srv.check_engine_frequency = 0.05
    srv.secure_train = False
    srv.logger = logging.getLogger("cr31.fed")
    srv.create_run_manager = lambda workspace, job_id: FakeRunManager()
    return srv


def run_start_run_case(label, forced):
    with tempfile.TemporaryDirectory(prefix="cr31-fed-") as workspace:
        os.makedirs(os.path.join(workspace, "startup"), exist_ok=True)
        os.makedirs(os.path.join(workspace, "local"), exist_ok=True)
        run_root = os.path.join(workspace, "job-cr31", "app_server")
        os.makedirs(run_root, exist_ok=True)

        srv = make_fed_server()
        args = types.SimpleNamespace(workspace=workspace, config_folder="config")
        done = threading.Event()
        result = {}

        original_runner = fed_server_mod.ServerRunner
        original_threading = fed_server_mod.threading
        try:
            fed_server_mod.ServerRunner = FakeServerRunner
            if forced:
                FakeServerRunner.run_delay = 0.0
                fed_server_mod.threading = types.SimpleNamespace(Thread=DelayAfterStartThread)
            else:
                FakeServerRunner.run_delay = 0.05

            def target():
                try:
                    srv.start_run("job-cr31", run_root, MagicMock(), args, None)
                    result["returned"] = True
                except BaseException as e:
                    result["error"] = f"{type(e).__name__}: {e}"
                finally:
                    done.set()

            t = threading.Thread(target=target, daemon=True)
            t.start()
            returned_before_release = done.wait(timeout=0.75)
            status_before_release = srv.engine.engine_info.status.value
            history_before_release = list(srv.engine.engine_info.history)
            if not returned_before_release:
                srv.engine.asked_to_stop = True
                done.wait(timeout=2.0)
            t.join(timeout=2.0)
        finally:
            fed_server_mod.ServerRunner = original_runner
            fed_server_mod.threading = original_threading

        print(label)
        print(f"  returned_before_release={returned_before_release}")
        print(f"  status_before_release={status_before_release}")
        print(f"  history_before_release={history_before_release}")
        print(f"  final_result={result}")
        print(f"  final_history={srv.engine.engine_info.history}")
        return returned_before_release, status_before_release, history_before_release


def main():
    logging.basicConfig(level=logging.CRITICAL)
    print(f"SOURCE={SOURCE}")
    parent_waiter_snapshot_case()
    control = run_start_run_case("START_RUN_CONTROL", forced=False)
    forced = run_start_run_case("START_RUN_FORCED_TIMING", forced=True)

    triggered = (
        control[0] is True
        and forced[0] is False
        and forced[1] == MachineStatus.STARTED.value
        and any(":1209:stopped" in item for item in forced[2])
        and any(":1148:started" in item for item in forced[2])
    )
    print(f"BUG_TRIGGERED={triggered}")
    if triggered:
        print(
            "BAD_OUTCOME=start_run loop at fed_server.py:1149 kept running after "
            "run_engine wrote STOPPED at fed_server.py:1209; fed_server.py:1148 "
            "overwrote it with STARTED."
        )
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
