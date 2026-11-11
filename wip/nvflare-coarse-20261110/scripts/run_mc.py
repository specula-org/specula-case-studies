#!/usr/bin/env python3
"""Run TLC on generated MC modules and record a JSON receipt per run.

run_mc.py NAME [NAME...] [--timeout S] [--workers N] [--mode bfs|sim] [--depth D]
Results: checks/results/NAME.json, logs/NAME.log
"""
import argparse, json, os, re, subprocess, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MIX = ROOT / "checks" / "mixes"
RES = ROOT / "checks" / "results"
LOG = ROOT / "logs"


def parse(out):
    r = {}
    m = re.findall(r"([\d,]+) states generated, ([\d,]+) distinct states found, ([\d,]+) states left", out)
    if m:
        g, d, q = m[-1]
        r.update(generated=int(g.replace(",", "")), distinct=int(d.replace(",", "")),
                 queue=int(q.replace(",", "")))
    m = re.findall(r"Progress: ([\d,]+) states checked, ([\d,]+) traces generated \(trace length: mean=(\d+)", out)
    if m:   # simulation statistics
        s, t, ml = m[-1]
        r.update(sim_states=int(s.replace(",", "")), traces=int(t.replace(",", "")), trace_mean=int(ml))
    m = re.search(r"depth of the complete state graph search is (\d+)", out)
    if m:
        r["depth"] = int(m.group(1))
    m = re.search(r"Invariant (\w+) is violated", out)
    if m:
        r["violated"] = m.group(1)
    m = re.search(r"Action property (\w+) (?:of|is violated)", out)
    if m:
        r["violated"] = r.get("violated") or m.group(1)
    elif re.search(r"Temporal properties were violated", out):
        r["violated"] = r.get("violated") or "temporal"
    m = re.search(r"Property (\w+) is violated", out)
    if m:
        r["violated"] = r.get("violated") or m.group(1)
    m = re.search(r"Evaluating invariant (\w+) failed", out)
    if m and "violated" not in r:
        # TLC sometimes throws while evaluating an invariant exactly at a violating
        # state (seen with record-field checks on PayRcv ports); the trace is kept
        # and must be inspected (scripts/ce.py) -- reported separately.
        r["violated"] = m.group(1); r["eval_error"] = True
    if "Error: Deadlock reached." in out and "violated" not in r:
        r["violated"] = "Deadlock"
    if "Model checking completed. No error has been found." in out:
        r["result"] = "pass_exhaustive"
    elif "violated" in r:
        r["result"] = "violation_evalerror" if r.get("eval_error") else "violation"
    elif re.search(r"Error:|Exception|\*\*\* Errors", out):
        r["result"] = "error"
    else:
        r["result"] = "incomplete"
    m = re.search(r"Finished in (.*?) at", out)
    if m:
        r["tlc_time"] = m.group(1)
    if r.get("result") == "violation":
        i = out.find("Error: The behavior up to this point is:")
        if i < 0:
            i = out.find("is violated")
        r["trace_excerpt_chars"] = len(out) - i
    return r


def run(name, timeout, workers, mode, depth, heap):
    LOG.mkdir(exist_ok=True); RES.mkdir(parents=True, exist_ok=True)
    mod = f"MC_{name}"
    extra = []
    if mode == "sim":
        extra = ["-simulate", f"num={depth[1]}", "-depth", str(depth[0])]
    env = dict(os.environ, TLC_WORKERS=str(workers), TLC_HEAP=heap)
    t0 = time.time()
    import signal
    p = subprocess.Popen([str(ROOT / "scripts" / "tlc.sh"), "tlc", str(MIX), mod, f"{mod}.cfg"] + extra,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env,
                         start_new_session=True)
    try:
        out, _ = p.communicate(timeout=timeout)
        timed_out = False
    except subprocess.TimeoutExpired:
        # stop this run's own process group (tlc.sh + its JVM) so it cannot linger
        try:
            os.killpg(p.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            out, _ = p.communicate(timeout=30)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL); out, _ = p.communicate()
        timed_out = True
    (LOG / f"{name}.log").write_text(out)
    r = parse(out)
    if timed_out and r.get("result") != "violation":
        r["result"] = "budget_stopped"
        m = re.findall(r"Progress\(\d+\).*?([\d,]+) states generated.*?([\d,]+) distinct states found.*?([\d,]+) states left", out)
        if m:
            r["distinct_at_stop"] = int(m[-1][1].replace(",", ""))
    if "Exception in thread" in out and r.get("result") not in ("violation", "violation_evalerror"):
        # a TLC worker died (e.g. while reconstructing a violating trace in
        # simulation): the run found something it could not report -- never
        # count it as a clean budget stop
        r["result"] = "worker_exception"
    r.update(name=name, mode=mode, wall_seconds=round(time.time() - t0, 1), timeout=timeout,
             workers=workers, cfg=(MIX / f"{mod}.cfg").read_text())
    (RES / f"{name}.json").write_text(json.dumps(r, indent=1))
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("names", nargs="+")
    ap.add_argument("--timeout", type=int, default=600)
    ap.add_argument("--workers", type=int, default=16)
    ap.add_argument("--mode", default="bfs")
    ap.add_argument("--depth", default="200,20000")
    ap.add_argument("--heap", default="8g")
    a = ap.parse_args()
    d = tuple(int(x) for x in a.depth.split(","))
    for n in a.names:
        r = run(n, a.timeout, a.workers, a.mode, d, a.heap)
        print(json.dumps({k: v for k, v in r.items() if k != "cfg"}))


if __name__ == "__main__":
    main()
