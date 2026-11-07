"""C1-A / C1-B under natural (unforced) scheduling. Pinned source c411a201, read-only via sys.path.

c1_repro.py aligns the two threads with events. This harness does not: the run thread and the
completion thread run freely; only the store fault itself is modelled.

Window (job_runner.py): run() inserts the job into running_jobs (768), then writes RUNNING (769).
If that write raises, the except branch removes the job (773-775) and later writes FAILED_TO_RUN
(793-796). The completion thread (492-592) scans every 1 s (592); it picks up any job that is in
running_jobs and no longer in engine.run_processes (495-497), finalizes it (abort RPC, workspace
archive, 575 terminal write) and then does an unguarded `del self.running_jobs[job_id]` (583).
  C1-A: the 575 terminal write lands before the 796 FAILED_TO_RUN write.
  C1-B: the except branch's 775 removal lands between the completion thread's 497 get and its 583 del.
Both need the SJ to be gone from run_processes inside the window [768, time the RUNNING write fails].

Real code: JobRunner.run + its completion thread, _get_finished_job_status, abort_client_run,
_save_workspace, SimpleJobDefManager, FilesystemStorage (real files, fsync, zip archive),
ServerEngine.wait_for_complete (real 2 s UPDATE_RUN_STATUS wait) reaping a real child process that
exits with CONFIG_ERROR (103) like an SJ whose server config fails.
Stubs: engine plumbing, the scheduler, _deploy_job, client RPC latencies (start_client_job, abort,
cancel_client_resources), and the store fault on the RUNNING write (time-to-failure D, then
StorageException). The "persistent" scenario uses a real OS fault instead (job dir made read-only,
real EACCES from FilesystemStorage), with no injected exception.

usage:
  c1_natural.py measure                      real-code latencies
  c1_natural.py run <scenario> <n> [par]     n trials of a scenario, par processes (default 7)
  c1_natural.py trial <scenario> <seed>      one trial (internal), prints one JSON line
scenarios: control fastfail sdk slow sdk_alive slow_alive persistent persistent_early fixed:<D seconds>
           stall:<D seconds> (RUNNING write delayed by D, then succeeds: the #5301 path)
           silentabort:<D seconds> (as fixed:, but the completion thread's ABORT waits its 2 s timeout)
"""
import contextlib, json, logging, os, random, shutil, subprocess, sys, tempfile, threading, time, types, uuid
from unittest.mock import MagicMock

SRC = "/home/ubuntu/nvflare-integrated-model-20261103/sources/current"
sys.dont_write_bytecode = True
sys.path.insert(0, SRC)
logging.disable(logging.CRITICAL)

from nvflare.apis.client import Client  # noqa: E402
from nvflare.apis.fl_constant import RunProcessKey, SystemComponents  # noqa: E402
from nvflare.apis.fl_context import FLContextManager  # noqa: E402
from nvflare.apis.impl.job_def_manager import SimpleJobDefManager  # noqa: E402
from nvflare.apis.job_def import JobMetaKey, RunStatus  # noqa: E402
from nvflare.apis.job_scheduler_spec import DispatchInfo  # noqa: E402
from nvflare.apis.server_engine_spec import ServerEngineSpec  # noqa: E402
from nvflare.apis.storage import StorageException  # noqa: E402
from nvflare.app_common.storages.filesystem_storage import FilesystemStorage  # noqa: E402
from nvflare.private.fed.server.job_runner import JobRunner  # noqa: E402
from nvflare.private.fed.server.server_engine import ServerEngine  # noqa: E402
from nvflare.private.fed.server.server_state import HotState  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
TMP = os.path.abspath(os.path.join(HERE, "..", "..", ".tmp"))
RUNNING, FAILED = RunStatus.RUNNING.value, RunStatus.FAILED_TO_RUN.value
TERMINAL = {RunStatus.FINISHED_EXECUTION_EXCEPTION.value, RunStatus.FINISHED_COMPLETED.value,
            RunStatus.FINISHED_ABNORMAL.value, RunStatus.FINISHED_ABORTED.value}


def scenario_params(name, rng):
    """t_start: start_client_job latency; sj: SJ exit time after spawn (None = long job); d: RUNNING
    write time-to-failure (None = no fault)."""
    sj_fast = rng.uniform(1.0, 1.5)          # imports (~0.8 s measured) + config error, before any cell
    slow_start = rng.uniform(4.5, 6.5)        # START_JOB reply slower than SJ exit + 2 s reap wait
    fast_start = rng.uniform(0.1, 0.5)        # CP spawns the CJ and replies
    if name == "control":
        return dict(t_start=slow_start, sj=sj_fast, d=None)
    if name == "fastfail":                    # local FS: ENOSPC/EROFS/EACCES/EMFILE fail in microseconds
        return dict(t_start=slow_start, sj=sj_fast, d=0.0)
    if name in ("sdk", "sdk_alive"):          # object-store SDK, 3 attempts, full-jitter backoff
        d = sum(rng.uniform(0.02, 0.15) for _ in range(3)) + rng.uniform(0, 1) * 1 + rng.uniform(0, 1) * 2
        return dict(t_start=slow_start if name == "sdk" else fast_start, sj=sj_fast, d=d)
    if name in ("slow", "slow_alive"):        # stands for timeouts of many seconds (soft NFS, SDK read timeout)
        return dict(t_start=slow_start if name == "slow" else fast_start, sj=sj_fast, d=rng.uniform(5.0, 15.0))
    if name == "persistent":                  # store read-only from the client-start phase on
        return dict(t_start=slow_start, sj=sj_fast, d="readonly")
    if name == "persistent_early":            # store read-only from the deploy phase on
        return dict(t_start=slow_start, sj=sj_fast, d="readonly_early")
    if name.startswith("fixed:"):
        return dict(t_start=slow_start, sj=sj_fast, d=float(name.split(":", 1)[1]))
    if name.startswith("silentabort:"):       # fixed D; a client does not answer ABORT -> 2.0 s timeout (460)
        return dict(t_start=slow_start, sj=sj_fast, d=float(name.split(":", 1)[1]), abort_rtt=2.0)
    if name.startswith("stall:"):             # #5301: RUNNING write delayed, then succeeds (no failure)
        return dict(t_start=slow_start, sj=sj_fast, d=["stall", float(name.split(":", 1)[1])])
    raise SystemExit(f"unknown scenario {name}")


class Store(FilesystemStorage):
    """Real FilesystemStorage; records status writes; optionally fails the job's first RUNNING write."""

    def __init__(self, root, fault_d):
        super().__init__(root_dir=root, uri_root="/")
        self.fault_d, self.history, self.t_running = fault_d, [], None

    def update_meta(self, uri, meta, replace):
        st = meta.get(JobMetaKey.STATUS.value)
        if st == RUNNING and self.t_running is None:
            self.t_running = time.monotonic()
            if isinstance(self.fault_d, float):
                time.sleep(self.fault_d)
                self.history.append((threading.current_thread().name, "RUNNING-write-failed", time.monotonic()))
                raise StorageException("failed to write content: [Errno 5] Input/output error")
            if isinstance(self.fault_d, list):
                time.sleep(self.fault_d[1])
        try:
            super().update_meta(uri, meta, replace)
        except Exception as e:
            if st:
                self.history.append((threading.current_thread().name, f"{st}-write-failed:{type(e).__name__}",
                                     time.monotonic()))
            raise
        if st:
            self.history.append((threading.current_thread().name, st, time.monotonic()))


class Workspace:
    def __init__(self, root):
        self.root = root

    def _d(self, jid, kind):
        p = os.path.join(self.root, jid, kind)
        os.makedirs(p, exist_ok=True)
        return p

    def get_run_dir(self, jid):
        return self._d(jid, "run")

    def get_result_root(self, jid):
        return self._d(jid, "result")

    def get_log_root(self, jid):
        return self._d(jid, "log")

    def get_audit_root(self, jid):
        return self._d(jid, "audit")


def trial(name, seed):
    rng = random.Random(seed)
    p = scenario_params(name, rng)
    work = tempfile.mkdtemp(prefix=f"c1n_{name.replace(':', '_')}_", dir=TMP)
    os.chdir(work)                                   # SimpleJobDefManager makes "jobs" relative to cwd
    store = Store(os.path.join(work, "store"), p["d"])
    jm = SimpleJobDefManager(uri_root="jobs", job_store_id="job_store")
    ws = Workspace(os.path.join(work, "ws"))
    eng = MagicMock(spec=ServerEngineSpec)
    eng.get_component = lambda n: {"job_store": store, SystemComponents.JOB_MANAGER: jm}.get(n)
    eng.server = MagicMock()
    eng.server.server_state = HotState()
    client = Client("site-1", "tok-1")
    eng.get_clients = lambda: [client]
    eng.client_manager = types.SimpleNamespace(clients={"tok-1": client})
    eng.validate_targets = lambda names: ([client], [])
    eng.get_job_clients = lambda sites: {"tok-1": client}
    eng.get_workspace = lambda: ws
    eng.run_processes, eng.exception_run_processes, eng.lock = {}, {}, threading.Lock()
    mgr = FLContextManager(engine=eng, identity_name="server")
    eng.new_context = mgr.new_context
    marks, procs = {}, []
    reaper = types.SimpleNamespace(run_processes=eng.run_processes, exception_run_processes=eng.exception_run_processes,
                                   lock=eng.lock, logger=logging.getLogger("sj"), engine_info=types.SimpleNamespace())

    def rpc(lo, hi):
        time.sleep(rng.uniform(lo, hi))
        return []

    eng.server.admin_server = types.SimpleNamespace(
        timeout=10.0, sai=types.SimpleNamespace(new_context=lambda: contextlib.nullcontext(None)),
        send_requests=lambda reqs, ctx, timeout_secs=2.0, optional=False:
        rpc(p["abort_rtt"], p["abort_rtt"]) if "abort_rtt" in p else rpc(0.02, 0.3))   # abort RTT

    def start_app_on_server(fl_ctx, job, job_clients, snapshot=None):
        sleep_for = p["sj"] if p["sj"] is not None else 3600
        code = 103 if p["sj"] is not None else 0     # ProcessExitCode.CONFIG_ERROR
        proc = subprocess.Popen([sys.executable, "-S", "-c", f"import time,sys;time.sleep({sleep_for});sys.exit({code})"])
        procs.append(proc)
        marks["sj_spawn"] = time.monotonic()
        eng.run_processes[job.job_id] = {RunProcessKey.PARTICIPANTS: job_clients, RunProcessKey.JOB_HANDLE: proc}

        def reap():
            ServerEngine.wait_for_complete(reaper, ws.root, job.job_id, proc)   # real: waits 2 s for UPDATE_RUN_STATUS
            marks["sj_reaped"] = time.monotonic()
        threading.Thread(target=reap, name="sj_reaper", daemon=True).start()
        return ""

    def start_client_job(job, client_sites, fl_ctx):
        time.sleep(p["t_start"])
        if p["d"] == "readonly":                     # the job store goes read-only (e.g. ext4 errors=remount-ro)
            os.chmod(os.path.join(store.root_dir, "jobs", job.job_id), 0o555)
        ok = types.SimpleNamespace(body="OK", get_header=lambda *a, **k: "OK")
        return [types.SimpleNamespace(client_name=s, reply=ok) for s in client_sites]

    def abort_app_on_server(job_id, turn_to_cold=False):
        for pr in procs:
            if pr.poll() is None:
                pr.terminate()
        return ""

    eng.start_app_on_server = start_app_on_server
    eng.start_client_job = start_client_job
    eng.abort_app_on_server = abort_app_on_server
    eng.cancel_client_resources = lambda *a, **k: rpc(0.02, 0.3)
    eng.remove_exception_process = lambda jid: eng.exception_run_processes.pop(jid, None)

    class Scheduler:
        given = set()

        def schedule_job(self, job_manager, job_candidates, fl_ctx):
            for j in job_candidates:
                if j.job_id not in self.given:
                    self.given.add(j.job_id)
                    return j, {"site-1": DispatchInfo(app_name="app", resource_requirements={}, token="tok-1")}
            return None, None

        def remove_scheduled_job(self, job_id):
            pass

    runner = JobRunner(workspace_root=ws.root)
    runner.scheduler = Scheduler()
    def deploy(job, sites, fl_ctx):
        time.sleep(rng.uniform(0.1, 1.5))
        if p["d"] == "readonly_early":
            os.chmod(os.path.join(store.root_dir, "jobs", job.job_id), 0o555)
        return job.job_id, []
    runner._deploy_job = deploy
    real_gfs = runner._get_finished_job_status

    def gfs(engine, job, fl_ctx):                    # timestamp only, then the real method
        marks.setdefault("pickup", time.monotonic())
        return real_gfs(engine, job, fl_ctx)
    runner._get_finished_job_status = gfs

    jid = str(uuid.uuid4())
    store.create_object(jm.job_uri(jid), b"job-data", {JobMetaKey.JOB_ID.value: jid,
                        JobMetaKey.STATUS.value: RunStatus.SUBMITTED.value, JobMetaKey.SCHEDULE_COUNT.value: 0,
                        JobMetaKey.LAST_SCHEDULE_TIME.value: 0, JobMetaKey.SCHEDULE_HISTORY.value: []},
                        overwrite_existing=True)
    run_dir = ws.get_run_dir(jid)                    # a deployed app of ~1 MB (config + custom code)
    with open(os.path.join(run_dir, "app.bin"), "wb") as f:
        f.write(os.urandom(1 << 20))
    crashes = []
    threading.excepthook = lambda a: crashes.append((a.thread.name, a.exc_type.__name__, str(a.exc_value)[:80]))
    t = threading.Thread(target=runner.run, args=(mgr.new_context(),), name="job_runner", daemon=True)
    t.start()
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:               # until the run thread has finished the start attempt
        if not t.is_alive() or any(h[0] == "job_runner" and h[1] in (RUNNING, FAILED) for h in store.history):
            break
        time.sleep(0.05)
    time.sleep(3.5)                                  # completion thread scans every 1 s
    runner.ask_to_stop = True
    for pr in procs:
        if pr.poll() is None:
            pr.kill()
    try:
        final = store.get_meta(jm.job_uri(jid)).get(JobMetaKey.STATUS.value)
    except Exception as e:
        final = f"unreadable:{type(e).__name__}"
    hist = [(h[0] if h[0] in ("job_runner",) else "completion", h[1], round(h[2] - store.t_running, 4)
             if store.t_running else None) for h in store.history]
    terminal_by_completion = [h for h in hist if h[0] == "completion" and h[1] in TERMINAL]
    failed_by_runner = [h for h in hist if h[0] == "job_runner" and h[1] == FAILED]
    c1a = bool(terminal_by_completion and failed_by_runner and terminal_by_completion[0][2] < failed_by_runner[-1][2])
    c1b = any(c[1] == "KeyError" for c in crashes if c[0] != "job_runner")
    sched_dead = not t.is_alive() and any(c[0] == "job_runner" for c in crashes)
    running_by_runner = [h for h in hist if h[0] == "job_runner" and h[1] == RUNNING]
    late_running = bool(terminal_by_completion and running_by_runner and final == RUNNING
                        and terminal_by_completion[0][2] < running_by_runner[-1][2])
    rel = lambda k: None if k not in marks or store.t_running is None else round(marks[k] - store.t_running, 4)
    out = dict(scenario=name, seed=seed, d=p["d"], t_start=round(p["t_start"], 3), sj_exit=p["sj"],
               sj_reaped_rel768=rel("sj_reaped"), pickup_rel768=rel("pickup"), final=final, history=hist,
               crashes=crashes, C1A=c1a, C1B=c1b, sched_dead=sched_dead, late_running=late_running)
    os.chdir(TMP)
    with contextlib.suppress(Exception):
        os.chmod(os.path.join(store.root_dir, "jobs", jid), 0o755)
    shutil.rmtree(work, ignore_errors=True)
    print(json.dumps(out), flush=True)


def run(name, n, par):
    py = sys.executable
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    pending, running, results = list(range(n)), [], []
    base = random.randrange(1 << 30)
    while pending or running:
        while pending and len(running) < par:
            s = base + pending.pop(0)
            running.append(subprocess.Popen([py, "-B", __file__, "trial", name, str(s)], stdout=subprocess.PIPE,
                                            stderr=subprocess.DEVNULL, text=True, env=env, cwd=TMP))
        time.sleep(0.2)
        for pr in [r for r in running if r.poll() is not None]:
            running.remove(pr)
            line = (pr.stdout.read() or "").strip().splitlines()
            if line:
                results.append(json.loads(line[-1]))
    k = lambda f: sum(1 for r in results if r[f])
    benign = sum(1 for r in results if not (r["C1A"] or r["C1B"] or r["sched_dead"] or r["late_running"]))
    finals = {}
    for r in results:
        finals[r["final"]] = finals.get(r["final"], 0) + 1
    pick = sorted(r["pickup_rel768"] for r in results if r["pickup_rel768"] is not None)
    print(f"scenario={name} trials={len(results)} C1-A={k('C1A')} C1-B={k('C1B')} "
          f"scheduler_dead={k('sched_dead')} late_RUNNING_over_terminal(#5301)={k('late_running')} benign={benign} "
          f"final_status={finals}")
    if pick:
        print(f"  completion pickup after line 768: n={len(pick)} min={pick[0]:.3f}s "
              f"median={pick[len(pick) // 2]:.3f}s max={pick[-1]:.3f}s")
    for r in results[:2]:
        print("  example:", json.dumps({x: r[x] for x in ("d", "sj_reaped_rel768", "pickup_rel768", "history",
                                                         "crashes", "final")}))
    with open(os.path.join(TMP, f"c1n_{name.replace(':', '_')}_{int(time.time())}.jsonl"), "w") as f:
        for r in results:
            f.write(json.dumps(r) + "\n")


def measure():
    work = tempfile.mkdtemp(prefix="c1n_measure_", dir=TMP)
    os.chdir(work)
    store = FilesystemStorage(root_dir=os.path.join(work, "store"), uri_root="/")
    jid = str(uuid.uuid4())
    uri = f"jobs/{jid}"
    store.create_object(uri, b"x", {"status": "DISPATCHED"}, overwrite_existing=True)

    def stats(xs):
        xs = sorted(xs)
        return f"median={xs[len(xs) // 2] * 1e3:.3f} ms p99={xs[int(len(xs) * .99)] * 1e3:.3f} ms max={xs[-1] * 1e3:.3f} ms"
    ok = []
    for _ in range(300):
        t0 = time.perf_counter()
        store.update_meta(uri, {"status": "RUNNING"}, replace=False)
        ok.append(time.perf_counter() - t0)
    print("FilesystemStorage.update_meta (RUNNING write, real fsync):", stats(ok))
    os.chmod(os.path.join(store.root_dir, "jobs", jid), 0o555)
    bad, err = [], None
    for _ in range(300):
        t0 = time.perf_counter()
        try:
            store.update_meta(uri, {"status": "RUNNING"}, replace=False)
        except StorageException as e:
            err = str(e)[:70]
        bad.append(time.perf_counter() - t0)
    os.chmod(os.path.join(store.root_dir, "jobs", jid), 0o755)
    print("FilesystemStorage.update_meta failing on a read-only job dir (real EACCES):", stats(bad), "|", err)
    for mb in (1, 100):
        run_dir = os.path.join(work, f"ws{mb}", "run")
        os.makedirs(run_dir)
        with open(os.path.join(run_dir, "blob"), "wb") as f:
            f.write(os.urandom(mb << 20))
        t0 = time.perf_counter()
        store.update_object(uri, [run_dir], "workspace")       # what JobManager.save_workspace does
        print(f"workspace archive of a {mb} MB run dir (real zip + replace): {(time.perf_counter() - t0) * 1e3:.1f} ms")
    shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    os.makedirs(TMP, exist_ok=True)
    cmd = sys.argv[1] if len(sys.argv) > 1 else "measure"
    if cmd == "measure":
        measure()
    elif cmd == "trial":
        trial(sys.argv[2], int(sys.argv[3]))
    elif cmd == "run":
        run(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]) if len(sys.argv) > 4 else 7)
