import sys, json
sys.path.insert(0, "/home/ubuntu/nvflare-remix-20261103/scripts")
import mkmc, run_mc
from concurrent.futures import ThreadPoolExecutor
G = ["JobSP", "JobCP", "RunCJ", "TaskCJ", "Trainer", "PaySrc", "PayRcv", "CommSJ", "WfSJ"]
def grain(fine): g = {k: ("F" if k in fine else "C") for k in G}; g["Net"] = "R"; return g
common = dict(sites=1, launch=1, attempt=1, inv=["GFinishedNoPanic"], prop=[], extends=("Mix", "Props", "GenericProps"),
              deadlock=False)
mkmc.build("l13_jobspF_k3", grain=grain(["JobSP"]), faults=["statusLost", "deadClient"], rarity=3, **common)
mkmc.build("l13_jobspF_ctl", grain=grain(["JobSP"]), faults=["deadClient"], rarity=3, **common)
mkmc.build("l13_allC_k3", grain=grain([]), faults=["statusLost", "deadClient"], rarity=3, **common)
with ThreadPoolExecutor(3) as ex:
    fs = {n: ex.submit(run_mc.run, n, 900, 10, "bfs", (0, 0), "16g") for n in ["l13_jobspF_k3", "l13_jobspF_ctl", "l13_allC_k3"]}
    for n, f in fs.items():
        r = f.result(); r.pop("cfg", None); print(json.dumps({k: r.get(k) for k in ["name", "result", "violated", "depth", "distinct", "distinct_at_stop", "wall_seconds"]}), flush=True)
