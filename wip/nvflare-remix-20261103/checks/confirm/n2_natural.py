"""N2 under natural timing: how wide is the window in which a dead-client grace
expiry turns a completed workflow into a policy-violation panic?
Pinned source c411a201, read-only via sys.path.

n2_repro.py showed the mechanism with a 1 s stop_controller stub. Here the whole
end-of-workflow path is real: ServerRunner._execute_run (server_runner.py:
130-182) runs one workflow whose communicator is a real WFCommServer; its
control_flow returns at T_ret; the real finally block takes wf_lock, calls
stop_controller, then WFCommServer.finalize_run (wf_comm_server.py:1033-1046),
which holds _controller_lock while it runs _cleanup_inflight_tensor_downloads
(151-162: imports nvflare.app_opt.pt.tensor_downloader, i.e. torch) and only then
sets _all_done. The task monitor (_monitor_tasks, 1201-1213; period 0.2 s, the
WFCommServer default - Controller.set_communicator writes task_check_period, an
attribute the monitor never reads) runs _check_dead_clients and
_job_policy_violated, then check_tasks, which needs _controller_lock
(1215-1217). The dead-job report enters through the real
ServerRunner.handle_dead_job -> process_dead_client_report.

Stubs: the engine (two clients, job meta min_sites=2, event recorder), the
workflow's control_flow (returns at T_ret) and stop_controller (instant, like
ScatterAndGather.stop_controller, or a given delay). The grace period is the
config var dead_client_grace_period (default 60 s); it is compressed to 1 s so
each trial is short. This changes no decision logic: only the offset between
the grace expiry and T_ret matters, and the window width does not depend on
the grace length.

Natural premise: a client's death is reported at a random time; its grace
expiry lands uniformly in [T_ret - A, T_ret + A]. Outcomes per trial:
  abort-in-workflow  panic before T_ret (intended behavior: policy violated while running)
  N2                 panic at or after T_ret (workflow already returned)
  completed          no panic
Measured N2 window F = (N2 / trials) * 2A. For a client death uniformly
distributed over the last 60 s before the return (the only deaths that do not
already abort the workflow while it runs), P(N2) = F / 60 s.

Each trial runs in a fresh interpreter, so whether torch is installed decides
whether the first finalize_run pays a cold torch import (run this driver with
an interpreter that has torch to measure that case).

usage: n2_natural.py [trials] [A] [parallel] [stop_delay]
"""
import json, os, random, subprocess, sys, threading, time

SRC = "/home/ubuntu/nvflare-integrated-model-20261103/sources/current"
GRACE = 1.0


def worker(offset, stop_delay):
    sys.dont_write_bytecode = True
    sys.path.insert(0, SRC)
    import types
    from nvflare.apis.event_type import EventType
    from nvflare.apis.fl_constant import FLContextKey
    from nvflare.apis.fl_context import FLContextManager
    from nvflare.apis.impl.controller import Controller
    from nvflare.apis.impl.wf_comm_server import WFCommServer
    from nvflare.apis.job_def import JobMetaKey
    from nvflare.private.fed.server.server_runner import ServerRunner, ServerRunnerConfig

    events = []

    class Engine:
        def __init__(self):
            self.clients = [types.SimpleNamespace(name="site-1"), types.SimpleNamespace(name="site-2")]
            meta = {JobMetaKey.JOB_ID.value: "job1", JobMetaKey.JOB_NAME.value: "job1",
                    JobMetaKey.MIN_CLIENTS.value: 2, JobMetaKey.DEPLOY_MAP.value: {"app": ["@ALL"]}}
            self.mgr = FLContextManager(engine=self, identity_name="server", job_id="job1",
                                        private_stickers={FLContextKey.JOB_META: meta})

        def new_context(self):
            return self.mgr.new_context()

        def get_clients(self):
            return self.clients

        def fire_event(self, event_type, fl_ctx):
            events.append((time.time(), event_type))

        def register_aux_message_handler(self, topic, message_handle_func):
            pass

    eng = Engine()
    comm = WFCommServer()
    timeline = {}

    class Workflow(Controller):
        def start_controller(self, fl_ctx):
            comm._dead_client_grace = GRACE          # config var dead_client_grace_period, compressed

        def control_flow(self, abort_signal, fl_ctx):
            while time.time() < timeline["t_ret"] and not abort_signal.triggered:
                time.sleep(0.001)
            timeline["returned"] = time.time()

        def stop_controller(self, fl_ctx):
            if stop_delay:
                time.sleep(stop_delay)

        def process_result_of_unknown_task(self, *a, **k):
            pass

    ctl = Workflow()
    ctl.set_communicator(comm)
    wf = types.SimpleNamespace(id="wf", controller=ctl)
    cfg = ServerRunnerConfig(heartbeat_timeout=60, task_request_interval=1.0, workflows=[wf], task_data_filters={},
                             task_result_filters={}, handlers=[], components={})
    runner = ServerRunner(config=cfg, job_id="job1", engine=eng)
    t0 = time.time()
    timeline["t_ret"] = t0 + 2.0 + random.uniform(0.0, 0.2)   # random phase against the 0.2 s monitor tick
    t_report = timeline["t_ret"] - GRACE + offset

    def report():
        time.sleep(max(0.0, t_report - time.time()))
        with eng.new_context() as ctx:
            runner.handle_dead_job("site-2", ctx)        # SP's HANDLE_DEAD_JOB for site-2
        timeline["reported"] = time.time()

    threading.Thread(target=report, daemon=True).start()
    runner._execute_run()
    t_ret = timeline["returned"]
    panics = [t - t_ret for t, e in events if e == EventType.FATAL_SYSTEM_ERROR]
    ends = [t - t_ret for t, e in events if e == EventType.END_WORKFLOW]
    comm._task_monitor.join(timeout=2)
    return {"offset": offset, "report_err": timeline.get("reported", 0) - t_report,
            "panic_rel": panics[0] if panics else None, "finalized_rel": ends[0] if ends else None,
            "torch": "torch" in sys.modules}


def classify(r):
    if r["panic_rel"] is None:
        return "completed"
    return "abort-in-workflow" if r["panic_rel"] < 0 else "N2"


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 200
    a = float(sys.argv[2]) if len(sys.argv) > 2 else 0.5
    par = int(sys.argv[3]) if len(sys.argv) > 3 else 8
    stop_delay = float(sys.argv[4]) if len(sys.argv) > 4 else 0.0
    offsets = [random.uniform(-a, a) for _ in range(n)]
    results, running = [], []
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    while offsets or running:
        while offsets and len(running) < par:
            off = offsets.pop()
            running.append(subprocess.Popen([sys.executable, "-B", __file__, "--worker", repr(off), repr(stop_delay)],
                                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, text=True))
        time.sleep(0.05)
        for p in [p for p in running if p.poll() is not None]:
            running.remove(p)
            out = [ln for ln in p.stdout.read().splitlines() if ln.startswith("{")]
            if out:
                results.append(json.loads(out[-1]))
    counts = {k: sum(classify(r) == k for r in results) for k in ("abort-in-workflow", "N2", "completed")}
    n2 = sorted(r["offset"] for r in results if classify(r) == "N2")
    fin = sorted(r["finalized_rel"] for r in results if r["finalized_rel"] is not None)
    torch_loaded = sum(r["torch"] for r in results)
    width = counts["N2"] / len(results) * 2 * a
    print(f"interpreter={sys.executable}")
    print(f"trials={len(results)} A=+-{a}s stop_delay={stop_delay}s monitor period=0.2s grace(compressed)={GRACE}s "
          f"torch imported in {torch_loaded}/{len(results)} workers")
    print(f"outcomes: {counts}")
    print(f"finalize_run done after control_flow return: median {1000*fin[len(fin)//2]:.1f} ms, "
          f"max {1000*fin[-1]:.1f} ms")
    if n2:
        print(f"N2 expiry offsets (s after return): min {n2[0]:.3f} max {n2[-1]:.3f}")
    print(f"measured N2 window F = {1000*width:.1f} ms  ->  P(N2 | client death uniform in last 60 s) = "
          f"{width/60:.2e}")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--worker":
        print(json.dumps(worker(float(sys.argv[2]), float(sys.argv[3]))))
    else:
        main()
