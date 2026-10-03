# E6: SJ main-loop lost update (fed_server.py:1145-1157 vs run_engine :1199-1209).
#
# FederatedServer.start_run (SJ main thread) does:
#     engine_thread = threading.Thread(target=self.run_engine); engine_thread.start()
#     self.engine.engine_info.status = MachineStatus.STARTED          # (A)
#     while self.engine.engine_info.status != MachineStatus.STOPPED: ...
# run_engine (engine thread) ends with:
#     self.engine.engine_info.status = MachineStatus.STOPPED          # (B)
# If (B) happens before (A), (A) overwrites STOPPED and the loop can only exit via asked_to_stop.
#
# Scheduling control (no product change): the scratch harness replaces the `threading` name seen by
# fed_server with a shim whose Thread.start() runs the target to completion synchronously, i.e. it forces
# the interleaving "engine thread finishes before the main thread executes (A)". The real product
# FederatedServer.start_run / run_engine code is executed unmodified. Control run uses real threads.
import sys
import threading
import time
import types
from types import SimpleNamespace
from unittest.mock import MagicMock

import nvflare.private.fed.server.fed_server as fs
from nvflare.apis.fl_constant import MachineStatus
from nvflare.apis.fl_context import FLContext
from nvflare.private.fed.server.server_engine_internal_spec import EngineInfo

RUN_SECONDS = 0.05  # how long the fake ServerRunner.run() takes


class FakeServerRunner:
    def __init__(self, config=None, job_id=None, engine=None):
        self.job_id = job_id

    def run(self):
        time.sleep(RUN_SECONDS)  # a very short run (e.g. empty/instantly failing workflow list)


class FakeEngine:
    def __init__(self):
        self.engine_info = EngineInfo()
        self.asked_to_stop = False

    def set_run_manager(self, rm):
        self.run_manager = rm

    def set_configurator(self, conf):
        pass

    def new_context(self):
        return FLContext()

    def restore_components(self, snapshot, fl_ctx):
        pass


class SyncThread:
    """Thread shim: start() runs the target synchronously to completion (forced interleaving)."""

    def __init__(self, target=None, args=(), kwargs=None, daemon=None, name=None):
        self._t, self._a, self._k = target, args, kwargs or {}

    def start(self):
        self._t(*self._a, **self._k)

    def join(self, timeout=None):
        pass


def make_server():
    srv = fs.FederatedServer.__new__(fs.FederatedServer)
    srv.engine = FakeEngine()
    srv.runner_config = MagicMock()
    srv.cell = None  # _send_parent_heartbeat becomes a no-op
    srv.check_engine_frequency = 0.05
    srv.secure_train = False
    srv.logger = MagicMock()
    srv.create_run_manager = lambda workspace, job_id: MagicMock()
    return srv


def run_case(label, threading_shim):
    fs.ServerRunner = FakeServerRunner
    orig_threading = fs.threading
    if threading_shim is not None:
        fs.threading = threading_shim
    srv = make_server()
    import os

    ws = os.path.join(os.path.dirname(os.path.abspath(__file__)), "poc_ws", "example_project", "prod_00", "server")
    args = SimpleNamespace(workspace=ws, config_folder="config")
    done = threading.Event()
    result = {}

    def main_thread():
        try:
            srv.start_run("job-e6", "/tmp/run", MagicMock(), args, None)
            result["returned"] = True
        except Exception as e:  # pragma: no cover
            result["error"] = repr(e)
        finally:
            done.set()

    t = threading.Thread(target=main_thread, daemon=True)
    t.start()
    returned = done.wait(timeout=3.0)
    status_while_waiting = srv.engine.engine_info.status
    # release the stuck loop the only way the product allows (what monitor_parent_process does on parent death)
    srv.engine.asked_to_stop = True
    done.wait(timeout=3.0)
    fs.threading = orig_threading
    print(
        f"{label:34} start_run returned within 3s: {returned!s:5}  engine_info.status after 3s: "
        f"{status_while_waiting}  (released only via asked_to_stop: {not returned})  result={result}"
    )
    return returned


if __name__ == "__main__":
    ok_real = run_case("control (real threading)", None)
    shim = types.SimpleNamespace(Thread=SyncThread)
    ok_forced = run_case("forced: engine finishes before (A)", shim)
    sys.exit(0 if (ok_real and not ok_forced) else 1)
