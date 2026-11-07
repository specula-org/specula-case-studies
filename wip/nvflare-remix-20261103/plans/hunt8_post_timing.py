# multiJob smoke and cross-job regressions on the spec after the Timing refactor
import runpy
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
KEEP = {"h8S_multi_fam_s1l2a2", "h8S_multi_fam_s2l2a2", "h8S_multi_allF_s2l2a2",
        "h8C_multi_p2_k1", "h8C_multi_p5_k1",
        "h8D_c1bmulti_s1l1a1", "h8D_del_s1l2a2", "h8D_job_s1l2a2"}
PLAN = [dict(p, name=p["name"] + "_pt") for p in runpy.run_path(str(ROOT / "plans" / "hunt8.py"))["PLAN"] if p["name"] in KEEP]
assert len(PLAN) == len(KEEP)
