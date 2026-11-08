# v10 regression on the non-taskMode spec: all D-track rediscoveries + one S-track smoke per family
import runpy
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
P8 = runpy.run_path(str(ROOT / "plans" / "hunt8.py"))["PLAN"]
D = [dict(p, name=p["name"] + "_v10") for p in P8 if p["track"] == "D"]
S = [dict(p, name=p["name"] + "_v10") for p in P8 if p["track"] == "S" and p["name"].endswith("_fam_s2l2a2")]
PLAN = D + S
