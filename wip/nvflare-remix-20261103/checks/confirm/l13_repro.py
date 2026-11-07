"""L13 (timing inventory, round 7): a job whose SJ ended by system_panic is
reported FINISHED:COMPLETED when the SJ's one status message arrives late.
Pinned source c411a201, read-only via sys.path.

After a FATAL_SYSTEM_ERROR event (server_runner.py:253-256, e.g. a deployment
policy violation), start_run returns normally and the SJ exits with code 0
(mpm.run rc from main). The only carrier of the error is UPDATE_RUN_STATUS
{execution_error: True}, sent once with fire_and_forget in the finally of
ServerAppRunner.start_server_app (server_app_runner.py:80-93, server_engine.py:
874-885). On the parent, ServerEngine.wait_for_complete (server_engine.py:
204-235) waits at most 2 s after the process exit for PROCESS_FINISHED, then
reads the return code (0: no exception_run_processes entry) and pops the job
from run_processes. A status message handled after that finds no entry
(fed_server.py:595-605) and is dropped. JobRunner._get_finished_job_status ->
_classify_finished_job_status(None) returns FINISHED_COMPLETED
(job_runner.py:594-596, 625-636).

Real code: FederatedServer._listen_command (UPDATE_RUN_STATUS branch),
ServerEngine.wait_for_complete (+ fed_utils.get_return_code), JobRunner.
_get_finished_job_status / _classify_finished_job_status. Stubs: the SJ process
handle (exits with 0), the message delivery (the status message is handed to
the real handler after a delay), the engine's client list (no clients to abort).

Scenarios:
  C  control: the status message arrives 50 ms after it is sent (before the exit).
  L  late: it arrives 2.5 s after the SJ process exit (degraded parent link).
  X  lost: it never arrives (fire_and_forget has no retry).
"""
import sys, tempfile, threading, time, types
from unittest.mock import MagicMock

SRC = "/home/ubuntu/nvflare-integrated-model-20261103/sources/current"
sys.dont_write_bytecode = True
sys.path.insert(0, SRC)

from nvflare.apis.fl_constant import RunProcessKey, ServerCommandNames  # noqa: E402
from nvflare.apis.fl_context import FLContext  # noqa: E402
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey  # noqa: E402
from nvflare.fuel.f3.message import Message  # noqa: E402
from nvflare.private.defs import CellMessageHeaderKeys  # noqa: E402
from nvflare.private.fed.server.fed_server import FederatedServer  # noqa: E402
from nvflare.private.fed.server.job_runner import JobRunner  # noqa: E402
from nvflare.private.fed.server.server_engine import ServerEngine  # noqa: E402

WS = tempfile.mkdtemp(dir="/home/ubuntu/nvflare-remix-20261103/.tmp")


class Handle:
    def __init__(self):
        self.exited = threading.Event()

    def wait(self):
        self.exited.wait()

    def poll(self):
        return 0                                    # the SJ's main returned normally


def scenario(delay):
    eng = ServerEngine.__new__(ServerEngine)
    eng.lock, eng.logger = threading.Lock(), MagicMock()
    eng.run_processes, eng.exception_run_processes = {}, {}
    eng.engine_info = types.SimpleNamespace(status=None)
    eng.client_manager = types.SimpleNamespace(clients={})
    srv = FederatedServer.__new__(FederatedServer)
    srv.lock, srv.engine, srv.logger = threading.Lock(), eng, MagicMock()
    h = Handle()
    eng.run_processes["job1"] = {RunProcessKey.JOB_HANDLE: h, RunProcessKey.JOB_ID: "job1",
                                 RunProcessKey.PARTICIPANTS: {}}
    waiter = threading.Thread(target=eng.wait_for_complete, args=[WS, "job1", h], daemon=True)
    waiter.start()

    msg = Message(headers={CellMessageHeaderKeys.JOB_ID: "job1",
                           MessageHeaderKey.TOPIC: ServerCommandNames.UPDATE_RUN_STATUS},
                  payload={"execution_error": True})
    # SJ: system_panic happened; finally -> update_job_run_status (fire_and_forget), then shutdown, exit 0
    t_send = time.time()
    if delay is not None and delay[0] == "send":
        threading.Timer(delay[1], srv._listen_command, args=[msg]).start()
    time.sleep(0.3)                                 # SJ shutdown (command agent, archive, cell stop)
    h.exited.set()                                  # process exit, rc 0
    if delay is not None and delay[0] == "exit":
        threading.Timer(delay[1], srv._listen_command, args=[msg]).start()
    waiter.join(timeout=10)
    time.sleep(1.0 if delay is None or delay[0] == "send" else delay[1] + 0.5)
    jr = JobRunner.__new__(JobRunner)
    jr.logger = MagicMock()
    jr.abort_client_run = lambda *a, **k: None
    jr.log_info = lambda *a, **k: None
    status = jr._get_finished_job_status(eng, types.SimpleNamespace(job_id="job1"), FLContext())
    return status, "job1" in eng.exception_run_processes


if __name__ == "__main__":
    c = scenario(("send", 0.05))
    late = scenario(("exit", 2.5))
    lost = scenario(None)
    print("C control (status msg 50 ms after send):", c)
    print("L late (status msg 2.5 s after SJ exit):  ", late)
    print("X lost (status msg never arrives):        ", lost)
    ok = "EXECUTION_EXCEPTION" in str(c[0]) and "COMPLETED" in str(late[0]) and "COMPLETED" in str(lost[0])
    print("L13 REPRODUCED: a system-panicked job is classified FINISHED:COMPLETED when its status message"
          " is late or lost" if ok else "not reproduced")
