#!/usr/bin/env python3
"""Shortest fault-free path to a milestone (BFS, invariant ~milestone)."""
import sys, os, subprocess, signal, re
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import mkmc
G = ["JobSP", "JobCP", "RunCJ", "TaskCJ", "Trainer", "PaySrc", "PayRcv", "CommSJ", "WfSJ"]
tag, gr, sites, secs, workers, ms = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]), sys.argv[6]
grain = {k: gr for k in G}; grain["Net"] = "R"
MS = {"term": "~Terminal", "running": 'pJobSP.status /= "RUNNING"'}
out_dir, mod, _ = mkmc.build(f"x7s_{tag}", grain=grain, faults=[], sites=sites, launch=1, attempt=1,
                             inv=["NotMS"], prop=[], extends=("Mix", "Props", "GenericProps"), deadlock=True,
                             known=True, extra_defs=f"NotMS == {MS[ms]}")
env = dict(os.environ, TLC_WORKERS=str(workers), TLC_HEAP="24g")
p = subprocess.Popen([str(ROOT / "scripts/tlc.sh"), "tlc", str(out_dir), mod, f"{mod}.cfg"],
                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env, start_new_session=True)
try:
    out, _ = p.communicate(timeout=secs)
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGTERM); out, _ = p.communicate(timeout=60)
(ROOT / ".build/x7" / f"s_{tag}.log").write_text(out)
steps = re.findall(r"^State (\d+):", out, re.M)
prog = re.findall(r"Progress\((\d+)\).*?([\d,]+) distinct", out)
print(tag, "violated" if "is violated" in out else "NOT reached", "path_len", steps[-1] if steps else None,
      "last progress depth/distinct", prog[-1] if prog else None)
