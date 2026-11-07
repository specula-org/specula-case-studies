# rerun after v9 fixes (completion stops at ask_to_stop, SP-exit stutter, stronger S1-free constraint)
import runpy
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
KEEP = {"h9B_sim_s1", "h9B_sim_s1_noS1", "h9B_sim_s2", "h9B_sim_s2_noS1", "h9B_bfs_s1_slowNoS1", "h9B_bfs_s2_slowNoS1"}
PLAN = [dict(p, name=p["name"] + "_r4") for p in runpy.run_path(str(ROOT / "plans" / "hunt9_B.py"))["PLAN"] if p["name"] in KEEP]
