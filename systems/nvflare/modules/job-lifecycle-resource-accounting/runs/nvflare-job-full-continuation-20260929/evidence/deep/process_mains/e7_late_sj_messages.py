# E7: SP-side ordering dependencies on SJ fire-and-forget messages (delayed-delivery fault).
#   F3: UPDATE_RUN_STATUS(execution_error=True) handled after ServerEngine.wait_for_complete popped the
#       run_processes entry -> the error is dropped -> job classified FINISHED_COMPLETED.
#   F4: a delayed SJ HEARTBEAT handled after the pop, while the job still waits for client outcomes
#       (store status RUNNING, job in running_jobs) -> _set_job_aborted -> run_aborted -> FINISHED_ABORTED.
# Real product functions: ServerEngine.wait_for_complete, FederatedServer._listen_command,
# FederatedServer._set_job_aborted, JobRunner.mark_run_aborted, JobRunner._classify_finished_job_status.
# Fakes: process handle, job manager, abort_app_on_server (no cell), engine container.
import logging
import threading
from types import SimpleNamespace
from unittest.mock import MagicMock

from nvflare.apis.fl_constant import ReservedKey, RunProcessKey, ServerCommandNames, SystemComponents
from nvflare.apis.fl_context import FLContext
from nvflare.apis.job_def import JobMetaKey, RunStatus
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey
from nvflare.private.defs import CellMessageHeaderKeys, new_cell_message
from nvflare.private.fed.server.fed_server import FederatedServer
from nvflare.private.fed.server.job_runner import JobRunner
from nvflare.private.fed.server.server_engine import ServerEngine
from nvflare.private.fed.server.server_engine_internal_spec import EngineInfo

logging.basicConfig(level=logging.WARNING)
JOB = "job-e7"
import os
WS = os.path.dirname(os.path.abspath(__file__))


class FakeHandle:
    def wait(self):
        return None

    def poll(self):
        return 0  # SJ exited 0 (workflow exceptions do not change the SJ exit code)


def make_engine(tmpdir):
    eng = ServerEngine.__new__(ServerEngine)
    eng.run_processes = {JOB: {RunProcessKey.JOB_HANDLE: FakeHandle(), RunProcessKey.JOB_ID: JOB, RunProcessKey.PARTICIPANTS: {}}}
    eng.exception_run_processes = {}
    eng.lock = threading.Lock()
    eng.logger = logging.getLogger("eng")
    eng.engine_info = EngineInfo()
    eng.run_manager = None
    jr = JobRunner(workspace_root=tmpdir)
    job = SimpleNamespace(job_id=JOB, run_aborted=False, meta={JobMetaKey.STATUS: RunStatus.RUNNING})
    jr.running_jobs[JOB] = job
    jr._pending_client_outcomes[JOB] = {"site-1"}  # SJ done; still waiting for client outcome
    eng.job_runner = jr
    job_manager = MagicMock()
    job_manager.get_job.return_value = job
    eng.get_component = lambda cid: job_manager if cid == SystemComponents.JOB_MANAGER else None
    eng.abort_app_on_server = MagicMock(return_value="")

    def new_context():
        ctx = FLContext()
        ctx.put(key=ReservedKey.ENGINE, value=eng, private=True, sticky=False)
        return ctx

    eng.new_context = new_context
    return eng, job


def make_server(eng):
    srv = FederatedServer.__new__(FederatedServer)
    srv.engine = eng
    srv.lock = threading.Lock()
    srv.logger = logging.getLogger("srv")
    return srv


def msg(topic, data):
    return new_cell_message({CellMessageHeaderKeys.JOB_ID: JOB, MessageHeaderKey.TOPIC: topic}, data)


def final_status(eng, job):
    # decision made by JobRunner._job_complete_process (job_runner.py:449-492)
    if job.run_aborted:
        return RunStatus.FINISHED_ABORTED.value
    return JobRunner._classify_finished_job_status(eng.exception_run_processes.get(JOB)).value


def case_update_run_status(order):
    eng, job = make_engine("/tmp")
    srv = make_server(eng)
    update = msg(ServerCommandNames.UPDATE_RUN_STATUS, {"execution_error": True})
    if order == "timely":
        srv._listen_command(update)
        eng.wait_for_complete(WS, JOB, FakeHandle())
    else:
        eng.wait_for_complete(WS, JOB, FakeHandle())  # waits 2 s for PROCESS_FINISHED, then pops
        srv._listen_command(update)
    return final_status(eng, job)


def case_heartbeat(order):
    eng, job = make_engine("/tmp")
    srv = make_server(eng)
    srv._listen_command(msg(ServerCommandNames.UPDATE_RUN_STATUS, {"execution_error": False}))
    hb = msg(ServerCommandNames.HEARTBEAT, {})
    if order == "timely":
        srv._listen_command(hb)
        eng.wait_for_complete(WS, JOB, FakeHandle())
    else:
        eng.wait_for_complete(WS, JOB, FakeHandle())
        srv._listen_command(hb)
    return final_status(eng, job), eng.abort_app_on_server.called


if __name__ == "__main__":
    print("F3 UPDATE_RUN_STATUS(execution_error=True) timely  ->", case_update_run_status("timely"))
    print("F3 UPDATE_RUN_STATUS(execution_error=True) late    ->", case_update_run_status("late"))
    s, a = case_heartbeat("timely")
    print(f"F4 SJ heartbeat before pop (normal job)          -> {s}  abort_app_on_server called={a}")
    s, a = case_heartbeat("late")
    print(f"F4 SJ heartbeat after pop  (normal job)          -> {s}  abort_app_on_server called={a}")
