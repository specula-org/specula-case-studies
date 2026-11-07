import sys, json
sys.path.insert(0, "/home/ubuntu/nvflare-remix-20261103/scripts")
import mkmc, run_mc
from concurrent.futures import ThreadPoolExecutor
G = ["JobSP", "JobCP", "RunCJ", "TaskCJ", "Trainer", "PaySrc", "PayRcv", "CommSJ", "WfSJ", "Reg"]
def grain(over): g = {k: "C" for k in G}; g.update(over); g["Net"] = "R"; return g
mkmc.build("fin_l13_jobspF", grain=grain({"JobSP": "F"}), faults=["statusLost", "deadClient"], rarity=4, sites=1, launch=1, attempt=1,
           inv=["GFinishedNoPanic"], prop=[], extends=("Mix", "Props", "GenericProps"), deadlock=False)
mkmc.build("fin_l13_allC", grain=grain({}), faults=["statusLost", "deadClient"], rarity=4, sites=1, launch=1, attempt=1,
           inv=["GFinishedNoPanic"], prop=[], extends=("Mix", "Props", "GenericProps"), deadlock=False)
mkmc.build("fin_t2_regF", grain=grain({"Reg": "F"}), faults=["deadClient"], rarity=3, sites=2, launch=1, attempt=1,
           inv=["GCleanupThreadAlive"], prop=[], extends=("Mix", "Props", "GenericProps"), deadlock=False)
with ThreadPoolExecutor(3) as ex:
    fs = {n: ex.submit(run_mc.run, n, 900, 10, "bfs", (0, 0), "16g") for n in ["fin_l13_jobspF", "fin_l13_allC", "fin_t2_regF"]}
    for n, f in fs.items():
        r = f.result(); print(json.dumps({k: r.get(k) for k in ("name", "result", "violated", "depth", "distinct", "distinct_at_stop")}), flush=True)
