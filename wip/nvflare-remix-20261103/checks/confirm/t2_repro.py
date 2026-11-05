"""T2 (thread audit, round 6): the server's client_cleanup thread dies when a
client it has listed as dead re-registers before its turn in the logout loop.
Pinned source c411a201, read-only via sys.path.

FederatedServer.remove_dead_clients (fed_server.py:309-321) collects the
tokens whose heartbeat is older than heart_beat_timeout, then logs each out:
logout_client -> client_manager.remove_client(token) returns None for a token
that is already gone (client_manager.py:193-209), and notify_dead_client(None)
dereferences client.name (fed_server.py:1114); the log line in
remove_dead_clients does the same. A re-registration of the same client name
pops its old token (client_manager.py:330-337). client_cleanup (fed_server.py:
290-304) has no handler, so the thread ends and dead clients are never
removed again. Processing one dead client can take seconds: for a job still
waiting for its outcome, notify_dead_client -> _resolve_missing_client_outcome
-> job_runner.fail_run aborts the clients and the SJ (2 s and 1 s timeouts).

Scenario: a network outage; site-1 and site-2 both miss heartbeats, then both
reconnect. Real code: ClientManager.authenticate (non-secure mode),
FederatedServer.client_cleanup / remove_dead_clients / logout_client /
notify_dead_client / _resolve_missing_client_outcome. Stubs: the engine and
the job runner (its fail_run takes 2 s, standing for the abort round trips),
the admin server. Not forced: site-2 simply re-registers while the cleanup
thread is busy with site-1.
"""
import sys, threading, time, types
from unittest.mock import MagicMock

SRC = "/home/ubuntu/nvflare-integrated-model-20261103/sources/current"
sys.dont_write_bytecode = True
sys.path.insert(0, SRC)

from nvflare.apis.fl_context import FLContext  # noqa: E402
from nvflare.apis.shareable import Shareable  # noqa: E402
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey  # noqa: E402
from nvflare.fuel.f3.message import Message  # noqa: E402
from nvflare.private.defs import CellMessageHeaderKeys, ClientType  # noqa: E402
from nvflare.private.fed.server.client_manager import ClientManager  # noqa: E402
from nvflare.private.fed.server.fed_server import FederatedServer  # noqa: E402

cm = ClientManager(project_name="p", min_num_clients=1, max_num_clients=10)


def register(name):
    """The real registration entry (ClientManager.authenticate, non-secure mode)."""
    req = Message(headers={CellMessageHeaderKeys.CLIENT_NAME: name, MessageHeaderKey.ORIGIN: name,
                           CellMessageHeaderKeys.PROJECT_NAME: "p", CellMessageHeaderKeys.CLIENT_TYPE: ClientType.REGULAR,
                           CellMessageHeaderKeys.CLIENT_IP: "10.0.0.1"},
                  payload=Shareable())
    return cm.authenticate(req, FLContext())


class SlowJobRunner:
    """Each site still owes job1 its outcome; fail_run aborts clients and SJ (seconds)."""
    def __init__(self):
        self.pending = {"job1": {"site-1", "site-2"}}

    def get_client_outcome_jobs(self, name):
        return {j for j, s in self.pending.items() if name in s}

    def is_client_outcome_pending(self, job_id, name):
        return name in self.pending.get(job_id, set())

    def fail_run(self, job_id, rc, fl_ctx):
        time.sleep(2.0)

    def resolve_client_outcome(self, job_id, name):
        self.pending.get(job_id, set()).discard(name)


server = FederatedServer.__new__(FederatedServer)
server.client_manager, server.heart_beat_timeout, server.shutdown = cm, 60, False
server.admin_server, server.tokens = MagicMock(), {}
server.logger = MagicMock()
server.engine = types.SimpleNamespace(job_runner=SlowJobRunner(), run_processes={}, exception_run_processes={},
                                      new_context=lambda: FLContext())

c1, c2 = register("site-1"), register("site-2")
for c in (c1, c2):
    c.last_connect_time = time.time() - 120          # network outage: both missed heartbeats

crashes = []
threading.excepthook = lambda a: crashes.append((a.thread.name, a.exc_type.__name__, str(a.exc_value)))
cleanup = threading.Thread(target=server.client_cleanup, name="client_cleanup", daemon=True)
cleanup.start()
time.sleep(0.5)                                     # cleanup is now logging out the first dead client
# the client still waiting for its turn in the logout loop reconnects
waiting = [c.name for c in cm.clients.values()]
late = register(waiting[0])
time.sleep(4.0)
print("re-registered:", late.name, "new token in table:", late.token in cm.clients)
print("cleanup thread alive:", cleanup.is_alive(), "| exceptions:", crashes)
# a client that dies now is never removed
late.last_connect_time = time.time() - 120
time.sleep(6.0)
print("dead client still registered 6 s later:", late.token in cm.clients)
server.shutdown = True
ok = (not cleanup.is_alive()) and any(c[1] == "AttributeError" for c in crashes) and late.token in cm.clients
print("T2 REPRODUCED: client_cleanup died; dead clients are no longer removed" if ok else "not reproduced")
