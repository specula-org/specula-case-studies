# final plan, D track only (all 12 rediscovery regressions), after the T4 fix
import runpy
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
PLAN = [dict(p, name=p["name"] + "_final") for p in runpy.run_path(str(ROOT / "plans" / "hunt8.py"))["PLAN"] if p["track"] == "D"]
