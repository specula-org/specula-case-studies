#!/usr/bin/env python3
"""Like run_mc.py, but streams TLC output to logs/NAME.log while it runs (so
progress is visible) and writes the same JSON receipt in checks/results/.

fed_run.py NAME [NAME...] [--timeout S] [--workers N] [--heap H] [--mode bfs|sim] [--depth D,N]
"""
import argparse, json, os, re, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import run_mc  # noqa: E402

MIX = ROOT / "checks" / "mixes"
RES = ROOT / "checks" / "results"
LOG = ROOT / "logs"


def run(name, timeout, workers, mode, depth, heap, xargs=()):
    LOG.mkdir(exist_ok=True); RES.mkdir(parents=True, exist_ok=True)
    mod = f"MC_{name}"
    extra = []
    if mode == "sim":
        extra = ["-simulate", f"num={depth[1]}", "-depth", str(depth[0])]
    extra += list(xargs)
    env = dict(os.environ, TLC_WORKERS=str(workers), TLC_HEAP=heap)
    t0 = time.time()
    logf = LOG / f"{name}.log"
    timed_out = False
    with open(logf, "w") as fh:
        p = subprocess.Popen([str(ROOT / "scripts" / "tlc.sh"), "tlc", str(MIX), mod, f"{mod}.cfg"] + extra,
                             stdout=fh, stderr=subprocess.STDOUT, env=env, start_new_session=True)
        try:
            p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            os.killpg(p.pid, 15)
            try:
                p.wait(timeout=30)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, 9)
    out = logf.read_text()
    r = run_mc.parse(out)
    if timed_out and r.get("result") != "violation":
        r["result"] = "budget_stopped"
        m = re.findall(r"([\d,]+) states generated.*?([\d,]+) distinct states found.*?([\d,]+) states left", out)
        if m:
            r["distinct_at_stop"] = int(m[-1][1].replace(",", ""))
    r.update(name=name, mode=mode, wall_seconds=round(time.time() - t0, 1), timeout=timeout,
             workers=workers, cfg=(MIX / f"{mod}.cfg").read_text())
    (RES / f"{name}.json").write_text(json.dumps(r, indent=1))
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("names", nargs="+")
    ap.add_argument("--timeout", type=int, default=600)
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--mode", default="bfs")
    ap.add_argument("--depth", default="200,20000")
    ap.add_argument("--heap", default="8g")
    ap.add_argument("--tlc", default="", help="extra TLC args, space separated")
    a = ap.parse_args()
    d = tuple(int(x) for x in a.depth.split(","))
    for n in a.names:
        r = run(n, a.timeout, a.workers, a.mode, d, a.heap, a.tlc.split())
        print(json.dumps({k: v for k, v in r.items() if k != "cfg"}), flush=True)


if __name__ == "__main__":
    main()
