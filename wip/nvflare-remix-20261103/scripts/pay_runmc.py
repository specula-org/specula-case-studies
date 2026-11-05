#!/usr/bin/env python3
"""Run existing checks/mixes/MC_NAME like run_mc.py, but kill the JVM's process
group on timeout (run_mc.py leaves the JVM running and then blocks on its pipes).
pay_runmc.py NAME [NAME...] [--timeout S] [--workers N] [--heap H] [--sim DEPTH]
Writes checks/results/NAME.json (run_mc format) and logs/NAME.log."""
import argparse, json, os, re, signal, subprocess, sys, time
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import run_mc  # noqa: E402


def run(name, timeout, workers, heap, sim):
    mod = f"MC_{name}"
    env = dict(os.environ, TLC_WORKERS=str(workers), TLC_HEAP=heap)
    extra = ["-simulate", "num=100000000", "-depth", str(sim)] if sim else []
    logf = ROOT / "logs" / f"{name}.log"
    t0 = time.time()
    with open(logf, "w") as fh:
        p = subprocess.Popen([str(ROOT / "scripts" / "tlc.sh"), "tlc", str(run_mc.MIX), mod, f"{mod}.cfg"] + extra,
                             stdout=fh, stderr=subprocess.STDOUT, env=env, start_new_session=True)
        try:
            p.wait(timeout=timeout); to = False
        except subprocess.TimeoutExpired:
            to = True
            os.killpg(p.pid, signal.SIGTERM)
            try:
                p.wait(timeout=30)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, signal.SIGKILL); p.wait()
    out = logf.read_text()
    r = run_mc.parse(out)
    if to and r.get("result") != "violation":
        r["result"] = "budget_stopped"
        m = re.findall(r"([\d,]+) distinct states found", out)
        if m:
            r["distinct_at_stop"] = int(m[-1].replace(",", ""))
    r.update(name=name, mode="sim" if sim else "bfs", wall_seconds=round(time.time() - t0, 1),
             timeout=timeout, workers=workers, cfg=(run_mc.MIX / f"{mod}.cfg").read_text())
    (run_mc.RES / f"{name}.json").write_text(json.dumps(r, indent=1))
    print(json.dumps({k: v for k, v in r.items() if k != "cfg"}))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("names", nargs="+")
    ap.add_argument("--timeout", type=int, default=600)
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--heap", default="8g")
    ap.add_argument("--sim", type=int, default=0)
    a = ap.parse_args()
    for n in a.names:
        run(n, a.timeout, a.workers, a.heap, a.sim)


if __name__ == "__main__":
    main()
