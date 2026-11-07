"""H03 under natural timing. Pinned source c411a201, read-only via sys.path.

Window (external_process_backend.py): _monitor_accepted_result_source reads the trainer's silence
(1259) or cell connection (1270) for task A, decides it timed out, and calls
_fail_accepted_result_source(trainer, A), which re-checks under _result_failure_lock (1288-1293)
that the live source is still A. If A settled in between, the re-check returns False and the monitor
still calls _stop_trainer (1268 / 1278): the launch_once trainer is stopped with no source-failure
notice and no job failure. The gap between the read and the re-check is pure Python.

measure     real _monitor_accepted_result_source; the gap W = (re-check lock acquired) - (silence
            read returned), idle and with 4 busy threads (GIL contention).
run         natural trials: real monitor thread (0.5 s poll, _RESULT_POLL_INTERVAL), real
            CellBackendBase._handle_result_source_settled for A and _handle_result_ready for B (real
            session validation/touch, _task_lock, _on_result_source_settled, _on_result_accepted which
            starts B's real monitor). The trainer has been silent for longer than heartbeat_timeout
            and its SETTLED(A)+RESULT_READY(B) burst arrives at a uniformly random time within the
            poll period after the timeout is crossed; nothing aligns it with the monitor.
Stubs: process-group probe (alive), cell connectivity (connected), _stop_trainer / _cleanup_trainer
/ _fail_job_for_lost_result_source (recorders), DownloadService.notify_source_failure (recorder).
heartbeat_timeout is 1 s instead of the 30 s default (backend_spec.py:79) to keep trials short;
the race only depends on the burst's phase against the poll, not on the timeout value.

usage: h03_natural.py measure [n] | run <seconds> <procs> <pairs_per_proc> [busy] | worker <seconds> <pairs> <seed> <busy>
(busy = CPU-bound threads per worker process, standing for CJ threads that forward A's download)
"""
import json, logging, os, random, subprocess, sys, threading, time, types
from collections import OrderedDict

SRC = "/home/ubuntu/nvflare-integrated-model-20261103/sources/current"
sys.dont_write_bytecode = True
sys.path.insert(0, SRC)
logging.disable(logging.CRITICAL)

import nvflare.app_common.executors.client_api.external_process_backend as epb  # noqa: E402
from nvflare.apis.shareable import Shareable  # noqa: E402
from nvflare.app_common.executors.client_api.cell_backend import CellSession, CellTask  # noqa: E402
from nvflare.client.cell.defs import MsgKey  # noqa: E402
from nvflare.fuel.f3.cellnet.defs import MessageHeaderKey  # noqa: E402
from nvflare.fuel.f3.streaming.download_service import DownloadService  # noqa: E402
from nvflare.fuel.utils.fobs.decomposers.via_downloader import LazyDownloadRef  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
TMP = os.path.abspath(os.path.join(HERE, "..", "..", ".tmp"))
FQCN = "site-1.job1.trainer_1"
SINKS = {}                                       # id(backend._cell) -> list of notified ref tuples


def _notify(**kw):
    SINKS[id(kw["cell"])].append(tuple(kw["ref_ids"]))
    return {}


DownloadService.notify_source_failure = staticmethod(_notify)


class TimedLock:
    def __init__(self):
        self._l, self.acq = threading.Lock(), []

    def __enter__(self):
        self._l.acquire()
        self.acq.append(time.perf_counter())
        return self

    def __exit__(self, *a):
        self._l.release()


def make(hb_timeout, timed=False):
    tr = epb._TrainerSession("tok", FQCN)
    tr.session_id = "s1"
    tr.ready.set()
    if timed:
        tr._result_failure_lock = TimedLock()
    tr.result_source_live.set()
    tr.result_source_task_id = "A"
    tr.result_source_refs, tr.result_receiver_ids = ("refA",), ("server.job1",)
    be = epb.ExternalProcessBackend.__new__(epb.ExternalProcessBackend)
    be.logger = logging.getLogger("h03")
    be._context = types.SimpleNamespace(heartbeat_timeout=hb_timeout, shutdown_timeout=None)
    be._cell = types.SimpleNamespace(is_cell_connected=lambda fqcn: True)
    be._lifecycle_lock, be._terminal_intent, be._closed, be._run_abort_signal = threading.Lock(), None, False, None
    be._secure_mode, be._abort = False, False
    be._task_lock, be._launch_lock = threading.Lock(), threading.Lock()
    be._protocol_sessions, be._active_launch, be._current_task = {FQCN: tr}, tr, None
    be._result_authority = OrderedDict()
    be._process_group_alive = lambda t: True
    rec = types.SimpleNamespace(stops=[], failed=[], notices=[])
    be._stop_trainer = lambda t, natural_exit_wait=0.0: rec.stops.append(
        (time.perf_counter(), t.result_source_task_id))
    be._cleanup_trainer = lambda t: None
    be._fail_job_for_lost_result_source = lambda reason: rec.failed.append(reason)
    SINKS[id(be._cell)] = rec.notices
    return tr, be, rec


def measure(n):
    def one_round(label, n):
        gaps = []
        for _ in range(n):
            tr, be, rec = make(30.0, timed=True)
            reads = []
            tr._last_peer_activity = time.monotonic() - 100.0          # silent for 100 s > 30 s

            def silent_for(tr=tr, reads=reads):
                v = CellSession.silent_for(tr)
                reads.append(time.perf_counter())
                return v
            tr.peer_silent_for = silent_for
            be._monitor_accepted_result_source(tr, "A")                 # real code; returns after failing A
            gaps.append(tr._result_failure_lock.acq[1] - reads[0])      # acq[0] is line 1243, acq[1] line 1288
        gaps.sort()
        q = lambda f: gaps[min(len(gaps) - 1, int(len(gaps) * f))] * 1e6
        big = sum(1 for g in gaps if g >= 1e-3)
        print(f"{label}: n={n} W median={q(.5):.1f} us p99={q(.99):.1f} us p99.9={q(.999):.1f} us "
              f"max={gaps[-1] * 1e6:.0f} us; W>=1ms in {big}/{n}; mean={sum(gaps) / n * 1e6:.1f} us")
        return sum(gaps) / n

    m0 = one_round("idle", n)
    stop = threading.Event()

    def busy():
        x = 0
        while not stop.is_set():
            x = sum(range(2000))
    ths = [threading.Thread(target=busy, daemon=True) for _ in range(4)]
    for t in ths:
        t.start()
    m1 = one_round("4 busy threads", n // 4)
    stop.set()
    print(f"P(burst lands in W | burst uniform over one 0.5 s poll) ~= mean W / 0.5 s: "
          f"idle {m0 / 0.5:.1e}, busy {m1 / 0.5:.1e}")


def req(payload):
    return types.SimpleNamespace(payload=payload,
                                 get_header=lambda k, d=None: FQCN if k == MessageHeaderKey.ORIGIN else d)


def burst(be):
    r1 = be._handle_result_source_settled(req({MsgKey.SESSION_ID: "s1", MsgKey.TASK_ID: "A"}))
    sh = Shareable()
    sh["w"] = LazyDownloadRef(fqcn=FQCN, ref_id="refB", item_id="T0")
    r2 = be._handle_result_ready(req({MsgKey.SESSION_ID: "s1", MsgKey.TASK_ID: "B", MsgKey.RESULT: sh,
                                      MsgKey.RESULT_ID: "rB", MsgKey.ATTEMPT_ID: "aB"}))
    return r1, r2


def one_trial(rng, hb=1.0, forced=False):
    tr, be, rec = make(hb)
    if forced:                                   # positive control only: burst runs right after the stale read
        def silent_for(tr=tr, be=be, fired=[]):
            v = CellSession.silent_for(tr)
            if v is not None and v > hb and not fired:
                fired.append(1)
                rec.forced = burst(be)
            return v
        tr.peer_silent_for = silent_for
    task_b = CellTask("B")
    task_b.result_receiver_ids = ("server.job1",)
    be._current_task = task_b                    # task B admitted and waiting for its result
    tr.touch()                                   # last message from the trainer
    t0 = time.monotonic()
    time.sleep(rng.uniform(0.0, 0.5))            # monitor start phase (A's result was accepted earlier)
    mon = threading.Thread(target=be._monitor_accepted_result_source, args=(tr, "A"), daemon=True)
    mon.start()
    t_burst = time.perf_counter()
    if forced:
        mon.join(hb + 2.0)
        r1, r2 = rec.forced
    else:
        burst_at = t0 + hb + rng.uniform(0.0, 0.5)   # trainer resumes within the poll after the timeout
        time.sleep(max(0.0, burst_at - time.monotonic()))
        t_burst = time.perf_counter()
        r1, r2 = burst(be)
        mon.join(2.0)
    tr._cleaned = True                           # stop B's monitor
    SINKS.pop(id(be._cell), None)
    replies = [(r.payload or {}).get(MsgKey.REPLY_TOPIC) for r in (r1, r2)]
    if rec.notices:
        kind = "loud_fail_A"                     # monitor fired before the burst: refA failure notice
    elif rec.stops:
        kind = "H03_stop_after_settle"
    else:
        kind = "normal"
    return dict(kind=kind, stops=[(round((s - t_burst) * 1e6, 1), tid) for s, tid in rec.stops],
                notices=rec.notices, job_failed=bool(rec.failed), replies=replies)


def worker(seconds, pairs, seed, busy):
    end = time.monotonic() + seconds
    stop = threading.Event()

    def spin():
        while not stop.is_set():
            sum(range(2000))
    for _ in range(busy):
        threading.Thread(target=spin, daemon=True).start()
    counts, examples, lock = {}, [], threading.Lock()

    def pair(i):
        rng = random.Random(seed * 1000 + i)
        while time.monotonic() < end:
            r = one_trial(rng)
            with lock:
                counts[r["kind"]] = counts.get(r["kind"], 0) + 1
                if r["kind"].startswith("H03") and len(examples) < 5:
                    examples.append(r)
    ths = [threading.Thread(target=pair, args=(i,)) for i in range(pairs)]
    for t in ths:
        t.start()
    for t in ths:
        t.join()
    stop.set()
    print(json.dumps({"counts": counts, "examples": examples}), flush=True)


def run(seconds, procs, pairs, busy):
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    ps = [subprocess.Popen([sys.executable, "-B", __file__, "worker", str(seconds), str(pairs),
                            str(random.randrange(1 << 20)), str(busy)], stdout=subprocess.PIPE, text=True, env=env, cwd=TMP)
          for _ in range(procs)]
    total, ex = {}, []
    for p in ps:
        out = p.communicate()[0].strip().splitlines()
        if out:
            d = json.loads(out[-1])
            for k, v in d["counts"].items():
                total[k] = total.get(k, 0) + v
            ex += d["examples"]
    n = sum(total.values())
    print(f"natural trials: {n} ({procs} procs x {pairs} concurrent pairs x {seconds}s, {busy} busy threads/proc) "
          f"outcomes={total}")
    for e in ex[:5]:
        print("  H03 example:", json.dumps(e))
    h = sum(v for k, v in total.items() if k.startswith("H03"))
    print(f"H03 rate per conditioned episode: {h}/{n}" + (f" = {h / n:.1e}" if h else
          f" (95% upper bound {3.0 / n:.1e})"))


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "measure"
    if cmd == "measure":
        measure(int(sys.argv[2]) if len(sys.argv) > 2 else 20000)
    elif cmd == "run":
        run(float(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]) if len(sys.argv) > 5 else 0)
    elif cmd == "selftest":                      # forced alignment: the classifier must report H03
        print("forced positive control:", json.dumps(one_trial(random.Random(1), forced=True)))
        print("unforced trial:", json.dumps(one_trial(random.Random(2))))
    elif cmd == "worker":
        worker(float(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]))
