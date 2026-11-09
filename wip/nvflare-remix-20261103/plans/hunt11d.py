# v11: one continuous 90-minute fused simulation on the Swarm family (all swarm faults + cjCrash),
# same property set and filters as hunt11.
import runpy
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
P = runpy.run_path(str(ROOT / "plans" / "hunt11.py"))["PLAN"]
base = [p for p in P if p["name"] == "h11_swarm_s2l2a2"][0]
PLAN = [dict(base, name="h11d_swarm_90min", timeout=5400, workers=24, heap="32g")]
