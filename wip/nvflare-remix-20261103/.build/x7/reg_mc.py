import sys, json
sys.path.insert(0, "/home/ubuntu/nvflare-remix-20261103/scripts")
import mkmc, run_mc
from concurrent.futures import ThreadPoolExecutor
G = ["JobSP", "JobCP", "RunCJ", "TaskCJ", "Trainer", "PaySrc", "PayRcv", "CommSJ", "WfSJ", "Reg"]
def grain(fine): g = {k: ("F" if k in fine else "C") for k in G}; g["Net"] = "R"; return g
common = dict(sites=2, launch=1, attempt=1, inv=["GCleanupThreadAlive"], prop=[], extends=("Mix", "Props", "GenericProps"),
              deadlock=False, symmetry=True)
mkmc.build("reg_t2_F", grain=grain(["Reg"]), faults=["deadClient"], rarity=3, **common)
mkmc.build("reg_t3_F", grain=grain(["Reg"]), faults=["deadClient", "jobExitRace"], rarity=4, profile=["otherJob"], **common)
mkmc.build("reg_t2_allC", grain=grain([]), faults=["deadClient"], rarity=3, **common)
with ThreadPoolExecutor(3) as ex:
    fs = {n: ex.submit(run_mc.run, n, 600, 8, "bfs", (0, 0), "12g") for n in ["reg_t2_F", "reg_t3_F", "reg_t2_allC"]}
    for n, f in fs.items():
        r = f.result(); r.pop("cfg", None)
        print(json.dumps({k: r.get(k) for k in ["name", "result", "violated", "depth", "distinct", "distinct_at_stop", "wall_seconds"]}), flush=True)
