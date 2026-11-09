import runpy
P = runpy.run_path("/home/ubuntu/nvflare-remix-20261103/plans/hunt11.py")["PLAN"]
PLAN = [dict(p, name=p["name"] + "_try", timeout=60, workers=4) for p in P if not p["name"].endswith("_b")]
