"""T3 (audit, round 7): the server's client_cleanup thread dies when another
job's SJ exits while a dead client is being processed (same consequence as T2,
different trigger). Pinned source c411a201, read-only via sys.path.

FederatedServer.notify_dead_client (fed_server.py:1118) iterates
engine.run_processes without engine.lock. For each job the dead client takes
part in, the loop body calls engine.notify_dead_job -> send_command_to_child_
runner_process (server_engine.py:887-911), which takes engine.lock, fires the
HANDLE_DEAD_JOB command and logs. ServerEngine.wait_for_complete (server_engine.
py:204-235) pops a finished job from run_processes under the same lock. If that
pop lands while the loop body runs (the body waits for the lock, or logs after
releasing it), the next step of the iteration raises "RuntimeError: dictionary
changed size during iteration". Nothing catches it on the way up (logout_client
-> remove_dead_clients -> client_cleanup, fed_server.py:290-329), so the thread
ends and dead clients are never removed again. remove_dead_clients itself also
iterates client_manager.clients (the live dict, client_manager.py:431-437)
without the client manager's lock.

Real code: ClientManager.authenticate, FederatedServer.client_cleanup /
remove_dead_clients / logout_client / notify_dead_client / _notify_dead_job,
ServerEngine.notify_dead_job / send_command_to_child_runner_process /
wait_for_complete (and fed_utils.get_return_code). Stubs: the cell
(fire_and_forget records the command), the job runner (no pending outcome), the
admin server, and the SJ process handle of job B.

Scenarios:
  C  control: the dead client is processed while no other job exits.
  F  forced timing: job B's SJ exits and its handle's poll() inside the locked
     section of wait_for_complete takes 50 ms while the cleanup thread reaches
     job A's notification (the lock wait makes the pop land inside the loop).
  N  natural: job B's exit time is uniform in a 20 ms window around the
     notification, poll() is instantaneous; many trials, hit rate reported.
"""
import random, sys, threading, time, types, tempfile, logging
from unittest.mock import MagicMock

SRC = "/home/ubuntu/nvflare-integrated-model-20261103/sources/current"
sys.dont_write_bytecode = True
sys.path.insert(0, SRC)

from nvflare.apis.fl_constant import RunProcessKey  # noqa: E402
from nvflare.apis.fl_context import FLContext  # noqa: E402
from nvflare.apis.shareable import Shareable  # noqa: E402
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey  # noqa: E402
from nvflare.fuel.f3.message import Message  # noqa: E402
from nvflare.private.defs import CellMessageHeaderKeys, ClientType  # noqa: E402
from nvflare.private.fed.server.client_manager import ClientManager  # noqa: E402
from nvflare.private.fed.server.fed_server import FederatedServer  # noqa: E402
from nvflare.private.fed.server.server_engine import ServerEngine  # noqa: E402

WS = tempfile.mkdtemp(dir="/home/ubuntu/nvflare-remix-20261103/.tmp")
log = logging.getLogger("t3"); log.addHandler(logging.FileHandler(f"{WS}/server.log")); log.setLevel(logging.INFO)


class Handle:
    """SJ process handle of job B: wait() returns when the SJ exits."""
    def __init__(self, poll_delay):
        self.exited, self.poll_delay = threading.Event(), poll_delay

    def wait(self):
        self.exited.wait()

    def poll(self):
        time.sleep(self.poll_delay)
        return 0


def trial(mode, poll_delay=0.0, jitter=0.0):
    cm = ClientManager(project_name="p", min_num_clients=1, max_num_clients=10)

    def register(name):
        req = Message(headers={CellMessageHeaderKeys.CLIENT_NAME: name, MessageHeaderKey.ORIGIN: name,
                               CellMessageHeaderKeys.PROJECT_NAME: "p",
                               CellMessageHeaderKeys.CLIENT_TYPE: ClientType.REGULAR,
                               CellMessageHeaderKeys.CLIENT_IP: "10.0.0.1"}, payload=Shareable())
        return cm.authenticate(req, FLContext())

    c1, c2 = register("site-1"), register("site-2")
    fired = []
    eng = ServerEngine.__new__(ServerEngine)
    eng.lock, eng.logger, eng.exception_run_processes = threading.Lock(), log, {}
    eng.engine_info = types.SimpleNamespace(status=None)
    eng.server = types.SimpleNamespace(cell=types.SimpleNamespace(
        fire_and_forget=lambda **kw: fired.append(kw["targets"])))
    eng.job_runner = types.SimpleNamespace(get_client_outcome_jobs=lambda name: set(),
                                           is_client_outcome_pending=lambda j, n: False)
    eng.new_context = lambda: FLContext()
    hb = Handle(poll_delay)
    eng.run_processes = {
        "jobA": {RunProcessKey.JOB_ID: "jobA", RunProcessKey.PARTICIPANTS: {c1.token: c1, c2.token: c2}},
        "jobB": {RunProcessKey.JOB_ID: "jobB", RunProcessKey.PARTICIPANTS: {c2.token: c2},
                 RunProcessKey.PROCESS_FINISHED: True},
    }
    srv = FederatedServer.__new__(FederatedServer)
    srv.client_manager, srv.heart_beat_timeout, srv.shutdown = cm, 60, False
    srv.admin_server, srv.tokens, srv.logger, srv.engine = MagicMock(), {}, log, eng
    srv.remove_client_data = lambda token: None
    crashes = []
    threading.excepthook = lambda a: crashes.append((a.thread.name, a.exc_type.__name__, str(a.exc_value)))
    exit_thread = threading.Thread(target=eng.wait_for_complete, args=[WS, "jobB", hb], name="sj_exit_B", daemon=True)
    exit_thread.start()
    c1.last_connect_time = time.time() - 120          # site-1 stopped heartbeating
    cleanup = threading.Thread(target=srv.client_cleanup, name="client_cleanup", daemon=True)
    if mode == "F":
        hb.exited.set()                               # job B's SJ has exited; wait_for_complete takes the lock
        time.sleep(0.005)
        cleanup.start()
    elif mode == "N":
        t0 = time.time() + 0.01
        cleanup.start()
        time.sleep(max(0.0, t0 + random.uniform(-jitter, jitter) - time.time()))
        hb.exited.set()
    else:
        cleanup.start()
    time.sleep(0.3)
    alive = cleanup.is_alive()
    # does a client that dies later still get removed?
    c2.last_connect_time = time.time() - 120
    time.sleep(5.5 if mode != "N" else 0.0)
    removed_later = c2.token not in cm.clients
    srv.shutdown = True
    hb.exited.set()
    return alive, crashes, removed_later, "jobB" in eng.run_processes


if __name__ == "__main__":
    a, cr, rem, _ = trial("C")
    print("C control:  cleanup alive:", a, "| exceptions:", cr, "| later dead client removed:", rem)
    a2, cr2, rem2, _ = trial("F", poll_delay=0.05)
    print("F forced:   cleanup alive:", a2, "| exceptions:", cr2, "| later dead client removed:", rem2)
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 300
    hits = 0
    for i in range(n):
        al, crn, _, _ = trial("N", jitter=0.01)
        hits += any(c[1] == "RuntimeError" for c in crn)
    print(f"N natural:  RuntimeError in {hits}/{n} trials (job B exits uniformly within +-10 ms of the notification)")
    ok = a and not cr and rem and (not a2) and any(c[1] == "RuntimeError" for c in cr2) and not rem2
    print("T3 REPRODUCED: client_cleanup died (dictionary changed size during iteration); dead clients no longer removed"
          if ok else "not reproduced")
