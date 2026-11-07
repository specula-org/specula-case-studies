"""L13 under natural timing: does a panicked SJ's one UPDATE_RUN_STATUS reach the
SP in time when nothing delays or drops it?
Pinned source c411a201, read-only via sys.path.

l13_repro.py injected a 2.5 s delay or a loss. Here the message goes over the
real transport. SP side (this process): a real root Cell with its internal
listener, the real FederatedServer._listen_command registered as in
_register_cellnet_cbs (fed_server.py:469-473), the real
ServerEngine.wait_for_complete (server_engine.py:204-235) on a real Popen handle
of the SJ process, then the real JobRunner._get_finished_job_status. SJ side (a
child process per trial, unique job id as in production): a real job Cell
"server.<job_id>" connected to the SP's internal listener; after `settle` seconds
(a real SJ sends its final status minutes after connecting) system_panic has set FATAL_SYSTEM_ERROR (sticky, as
ServerRunner.handle_event does, server_runner.py:253-257); the real
ServerEngine.update_job_run_status (server_engine.py:874-885) sends the status
with fire_and_forget, then the SJ exits with code 0:
  graceful  the real shutdown_job_process_runtime (job_process_cleanup.py:24-70:
            F3 streaming shutdown, cell.stop), then exit 0 - the runner_process
            finally path (runner_process.py:126-146)
  abrupt    os._exit(0) right after the send (no cell stop, no flush step)
Optional busy threads load the SP's GIL (other server work).

The job is misclassified (L13) only if the handler runs more than 2 s after the
process exit. The script reports, per trial, send->handler latency and
exit->handler slack, and the final job status. It also counts DATA frames the
SP's SFM layer dropped because they were processed before the handshake had
attached the endpoint (conn_manager.py:406-419: READY is sent before
update_endpoint, and frames of one connection are processed concurrently by the
frame_mgr pool, conn_manager.py:444-450); with a short settle time this hits
the status message itself.

usage: l13_natural.py [trials] [mode graceful|abrupt] [busy_threads] [settle_s]
"""
import logging, os, socket, subprocess, sys, tempfile, threading, time, types

SRC = "/home/ubuntu/nvflare-integrated-model-20261103/sources/current"
sys.dont_write_bytecode = True
sys.path.insert(0, SRC)

from nvflare.fuel.f3.cellnet.cell import Cell  # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".tmp")


def sj_main(url, mode, job_id, settle):
    from nvflare.apis.fl_constant import FLContextKey
    from nvflare.apis.fl_context import FLContextManager
    from nvflare.private.fed.app.job_process_cleanup import shutdown_job_process_runtime
    from nvflare.private.fed.server.server_engine import ServerEngine

    cell = Cell(f"server.{job_id}", "", secure=False, credentials={}, create_internal_listener=False,
                parent_url=url)
    cell.start()
    while not cell.is_cell_connected("server"):
        time.sleep(0.02)
    time.sleep(settle)
    eng = ServerEngine.__new__(ServerEngine)
    sent = {}

    class CellView:                                   # passes the real send through, keeps its return value
        def fire_and_forget(self, **kw):
            sent["r"] = cell.fire_and_forget(**kw)
            return sent["r"]
    eng.server = types.SimpleNamespace(cell=CellView())
    mgr = FLContextManager(engine=eng, identity_name="server", job_id=job_id,
                           public_stickers={FLContextKey.CURRENT_RUN: job_id},
                           private_stickers={FLContextKey.FATAL_SYSTEM_ERROR: True})   # system_panic happened
    eng.new_context = mgr.new_context
    t_send = time.time()
    eng.update_job_run_status()                       # start_server_app finally (server_app_runner.py:89)
    print(f"SENT {t_send} FF {repr(sent.get('r')).replace(' ', '')}", flush=True)
    if mode == "abrupt":
        os._exit(0)
    shutdown_job_process_runtime(stop_command_admission=None, wait_for_command_callbacks=None,
                                 stop_cell=cell.stop, logger=logging.getLogger("sj"))
    print(f"EXIT {time.time()}", flush=True)
    os._exit(0)


def main():
    from nvflare.apis.fl_constant import RunProcessKey
    from nvflare.apis.fl_context import FLContext
    from nvflare.private.defs import CellChannel
    from nvflare.private.fed.server.fed_server import FederatedServer
    from nvflare.private.fed.server.job_runner import JobRunner
    from nvflare.private.fed.server.server_engine import ServerEngine
    from unittest.mock import MagicMock

    n = int(sys.argv[1]) if len(sys.argv) > 1 else 50
    mode = sys.argv[2] if len(sys.argv) > 2 else "graceful"
    n_busy = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    settle = float(sys.argv[4]) if len(sys.argv) > 4 else 1.0
    os.makedirs(ROOT, exist_ok=True)
    ws = tempfile.mkdtemp(prefix="l13n_", dir=ROOT)
    logging.basicConfig(filename=os.path.join(ws, "server.log"), level=logging.INFO)
    dropped = []

    class DropCounter(logging.Handler):
        def emit(self, record):
            if "Ignoring DATA before endpoint attachment" in record.getMessage():
                dropped.append(time.time())
    sfm_log = logging.getLogger("nvflare.fuel.f3.sfm.conn_manager")
    sfm_log.setLevel(logging.DEBUG)
    sfm_log.addHandler(DropCounter(level=logging.DEBUG))
    sfm_log.propagate = False
    s = socket.socket(); s.bind(("localhost", 0)); port = s.getsockname()[1]; s.close()
    root = Cell("server", f"tcp://localhost:{port}", secure=False, credentials={}, create_internal_listener=True)

    eng = ServerEngine.__new__(ServerEngine)
    eng.lock, eng.logger = threading.Lock(), logging.getLogger("ServerEngine")
    eng.run_processes, eng.exception_run_processes = {}, {}
    eng.engine_info = types.SimpleNamespace(status=None)
    eng.client_manager = types.SimpleNamespace(clients={})
    srv = FederatedServer.__new__(FederatedServer)
    srv.lock, srv.engine, srv.logger = threading.Lock(), eng, logging.getLogger("FederatedServer")
    handled = []

    def listener(request):
        handled.append(time.time())
        return srv._listen_command(request)
    root.register_request_cb(channel=CellChannel.SERVER_PARENT_LISTENER, topic="*", cb=listener)
    root.start()
    url = root.get_internal_listener_url()

    stop_busy = threading.Event()

    def busy():
        k = 0
        while not stop_busy.is_set():
            k = (k * 1103515245 + 12345) % 2147483648
    for _ in range(n_busy):
        threading.Thread(target=busy, daemon=True).start()

    statuses, lat, slack, missing, sends, late = {}, [], [], 0, {}, []
    for i in range(n):
        handled.clear()
        job_id = f"job-{i}-{os.getpid()}"
        p = subprocess.Popen([sys.executable, "-B", __file__, "--sj", url, mode, job_id, repr(settle)],
                             stdout=subprocess.PIPE, text=True)
        eng.run_processes[job_id] = {RunProcessKey.JOB_HANDLE: p, RunProcessKey.JOB_ID: job_id,
                                     RunProcessKey.PARTICIPANTS: {}}
        exit_seen = {}

        def waiter():
            p.wait()
            exit_seen["t"] = time.time()
        tw = threading.Thread(target=waiter, daemon=True); tw.start()
        eng.wait_for_complete(ws, job_id, p)          # real: wait, <= 2 s for PROCESS_FINISHED, rc, pop
        tw.join()
        out = p.stdout.read().split()
        t_send = float(out[out.index("SENT") + 1]) if "SENT" in out else None
        time.sleep(0.3)
        jr = JobRunner.__new__(JobRunner)
        jr.logger = MagicMock(); jr.log_info = lambda *a, **k: None
        jr.abort_client_run = lambda *a, **k: None
        st = str(jr._get_finished_job_status(eng, types.SimpleNamespace(job_id=job_id), FLContext()))
        statuses[st] = statuses.get(st, 0) + 1
        ff = out[out.index("FF") + 1] if "FF" in out else "?"
        sends[ff] = sends.get(ff, 0) + 1
        if handled and t_send:
            lat.append(handled[0] - t_send)
            slack.append(exit_seen["t"] + 2.0 - handled[0])
        else:
            missing += 1
            for _ in range(40):                       # late or lost?
                if handled:
                    break
                time.sleep(0.1)
            if handled:
                late.append(handled[0] - exit_seen["t"])
        eng.exception_run_processes.clear()
    stop_busy.set()
    root.stop()
    lat.sort(); slack.sort()
    print(f"trials={n} SJ exit={mode} busy SP threads={n_busy} settle after connect={settle}s")
    print(f"job status after the SJ exits with 0 following system_panic: {statuses}")
    if lat:
        print(f"send -> SP handler latency: median {1e3*lat[len(lat)//2]:.2f} ms, max {1e3*lat[-1]:.2f} ms")
        print(f"slack before the 2 s wait expires (exit + 2 s - handler): min {slack[0]:.3f} s, "
              f"median {slack[len(slack)//2]:.3f} s")
    print(f"SJ-side fire_and_forget results: {sends}")
    print(f"status message not handled within the 2 s wait: {missing}/{n}; of these handled later "
          f"(late, s after exit): {[round(v, 2) for v in late]}; never handled within 4 more s: {missing - len(late)}")
    print(f"DATA frames dropped by the SP before endpoint attachment: {len(dropped)}")
    bad = sum(v for k, v in statuses.items() if "COMPLETED" in k)
    print("L13 natural: NOT reproduced (every panicked job recorded as EXECUTION_EXCEPTION)" if bad == 0 else
          f"L13 natural: REPRODUCED in {bad}/{n} trials (panicked job recorded as COMPLETED)")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--sj":
        sj_main(sys.argv[2], sys.argv[3], sys.argv[4], float(sys.argv[5]))
    else:
        try:
            main()
        finally:
            sys.stdout.flush()
            sys.stderr.flush()
            os._exit(0)
