# final-model reconfirmation of T2 and L13 (two 900 s D runs each)
import runpy
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
base = [p for p in runpy.run_path(str(ROOT / "plans" / "hunt8.py"))["PLAN"] if p["name"] in ("h8D_t2_s2l1a1", "h8D_l13_s1l1a1")]
PLAN = [dict(p, name=f"{p['name']}_fin{i}") for p in base for i in (1, 2)]
