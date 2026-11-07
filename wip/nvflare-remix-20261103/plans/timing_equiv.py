# Timing-module refactor equivalence: the four hunt8b C runs that completed exhaustively,
# rerun unchanged; their distinct-state counts must equal hunt8b's
import runpy
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
base = {p["name"]: p for p in runpy.run_path(str(ROOT / "plans" / "hunt8.py"))["PLAN"]}
PLAN = [dict(base[n], name=n + "_tm") for n in ["h8C_tail_p5_k1", "h8C_err_p5_k1", "h8C_status_p4_k1", "h8C_status_p5_k1"]]
