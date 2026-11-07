"""T3 under natural timing: how wide is the window in which another job's SJ
exit kills the server's client_cleanup thread?
Pinned source c411a201, read-only via sys.path.

Mechanism (t3_repro.py): FederatedServer.notify_dead_client (fed_server.py:
1105-1122) iterates engine.run_processes without engine.lock; every job the dead
client takes part in costs one ServerEngine.notify_dead_job (server_engine.py:
887-898: engine.lock + Cell.fire_and_forget + a warning log). A pop by
ServerEngine.wait_for_complete (204-235) or an insert by a job start (322-327)
during that loop raises "dictionary changed size during iteration" and nothing
catches it on the way up to client_cleanup (290-321).

Everything on that path is real here, including the transport: the SP root cell
(tcp, internal listener) runs in this process; job A's SJ is a real Cell in a
child process connected to the internal listener, so HANDLE_DEAD_JOB is a real
TCP fire_and_forget; job B's SJ is a real child process whose exit is observed
by the real wait_for_complete (Popen handle; get_return_code). The dead client
goes through the real ClientManager, FederatedServer.remove_dead_clients /
logout_client / remove_client_data / notify_dead_client, FedAdminServer.
client_dead, and a real JobRunner (no pending outcomes). Logging goes to a file
at INFO, as on a server. Stub: none on the path; remove_dead_clients is called
by a thread at a chosen time instead of by the 5 s client_cleanup loop (it is
that loop's body).

No forcing: job B's exit time is uniform in [-X, +X] around the cleanup scan.
The measured crash fraction gives the window W = fraction * 2X. A crash needs
B's exit inside W of a dead-client scan, so per dead-client event
P(T3) ~= W * (rate of SJ exits + job starts on the server).

usage: t3_natural.py [trials] [X_ms] [participating_jobs] [busy_threads]
  participating_jobs: running jobs (besides B) the dead client takes part in
  busy_threads: CPU-bound threads in the SP process (GIL load from other work)
"""
import logging, os, random, socket, subprocess, sys, tempfile, threading, time, types

SRC = "/home/ubuntu/nvflare-integrated-model-20261103/sources/current"
sys.dont_write_bytecode = True
sys.path.insert(0, SRC)

from nvflare.fuel.f3.cellnet.cell import Cell  # noqa: E402
from nvflare.private.defs import CellChannel  # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".tmp")


def sj_main(fqcn, url):
    """A job's SJ cell: connects to the SP's internal listener, accepts server commands."""
    got = []
    cell = Cell(fqcn, "", secure=False, credentials={}, create_internal_listener=False, parent_url=url)
    cell.register_request_cb(channel=CellChannel.SERVER_COMMAND, topic="*", cb=lambda req: got.append(1) and None)
    cell.start()
    while not cell.is_cell_connected("server"):
        time.sleep(0.05)
    print("READY", flush=True)
    sys.stdin.read()
    print("GOT", len(got), flush=True)
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

    n = int(sys.argv[1]) if len(sys.argv) > 1 else 200
    x = float(sys.argv[2]) / 1000 if len(sys.argv) > 2 else 0.005
    n_part = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    n_busy = int(sys.argv[4]) if len(sys.argv) > 4 else 0
    os.makedirs(ROOT, exist_ok=True)
    ws = tempfile.mkdtemp(prefix="t3n_", dir=ROOT)
    logging.basicConfig(filename=os.path.join(ws, "server.log"), level=logging.INFO)

    s = socket.socket(); s.bind(("localhost", 0)); port = s.getsockname()[1]; s.close()
    root = Cell("server", f"tcp://localhost:{port}", secure=False, credentials={}, create_internal_listener=True)
    root.start()
    url = root.get_internal_listener_url()
    sjs = []
    for i in range(n_part):
        p = subprocess.Popen([sys.executable, "-B", __file__, "--sj", f"server.job{i}", url],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        assert p.stdout.readline().strip() == "READY"
        sjs.append(p)

    stop_busy = threading.Event()

    def busy():
        k = 0
        while not stop_busy.is_set():
            k = (k * 1103515245 + 12345) % 2147483648
    for _ in range(n_busy):
        threading.Thread(target=busy, daemon=True).start()

    cm = ClientManager(project_name="p", min_num_clients=1, max_num_clients=100)

    def register(name):
        req = Message(headers={CellMessageHeaderKeys.CLIENT_NAME: name, MessageHeaderKey.ORIGIN: name,
                               CellMessageHeaderKeys.PROJECT_NAME: "p",
                               CellMessageHeaderKeys.CLIENT_TYPE: ClientType.REGULAR,
                               CellMessageHeaderKeys.CLIENT_IP: "10.0.0.1"}, payload=Shareable())
        return cm.authenticate(req, FLContext())     # pops the name's old token, inserts the new one

    others = [register(f"site-{k}") for k in range(2, 6)]
    eng = ServerEngine.__new__(ServerEngine)
    eng.lock, eng.logger, eng.exception_run_processes = threading.Lock(), logging.getLogger("ServerEngine"), {}
    eng.run_processes = {}
    eng.engine_info = types.SimpleNamespace(status=None)
    eng.server = types.SimpleNamespace(cell=root)
    eng.job_runner = JobRunner(workspace_root=ws)
    mgr = FLContextManager(engine=eng, identity_name="server")
    eng.new_context = mgr.new_context
    adm = types.SimpleNamespace(client_lock=threading.Lock(), clients={})
    srv = FederatedServer.__new__(FederatedServer)
    srv.client_manager, srv.heart_beat_timeout, srv.shutdown = cm, 600, False
    srv.admin_server = types.SimpleNamespace(client_dead=lambda token: FedAdminServer.client_dead(adm, token))
    srv.tokens, srv.logger, srv.engine = {}, logging.getLogger("FederatedServer"), eng

    bscript = "import sys,time; t=float(sys.argv[1]); time.sleep(max(0.0, t-time.time()))"
    hits, in_window, durs, pop_lat = 0, 0, [], []
    for i in range(n):
        dead = register("site-1")
        dead.last_connect_time = time.time() - 700        # missed heartbeats for > heart_beat_timeout
        parts = {dead.token: dead, **{c.token: c for c in others}}
        eng.run_processes.clear()
        for j in range(n_part):
            eng.run_processes[f"job{j}"] = {RunProcessKey.JOB_ID: f"job{j}", RunProcessKey.PARTICIPANTS: dict(parts)}
        t_scan = time.time() + 0.15
        t_b = t_scan + random.uniform(-x, x)
        hb = subprocess.Popen([sys.executable, "-S", "-c", bscript, repr(t_b)])
        eng.run_processes["jobB"] = {RunProcessKey.JOB_ID: "jobB", RunProcessKey.JOB_HANDLE: hb,
                                     RunProcessKey.PARTICIPANTS: {c.token: c for c in others},
                                     RunProcessKey.PROCESS_FINISHED: True}   # its UPDATE_RUN_STATUS arrived
        rec = {}

        def waiter():
            eng.wait_for_complete(ws, "jobB", hb)
            rec["popped"] = time.time()

        def cleanup():
            time.sleep(max(0.0, t_scan - time.time()))
            rec["start"] = time.time()
            try:
                srv.remove_dead_clients()                  # one pass of client_cleanup
            except Exception as e:
                rec["exc"] = f"{type(e).__name__}: {e}"
            rec["end"] = time.time()

        tw = threading.Thread(target=waiter, daemon=True); tw.start()
        tc = threading.Thread(target=cleanup, name="client_cleanup", daemon=True); tc.start()
        tc.join(); tw.join(timeout=5)
        if "exc" in rec and "changed size" in rec["exc"]:
            hits += 1
        if "popped" in rec:
            pop_lat.append(rec["popped"] - t_b)
            in_window += rec["start"] <= rec["popped"] <= rec["end"]
        durs.append(rec["end"] - rec["start"])
    # direct timing of the vulnerable loop: notify_dead_client with nothing exiting
    loop = []
    for _ in range(200):
        dead = register("site-1")
        for j in range(n_part):
            eng.run_processes[f"job{j}"][RunProcessKey.PARTICIPANTS][dead.token] = dead
        t0 = time.perf_counter(); srv.notify_dead_client(dead); loop.append(time.perf_counter() - t0)
        cm.remove_client(dead.token)
    stop_busy.set()
    for p in sjs:
        p.stdin.close(); p.wait(timeout=10)
    root.stop()
    durs.sort(); pop_lat.sort(); loop.sort()
    w = hits / n * 2 * x
    print(f"trials={n} B-exit offset uniform +-{1000*x:.1f} ms; dead client in {n_part} running job(s) besides B; "
          f"busy SP threads={n_busy}")
    print(f"remove_dead_clients pass: median {1e3*durs[n//2]:.2f} ms; notify_dead_client loop (direct): "
          f"median {1e3*loop[len(loop)//2]:.2f} ms, p90 {1e3*loop[int(len(loop)*.9)]:.2f} ms")
    print(f"B exit -> pop latency: median {1e3*pop_lat[len(pop_lat)//2]:.2f} ms")
    print(f"pop landed inside the scan in {in_window}/{n}; client_cleanup crashed (RuntimeError: dictionary "
          f"changed size during iteration) in {hits}/{n}")
    print(f"window W = {1e3*w:.3f} ms per dead-client scan")
    for rate, label in ((1 / 60, "1 SJ exit/start per minute"), (1 / 600, "1 per 10 minutes")):
        print(f"  natural P(T3) per dead-client event at {label}: {w*rate:.1e}")


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
