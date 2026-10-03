# E1-E4: exit code chain for the default local-process launcher, using only product code:
#   child main -> MainProcessMonitor.run -> exit status / rc file
#   -> spawn_process + ProcessHandle.poll (launcher normalisation)
#   -> fed_utils.get_return_code
#   -> JobExecutor._wait_child_process_finish (client remap + report)   [CJ path]
#   -> FederatedServer.process_job_failure -> JobRunner.fail_run/stop_run -> _classify_finished_job_status
#   -> ServerEngine.wait_for_complete-style recording -> _classify_finished_job_status   [SJ path]
import logging
import os
import shutil
import sys
import tempfile
import threading
from types import SimpleNamespace
from unittest.mock import MagicMock

from nvflare.apis.fl_constant import FLMetaKey, RunProcessKey
from nvflare.app_common.job_launcher.process_launcher import ProcessHandle
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey, ReturnCode
from nvflare.private.defs import CellMessageHeaderKeys, JobFailureMsgKey, new_cell_message
from nvflare.private.fed.client.client_executor import _ABORT_REQUESTED_KEY, JobExecutor
from nvflare.private.fed.client.client_status import ClientStatus
from nvflare.private.fed.server.fed_server import FederatedServer
from nvflare.private.fed.server.job_runner import JobRunner
from nvflare.private.fed.utils.fed_utils import get_return_code
from nvflare.utils.process_utils import spawn_process

HERE = os.path.dirname(os.path.abspath(__file__))
CHILD = os.path.join(HERE, "child_mpm.py")
log = logging.getLogger("e1")
logging.basicConfig(level=logging.WARNING)


def run_child(ws, job_id, mode, linger):
    run_dir = os.path.join(ws, job_id)
    os.makedirs(run_dir, exist_ok=True)
    adapter = spawn_process([sys.executable, CHILD, mode, "1" if linger else "0", run_dir], os.environ.copy())
    handle = ProcessHandle(process_adapter=adapter)
    handle.wait()
    raw = adapter.poll()
    rc_file = os.path.join(run_dir, FLMetaKey.PROCESS_RC_FILE)
    rc_content = open(rc_file).read() if os.path.exists(rc_file) else None
    return handle, raw, rc_content


def sj_classify(return_code):
    # replicate ServerEngine.wait_for_complete recording (server_engine.py:218-233), no UPDATE_RUN_STATUS
    exception_run_processes = {}
    run_process_info = {RunProcessKey.JOB_ID: "j"}
    if return_code and return_code != 0:
        run_process_info[RunProcessKey.PROCESS_RETURN_CODE] = return_code
        exception_run_processes["j"] = run_process_info
    return JobRunner._classify_finished_job_status(exception_run_processes.get("j"))


class _Engine:
    def __init__(self):
        self.lock = threading.Lock()
        self.run_processes = {}
        self.exception_run_processes = {}
        self.client_manager = SimpleNamespace(clients={})
        self.server = SimpleNamespace(admin_server=MagicMock())

    def new_context(self):
        from nvflare.apis.fl_constant import ReservedKey
        from nvflare.apis.fl_context import FLContext

        ctx = FLContext()
        ctx.put(key=ReservedKey.ENGINE, value=self, private=True, sticky=False)
        return ctx


def server_side_status(reported_code):
    """Feed a CJ-reported code through the real FederatedServer.process_job_failure and JobRunner."""
    engine = _Engine()
    jr = JobRunner(workspace_root="/tmp")
    job = SimpleNamespace(job_id="job-x", run_aborted=False)
    jr.running_jobs["job-x"] = job
    jr._pending_client_outcomes["job-x"] = {"site-1"}
    engine.job_runner = jr
    srv = FederatedServer.__new__(FederatedServer)
    srv.logger = log
    srv.engine = engine
    srv.client_manager = MagicMock()
    srv.client_manager.is_from_authorized_client.return_value = True
    srv.client_manager.clients = {"tok": SimpleNamespace(name="site-1")}
    req = new_cell_message(
        {CellMessageHeaderKeys.TOKEN: "tok", MessageHeaderKey.ORIGIN: "site-1"},
        {JobFailureMsgKey.JOB_ID: "job-x", JobFailureMsgKey.CODE: reported_code, JobFailureMsgKey.REASON: "r"},
    )
    srv.process_job_failure(req)
    # _job_complete_process decision (job_runner.py:449-492) once the SJ is gone
    exception_process = engine.exception_run_processes.get("job-x")
    if job.run_aborted:
        return "FINISHED_ABORTED(run_aborted)"
    return JobRunner._classify_finished_job_status(exception_process).value


def cj_report(ws, job_id, mode, linger, status):
    handle, raw, rc_content = run_child(ws, job_id, mode, linger)
    client = MagicMock()
    client.client_name = "site-1"
    client.send_request_before_shutdown.return_value.get_header.return_value = ReturnCode.OK
    je = JobExecutor(client=client, startup="startup")
    je.run_processes = {job_id: {RunProcessKey.JOB_HANDLE: handle, RunProcessKey.STATUS: status, _ABORT_REQUESTED_KEY: False}}
    rm = MagicMock()
    je._wait_child_process_finish(client, job_id, {"gpu": [0]}, "tok", rm, ws, MagicMock())
    payload = client.send_request_before_shutdown.call_args.kwargs["request"].payload
    return raw, rc_content, payload[JobFailureMsgKey.CODE]


def main():
    ws = tempfile.mkdtemp(prefix="e1ws-", dir=HERE)
    try:
        print("=== E1/E2: exit status, rc file, launcher normalisation, get_return_code (SJ view) ===")
        print(f"{'mode':8} {'linger':6} {'raw_exit':8} {'rc_file':8} {'poll()':6} {'get_rc':6}  SJ terminal status")
        for mode in ("ok", "exc", "config", "unsafe", "sysexit", "sigkill"):
            for linger in (False, True):
                if mode == "sigkill" and linger:
                    continue
                job_id = f"sj-{mode}-{int(linger)}"
                handle, raw, rc_content = run_child(ws, job_id, mode, linger)
                polled = handle.poll()
                rc = get_return_code(handle, job_id, ws, log)
                print(f"{mode:8} {str(linger):6} {raw!s:8} {rc_content!s:8} {polled!s:6} {rc!s:6}  {sj_classify(rc).value}")

        print()
        print("=== E3/E4: CJ path: remap in _wait_child_process_finish -> reported code -> server status ===")
        print(f"{'mode':8} {'linger':6} {'CP status':9} {'raw':5} {'rc_file':7} {'reported':8}  server terminal status")
        for mode in ("ok", "exc", "config", "unsafe"):
            for linger in (False, True):
                for status in (ClientStatus.STARTING, ClientStatus.STARTED, ClientStatus.STOPPED):
                    job_id = f"cj-{mode}-{int(linger)}-{status}"
                    raw, rc_content, reported = cj_report(ws, job_id, mode, linger, status)
                    print(
                        f"{mode:8} {str(linger):6} {status:<9} {raw!s:5} {rc_content!s:7} {reported!s:8}  "
                        f"{server_side_status(reported)}"
                    )
    finally:
        shutil.rmtree(ws, ignore_errors=True)


if __name__ == "__main__":
    main()
