import runpy
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
PLAN = [dict(p, name=p["name"] + "_long") for p in runpy.run_path(str(ROOT / "plans" / "hunt8.py"))["PLAN"] if "c1bmulti" in p["name"]]
