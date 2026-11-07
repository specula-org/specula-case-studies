import sys, runpy
from pathlib import Path
ROOT = Path("/home/ubuntu/nvflare-remix-20261103"); sys.path.insert(0, str(ROOT / "scripts"))
import mkmc, hunt
plan = {p["name"]: p for p in runpy.run_path(str(ROOT / "plans/hunt6.py"))["PLAN"]}
for src in sys.argv[1:]:
    p = dict(plan[src]); kw = {k: p[k] for k in hunt.BUILD_KEYS if k in p}
    kw["extends"] = tuple(kw["extends"]); kw["fuse"] = True
    mkmc.build("x7f_" + src, **kw); print("built", src)
