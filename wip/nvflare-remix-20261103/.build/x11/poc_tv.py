"""Replay the real POC trace on the regenerated TraceMix_allF / allC by simulation
(as in rounds 7-10, .build/x7/mj_checks.py)."""
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import run_mc
def go(name):
    t = (ROOT / f"checks/trace/TraceMix_{name}.tla").read_text().replace(f"MODULE TraceMix_{name}", f"MODULE MC_TraceMix_{name}V11")
    (ROOT / f"checks/mixes/MC_TraceMix_{name}V11.tla").write_text(t)
    (ROOT / f"checks/mixes/MC_TraceMix_{name}V11.cfg").write_text((ROOT / f"checks/trace/TraceMix_{name}.cfg").read_text())
    r = run_mc.run(f"TraceMix_{name}V11", 1200, 12, "sim", (2000, 10**9), "16g")
    acc = r.get("result") == "violation" and r.get("violated") == "TraceNotAccepted"
    return name, acc, {k: r.get(k) for k in ("result", "violated", "traces", "wall_seconds")}
with ThreadPoolExecutor(2) as ex:
    for res in ex.map(go, ["allF", "allC"]):
        print(res, flush=True)
