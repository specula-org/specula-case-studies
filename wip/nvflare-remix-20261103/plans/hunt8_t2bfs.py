import runpy
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
PLAN = [dict(p, name=p["name"] + "_bfs") for p in runpy.run_path(str(ROOT / "plans" / "hunt8.py"))["PLAN"] if p["name"] == "h8D_t2_s2l1a1"]
