"""S1: SP shutdown/restart with running jobs. JobRunner.stop_all_runs iterates
engine.run_processes.keys() without a snapshot (job_runner.py:944-951) while each
stopped job's SJ exit removes its entry (wait_for_complete, server_engine.py:204-237;
_remove_run_processes, 394-410). If a later job's stop is slow (an unresponsive but
still registered client makes abort_client_run wait its 2 s timeout, job_runner.py:446-462),
the next iteration raises RuntimeError. fl_shutdown (fed_server.py:1251-1255) then
skips the remaining jobs, SYSTEM_END and the base shutdown; server_shutdown runs in the
engine executor (server_engine.py:417-426, 1129-1140), so the exception is never seen.
Pinned source c411a201, read-only via sys.path.

Real code: FederatedServer.fl_shutdown, server_shutdown, ServerEngine.stop_all_jobs,
abort_app_on_server, _remove_run_processes, wait_for_complete, JobRunner.stop_all_runs,
stop_run, _stop_run, mark_run_aborted, abort_client_run, _send_to_clients,
_get_active_job_participants. Stubs: SJ process handles (exit 0.3 s after ABORT and set
PROCESS_FINISHED first, as the real SJ's UPDATE_RUN_STATUS does, fed_server.py:603),
the admin server's send_requests (an unresponsive client waits the timeout),
validate_targets, BaseServer.fl_shutdown, security_close, fire_event, logging.
"""
import concurrent.futures
import logging
import os
import sys
import threading
import time
import types

SRC = "/home/ubuntu/nvflare-integrated-model-20261103/sources/current"
sys.dont_write_bytecode = True
sys.path.insert(0, SRC)

from nvflare.apis.client import Client  # noqa: E402
from nvflare.apis.event_type import EventType  # noqa: E402
from nvflare.apis.fl_constant import RunProcessKey  # noqa: E402
from nvflare.private.fed.server import fed_server as fs_mod  # noqa: E402
from nvflare.private.fed.server import server_engine as se_mod  # noqa: E402
from nvflare.private.fed.server.job_runner import JobRunner  # noqa: E402

logging.disable(logging.CRITICAL)
TMP = "/home/ubuntu/nvflare-remix-20261103/.tmp/s1"
os.makedirs(TMP, exist_ok=True)
SJ_ABORT_EXIT = float(os.environ.get("S1_SJ_EXIT", "0.3"))


class SJHandle:
    def __init__(self, engine, job_id):
        self.engine, self.job_id, self.exited = engine, job_id, threading.Event()

    def abort(self):
        def run():
            time.sleep(SJ_ABORT_EXIT)
            info = self.engine.run_processes.get(self.job_id)
            if info is not None:
                info[RunProcessKey.PROCESS_FINISHED] = True
            self.exited.set()
        threading.Thread(target=run, daemon=True).start()

    def wait(self):
        self.exited.wait()

    def poll(self):
        return 0 if self.exited.is_set() else None

    def terminate(self):
        self.exited.set()


class Ctx:
    def __init__(self, engine):
        self.engine = engine

    def get_engine(self, default=None):
        return self.engine

    def set_prop(self, *a, **k):
        pass

    def get_prop(self, *a, **k):
        return None

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def scenario(n_jobs, slow_client):
    jr = JobRunner(workspace_root=TMP)
    jr.log_info = jr.log_debug = jr.log_error = jr.log_warning = lambda *a, **k: None
    eng = se_mod.ServerEngine.__new__(se_mod.ServerEngine)
    eng.lock = threading.Lock()
    eng.run_processes, eng.exception_run_processes = {}, {}
    eng.logger = logging.getLogger("se")
    eng.engine_info = types.SimpleNamespace(status=None)
    eng.job_runner = jr
    clients = {"t1": Client("site-1", "t1"), "t2": Client("site-2", "t2")}
    eng.client_manager = types.SimpleNamespace(clients=dict(clients))
    sent = {"clients": [], "sj_abort": [], "events": []}

    def send_requests(requests, fl_ctx, timeout_secs=None, optional=False):
        sent["clients"].append(sorted(requests))
        time.sleep(timeout_secs if (slow_client and "t2" in requests) else 0.01)
        return {}
    admin = types.SimpleNamespace(timeout=10.0, send_requests=send_requests,
                                  sai=types.SimpleNamespace(new_context=lambda: Ctx(eng)))
    eng.server = types.SimpleNamespace(admin_server=admin)
    eng.validate_targets = lambda names: ([c for c in clients.values() if c.name in names], [])
    eng.new_context = lambda: Ctx(eng)
    eng.fire_event = lambda event_type, fl_ctx: sent["events"].append(event_type)
    handles = {}

    def send_cmd(job_id, command_name, command_data, timeout=None, optional=False):
        sent["sj_abort"].append(job_id)
        handles[job_id].abort()
        return "ok"
    eng.send_command_to_child_runner_process = send_cmd
    for i in range(1, n_jobs + 1):
        j = f"job{i}"
        handles[j] = SJHandle(eng, j)
        eng.run_processes[j] = {RunProcessKey.JOB_HANDLE: handles[j], RunProcessKey.JOB_ID: j,
                                RunProcessKey.PARTICIPANTS: dict(clients)}
        jr.running_jobs[j] = types.SimpleNamespace(job_id=j, run_aborted=False)
        threading.Thread(target=eng.wait_for_complete, args=[TMP, j, handles[j]], daemon=True).start()

    server = fs_mod.FederatedServer.__new__(fs_mod.FederatedServer)
    server.engine, server.logger, server.status = eng, logging.getLogger("fs"), None
    base_called = []
    orig_base, orig_close = fs_mod.BaseServer.fl_shutdown, se_mod.security_close
    fs_mod.BaseServer.fl_shutdown = lambda self: base_called.append(True)
    se_mod.security_close = lambda: None
    try:
        # as ServerEngine.shutdown_server / restart_server do: run server_shutdown in the executor
        with concurrent.futures.ThreadPoolExecutor(1) as ex:
            fut = ex.submit(lambda p: se_mod.server_shutdown(*p), [server, os.path.join(TMP, "restart.fl")])
            err = fut.exception(timeout=60)
    finally:
        fs_mod.BaseServer.fl_shutdown, se_mod.security_close = orig_base, orig_close
    time.sleep(SJ_ABORT_EXIT + 0.5)
    aborted = [j for j, job in jr.running_jobs.items() if job.run_aborted]
    alive_sj = [j for j, h in handles.items() if not h.exited.is_set()]
    return dict(error=repr(err) if err else None, sj_abort_sent=sent["sj_abort"], marked_aborted=aborted,
                sj_still_running=alive_sj, system_end=EventType.SYSTEM_END in sent["events"],
                base_shutdown=bool(base_called), ask_to_stop=jr.ask_to_stop, status=server.status)


if __name__ == "__main__":
    ctl = scenario(3, slow_client=False)
    s1 = scenario(3, slow_client=True)
    print("control (all clients reply):        ", ctl)
    print("S1 (site-2 registered, not replying):", s1)
    ok = (ctl["error"] is None and ctl["system_end"] and ctl["ask_to_stop"]
          and s1["error"] and "RuntimeError" in s1["error"] and s1["sj_still_running"]
          and not s1["system_end"] and not s1["ask_to_stop"])
    print("S1 REPRODUCED: shutdown aborted mid-way, a running job was never stopped, SYSTEM_END not fired, "
          "and the error stayed inside the executor future" if ok else "not reproduced")
