"""T2 under natural timing: how wide is the window in which a re-login of an
overdue client kills the server's client_cleanup thread?
Pinned source c411a201, read-only via sys.path.

Mechanism (t2_repro.py): FederatedServer.remove_dead_clients (fed_server.py:
309-321) lists every token whose last heartbeat is older than heart_beat_timeout,
then logs them out one by one. If a listed token disappears before its turn,
ClientManager.remove_client returns None (client_manager.py:193-209) and
notify_dead_client(None) / the log line dereference client.name (fed_server.py:
1114, 319). client_cleanup (290-304) has no handler, so the thread ends.

What can remove a listed token before its turn: a new login of the same client
name (ClientManager.authenticated_client pops the old token, client_manager.py:
330-337; the CP logs in only when its process starts, client_train.py:170, or in
secure mode when the server's identity check of its old token fails,
communicator.py:154-165), admin remove_client / disable_client
(server_engine.py:611-614, client_manager.py:117-140), or the client's own quit
(fed_server.py:886-899). A reconnect after a network outage does NOT pop the
token: the CP keeps heartbeating with its old token and ClientManager.heartbeat
refreshes it, or re-activates it under the same token (client_manager.py:
376-417).

So the window is the time between the listing and B's turn: the logout of every
dead client listed before B. t2_repro.py used a 2 s fail_run stub for that; on
the real path _resolve_missing_client_outcome calls fail_run only when the job's
SJ is already gone (fed_server.py:1095-1102), and then _stop_run finds no run
process and sends nothing (job_runner.py:425-444), so fail_run returns at once.

Everything on the path is real here: ClientManager.authenticate (both logins),
FederatedServer.remove_dead_clients / logout_client / remove_client_data /
notify_dead_client / _resolve_missing_client_outcome, JobRunner (pending outcome
of a finished job -> real fail_run), FedAdminServer.client_dead,
ServerEngine.notify_dead_job over a real SP root cell to real SJ cells in child
processes. remove_dead_clients is called by a thread at a chosen time instead of
by the 5 s client_cleanup loop (it is that loop's body).

No forcing: B's re-login time is uniform in [-X, +X] around the scan. The crash
fraction gives the window W = fraction * 2X.

usage: t2_natural.py [trials] [X_ms] [dead_ahead] [running_jobs]
  dead_ahead: overdue clients listed before B (1 = just A; larger = mass outage)
  running_jobs: running jobs each dead client takes part in (one SJ cell each)
"""
import logging, os, random, socket, subprocess, sys, tempfile, threading, time, types

SRC = "/home/ubuntu/nvflare-integrated-model-20261103/sources/current"
sys.dont_write_bytecode = True
sys.path.insert(0, SRC)

from nvflare.fuel.f3.cellnet.cell import Cell  # noqa: E402
from nvflare.private.defs import CellChannel  # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".tmp")


def sj_main(fqcn, url):
    cell = Cell(fqcn, "", secure=False, credentials={}, create_internal_listener=False, parent_url=url)
    cell.register_request_cb(channel=CellChannel.SERVER_COMMAND, topic="*", cb=lambda req: None)
    cell.start()
    while not cell.is_cell_connected("server"):
        time.sleep(0.05)
    print("READY", flush=True)
    sys.stdin.read()
    cell.stop()
    os._exit(0)


def main():
    from nvflare.apis.fl_constant import RunProcessKey
    from nvflare.apis.fl_context import FLContext, FLContextManager
    from nvflare.apis.shareable import Shareable
    from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey
    from nvflare.fuel.f3.message import Message
    from nvflare.private.defs import CellMessageHeaderKeys, ClientType
    from nvflare.private.fed.server.admin import FedAdminServer
    from nvflare.private.fed.server.client_manager import ClientManager
    from nvflare.private.fed.server.fed_server import FederatedServer
    from nvflare.private.fed.server.job_runner import JobRunner
    from nvflare.private.fed.server.server_engine import ServerEngine

    n = int(sys.argv[1]) if len(sys.argv) > 1 else 300
    x = float(sys.argv[2]) / 1000 if len(sys.argv) > 2 else 0.005
    ahead = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    n_jobs = int(sys.argv[4]) if len(sys.argv) > 4 else 1
    os.makedirs(ROOT, exist_ok=True)
    ws = tempfile.mkdtemp(prefix="t2n_", dir=ROOT)
    logging.basicConfig(filename=os.path.join(ws, "server.log"), level=logging.INFO)

    s = socket.socket(); s.bind(("localhost", 0)); port = s.getsockname()[1]; s.close()
    root = Cell("server", f"tcp://localhost:{port}", secure=False, credentials={}, create_internal_listener=True)
    root.start()
    url = root.get_internal_listener_url()
    sjs = []
    for j in range(n_jobs):
        p = subprocess.Popen([sys.executable, "-B", __file__, "--sj", f"server.job{j}", url],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        assert p.stdout.readline().strip() == "READY"
        sjs.append(p)

    cm = ClientManager(project_name="p", min_num_clients=1, max_num_clients=500)

    def login(name):
        req = Message(headers={CellMessageHeaderKeys.CLIENT_NAME: name, MessageHeaderKey.ORIGIN: name,
                               CellMessageHeaderKeys.PROJECT_NAME: "p",
                               CellMessageHeaderKeys.CLIENT_TYPE: ClientType.REGULAR,
                               CellMessageHeaderKeys.CLIENT_IP: "10.0.0.1"}, payload=Shareable())
        return cm.authenticate(req, FLContext())

    eng = ServerEngine.__new__(ServerEngine)
    eng.lock, eng.logger, eng.exception_run_processes = threading.Lock(), logging.getLogger("ServerEngine"), {}
    eng.run_processes = {}
    eng.engine_info = types.SimpleNamespace(status=None)
    eng.server = types.SimpleNamespace(cell=root)
    eng.client_manager = cm
    jr = JobRunner(workspace_root=ws)
    eng.job_runner = jr
    mgr = FLContextManager(engine=eng, identity_name="server")
    eng.new_context = mgr.new_context
    adm = types.SimpleNamespace(client_lock=threading.Lock(), clients={})
    srv = FederatedServer.__new__(FederatedServer)
    srv.client_manager, srv.heart_beat_timeout, srv.shutdown = cm, 600, False
    srv.admin_server = types.SimpleNamespace(client_dead=lambda token: FedAdminServer.client_dead(adm, token))
    srv.tokens, srv.logger, srv.engine = {}, logging.getLogger("FederatedServer"), eng

    def setup():
        cm.clients.clear(); cm.name_to_clients.clear()
        dead_ahead = [login(f"site-{k}") for k in range(1, ahead + 1)]       # listed first (insertion order)
        b = login(f"site-{ahead + 1}")
        alive = [login(f"site-{k}") for k in range(ahead + 2, ahead + 5)]
        for c in dead_ahead + [b]:
            c.last_connect_time = time.time() - 700                          # all missed heartbeats (outage)
        everyone = {c.token: c for c in dead_ahead + [b] + alive}
        eng.run_processes.clear()
        eng.exception_run_processes.clear()
        for j in range(n_jobs):
            eng.run_processes[f"job{j}"] = {RunProcessKey.JOB_ID: f"job{j}", RunProcessKey.PARTICIPANTS: everyone}
        # a job whose SJ already finished still waits for the dead clients' outcomes (real fail_run path)
        jr.running_jobs["jobF"] = types.SimpleNamespace(job_id="jobF", run_aborted=False)
        jr._pending_client_outcomes["jobF"] = {c.name for c in dead_ahead + [b]}
        return dead_ahead, b

    hits, durs, other = 0, [], {}
    for i in range(n):
        dead_ahead, b = setup()
        t_scan = time.time() + 0.1
        t_login = t_scan + random.uniform(-x, x)
        rec = {}

        def relogin():
            time.sleep(max(0.0, t_login - time.time()))
            login(b.name)                                  # B's CP process restarted and logs in

        def cleanup():
            time.sleep(max(0.0, t_scan - time.time()))
            rec["start"] = time.time()
            try:
                srv.remove_dead_clients()                  # one pass of client_cleanup
            except Exception as e:
                rec["exc"] = f"{type(e).__name__}: {e}"
            rec["end"] = time.time()

        tl = threading.Thread(target=relogin, daemon=True); tl.start()
        tc = threading.Thread(target=cleanup, name="client_cleanup", daemon=True); tc.start()
        tc.join(); tl.join()
        e = rec.get("exc", "")
        if "NoneType" in e and "name" in e:
            hits += 1
        elif e:
            other[e] = other.get(e, 0) + 1
        durs.append(rec["end"] - rec["start"])
    # direct timing: logout of one dead client listed before B, and the real fail_run on that path
    lo, fr = [], []
    for _ in range(100):
        dead_ahead, b = setup()
        t0 = time.perf_counter(); srv.logout_client(dead_ahead[0].token); lo.append(time.perf_counter() - t0)
        jr.running_jobs["jobF"] = types.SimpleNamespace(job_id="jobF", run_aborted=False)
        jr._pending_client_outcomes["jobF"] = {b.name}
        with eng.new_context() as ctx:
            t0 = time.perf_counter(); jr.fail_run("jobF", 101, ctx); fr.append(time.perf_counter() - t0)
    for p in sjs:
        p.stdin.close(); p.wait(timeout=10)
    root.stop()
    durs.sort(); lo.sort(); fr.sort()
    w = hits / n * 2 * x
    print(f"trials={n} B re-login offset uniform +-{1000*x:.1f} ms; dead clients listed before B={ahead}; "
          f"running jobs per dead client={n_jobs}")
    print(f"remove_dead_clients pass: median {1e3*durs[n//2]:.2f} ms; logout_client of one dead client (direct): "
          f"median {1e3*lo[len(lo)//2]:.2f} ms, p90 {1e3*lo[int(len(lo)*.9)]:.2f} ms; real fail_run on the "
          f"missing-outcome path: median {1e3*fr[len(fr)//2]:.3f} ms")
    print(f"client_cleanup crashed (AttributeError on client.name of None) in {hits}/{n}; other exceptions: {other}")
    print(f"window W = {1e3*w:.3f} ms per scan")
    print(f"  re-login uniform within the 5.2 s cleanup cycle in which B became overdue: P(T2) = {w/5.2:.1e}")
    print(f"  re-login uniform over a 10-minute span (CP restarted 10-20 min after it died): P(T2) = {w/600:.1e}")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--sj":
        sj_main(sys.argv[2], sys.argv[3])
    else:
        try:
            main()
        finally:
            sys.stdout.flush()
            sys.stderr.flush()
            os._exit(0)      # the cell's connector threads are non-daemon executor threads
