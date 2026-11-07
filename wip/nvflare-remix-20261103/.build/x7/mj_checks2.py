import sys, json
sys.path.insert(0, "/home/ubuntu/nvflare-remix-20261103/scripts")
import mkmc, run_mc
from concurrent.futures import ThreadPoolExecutor
G = ["JobSP", "JobCP", "RunCJ", "TaskCJ", "Trainer", "PaySrc", "PayRcv", "CommSJ", "WfSJ", "Reg"]
def grain(over): g = {k: "C" for k in G}; g.update(over); g["Net"] = "R"; return g
base = dict(sites=1, launch=1, attempt=1, prop=[], extends=("Mix", "Props", "GenericProps"), profile=["multiJob"])
mkmc.build("mj_t1_j2", grain=grain({"JobSP": "F"}), faults=["deleteJob"], inv=["SchedAliveOrOursDeleted"], deadlock=False,
           extra_defs="SchedAliveOrOursDeleted == GSchedulerThreadAlive \\/ pJobSP.deleted", **base)
for T in (20, 50):
    mkmc.build(f"mj_c1b_sim_t{T}", grain=grain({"JobSP": "F", "JobCP": "F", "RunCJ": "F"}), faults=["storeError", "rpcTimeout", "abort", "cjCrash"],
               inv=["GCompletionThreadAlive"], deadlock=True, known=False, throttle=T, rarity=99, **base)
    mkmc.build(f"mj_c1b_hang_t{T}", grain=grain({"JobSP": "F", "JobCP": "F", "RunCJ": "F"}), faults=["storeError", "rpcTimeout", "abort", "cjCrash"],
               inv=[], deadlock=True, known=False, throttle=T, rarity=99,
               extra_defs="", **base)
jobs = [("mj_t1_j2", "bfs", 600)] + [(f"mj_c1b_sim_t{T}", "sim", 600) for T in (20, 50)] + [(f"mj_c1b_hang_t{T}", "sim", 600) for T in (20, 50)]
with ThreadPoolExecutor(5) as ex:
    fs = {n: ex.submit(run_mc.run, n, t, 8, m, (1500, 10**9) if m == "sim" else (0, 0), "12g") for n, m, t in jobs}
    for n, f in fs.items():
        r = f.result(); print(json.dumps({k: r.get(k) for k in ("name", "result", "violated", "depth", "distinct", "traces", "distinct_at_stop")}), flush=True)
