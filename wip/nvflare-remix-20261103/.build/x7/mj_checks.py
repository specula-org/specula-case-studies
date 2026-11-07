import sys, json, subprocess, os
sys.path.insert(0, "/home/ubuntu/nvflare-remix-20261103/scripts")
import mkmc, run_mc
from concurrent.futures import ThreadPoolExecutor
ROOT = "/home/ubuntu/nvflare-remix-20261103"
G = ["JobSP", "JobCP", "RunCJ", "TaskCJ", "Trainer", "PaySrc", "PayRcv", "CommSJ", "WfSJ", "Reg"]
def grain(over): g = {k: "C" for k in G}; g.update(over); g["Net"] = "R"; return g
base = dict(sites=1, launch=1, attempt=1, prop=[], extends=("Mix", "Props", "GenericProps"), profile=["multiJob"])
B = {"mj_t1": dict(grain=grain({"JobSP": "F"}), faults=["deleteJob"], inv=["GSchedulerThreadAlive", "OurJobNotDeleted"], deadlock=False,
                   extra_defs="OurJobNotDeleted == TRUE"),
     "mj_c1b": dict(grain=grain({"JobSP": "F"}), faults=["storeError", "rpcTimeout"], inv=["GCompletionThreadAlive"], deadlock=True, known=False),
     "mj_c1b_hang": dict(grain=grain({"JobSP": "F"}), faults=["storeError", "rpcTimeout"], inv=[], deadlock=True, known=False),
     "mj_ok": dict(grain=grain({"JobSP": "F"}), faults=[], inv=["GSchedulerThreadAlive", "GCompletionThreadAlive"], deadlock=True, known=False)}
for n, kw in B.items(): mkmc.build(n, **base, **kw)
def ref(args, tag):
    env = dict(os.environ, MIX_INCLUDE_WIP="all")
    out = subprocess.run(["python3", f"{ROOT}/scripts/gen_ref.py"] + args + ["--run", "--tag", tag], capture_output=True, text=True, env=env, cwd=ROOT).stdout
    return tag + ": " + " | ".join(l for l in out.splitlines() if "receipt" in l or "'result'" in l or "rror" in l)[-350:]
def mc(n):
    r = run_mc.run(n, 900, 8, "bfs", (0, 0), "16g")
    return json.dumps({k: v for k, v in r.items() if k in ("name", "result", "violated", "depth", "distinct", "distinct_at_stop")})
def tv():
    subprocess.run(["python3", "scripts/gen_trace.py", "allF", "--grain", "JobSP=F,JobCP=F,RunCJ=F,TaskCJ=F,Trainer=F,PaySrc=F,PayRcv=F,CommSJ=F,WfSJ=F,Reg=F,Net=R"], cwd=ROOT, capture_output=True)
    t = open(f"{ROOT}/checks/trace/TraceMix_allF.tla").read().replace("MODULE TraceMix_allF", "MODULE MC_TraceMix_allF9")
    open(f"{ROOT}/checks/mixes/MC_TraceMix_allF9.tla", "w").write(t)
    open(f"{ROOT}/checks/mixes/MC_TraceMix_allF9.cfg", "w").write(open(f"{ROOT}/checks/trace/TraceMix_allF.cfg").read())
    r = run_mc.run("TraceMix_allF9", 1200, 12, "sim", (2000, 10**9), "16g")
    return "TV allF: " + str(r.get("result")) + " " + str(r.get("violated")) + " " + str(r.get("wall_seconds"))
with ThreadPoolExecutor(8) as ex:
    fs = [ex.submit(ref, ["JobSP", "F", "C", "--sites", "1", "--faults", "deleteJob,storeError,rpcTimeout,abort,spCrash", "--profile", "multiJob", "--timeout", "900", "--workers", "16"], "mj1"),
          ex.submit(ref, ["JobSP", "F", "C", "--sites", "1", "--faults", "deleteJob,rpcTimeout,storeError,deployError,abort,spCrash", "--timeout", "600", "--workers", "12"], "mj0"),
          ex.submit(tv)]
    fs += [ex.submit(mc, n) for n in B]
    for f in fs: print(f.result(), flush=True)
