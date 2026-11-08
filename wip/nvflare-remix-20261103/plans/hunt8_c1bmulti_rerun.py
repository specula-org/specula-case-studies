# two independent reruns of the C1-B cross-job regression on the current spec (after h8post missed once)
import runpy
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
base = [p for p in runpy.run_path(str(ROOT / "plans" / "hunt8.py"))["PLAN"] if p["name"] == "h8D_c1bmulti_s1l1a1"][0]
PLAN = [dict(base, name=base["name"] + s) for s in ("_rr1", "_rr2")]
