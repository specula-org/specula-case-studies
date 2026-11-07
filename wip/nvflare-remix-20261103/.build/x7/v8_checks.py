import sys, json, subprocess, os
sys.path.insert(0, "/home/ubuntu/nvflare-remix-20261103/scripts")
import mkmc, run_mc
from concurrent.futures import ThreadPoolExecutor
ROOT = "/home/ubuntu/nvflare-remix-20261103"
G = ["JobSP", "JobCP", "RunCJ", "TaskCJ", "Trainer", "PaySrc", "PayRcv", "CommSJ", "WfSJ", "Reg"]
def grain(fine): g = {k: ("F" if k in fine else "C") for k in G}; g["Net"] = "R"; return g
common = dict(sites=1, launch=1, attempt=1, prop=[], extends=("Mix", "Props", "GenericProps"), deadlock=True, known=False)
mkmc.build("v8_r2", grain=grain(["Reg", "CommSJ", "JobCP"]), faults=["cpCrash", "rpcTimeout"], inv=["GCleanupThreadAlive"], **common)
mkmc.build("v8_r2ctl", grain=grain(["Reg", "CommSJ", "JobCP"]), faults=["cjCrash", "rpcTimeout"], inv=["GCleanupThreadAlive"], **common)
def ref(args, tag):
    env = dict(os.environ, MIX_INCLUDE_WIP="all")
    out = subprocess.run(["python3", f"{ROOT}/scripts/gen_ref.py"] + args + ["--run", "--tag", tag], capture_output=True, text=True, env=env, cwd=ROOT).stdout
    return tag + ": " + " | ".join(l for l in out.splitlines() if "receipt" in l or "'result'" in l)[-400:]
def tv():
    out = subprocess.run(["python3", "-c", "import sys; sys.path.insert(0,'scripts'); import run_mc, json; r=run_mc.run('TraceMix_allF8', 1200, 16, 'sim', (2000, 10**9), '16g'); print(r.get('result'), r.get('violated'), r.get('wall_seconds'))"],
                         capture_output=True, text=True, cwd=ROOT).stdout
    return "TV allF: " + out.strip()
subprocess.run(["python3", "scripts/gen_trace.py", "allF", "--grain", "JobSP=F,JobCP=F,RunCJ=F,TaskCJ=F,Trainer=F,PaySrc=F,PayRcv=F,CommSJ=F,WfSJ=F,Reg=F,Net=R"], cwd=ROOT, capture_output=True)
t = open(f"{ROOT}/checks/trace/TraceMix_allF.tla").read().replace("MODULE TraceMix_allF", "MODULE MC_TraceMix_allF8")
open(f"{ROOT}/checks/mixes/MC_TraceMix_allF8.tla", "w").write(t)
open(f"{ROOT}/checks/mixes/MC_TraceMix_allF8.cfg", "w").write(open(f"{ROOT}/checks/trace/TraceMix_allF.cfg").read())
with ThreadPoolExecutor(5) as ex:
    fs = [ex.submit(ref, ["Reg", "F", "C", "--sites", "2", "--faults", "deadClient,jobExitRace,cpCrash,cjCrash,rpcTimeout", "--profile", "otherJob", "--timeout", "900", "--workers", "16"], "v8b"),
          ex.submit(ref, ["CommSJ", "F", "C", "--sites", "2", "--faults", "cjCrash,deadClient,taskTimeout,rpcTimeout", "--timeout", "900", "--workers", "16"], "v8c"),
          ex.submit(lambda: json.dumps({k: v for k, v in run_mc.run("v8_r2", 900, 8, "bfs", (0, 0), "12g").items() if k in ("name", "result", "violated", "depth", "distinct", "distinct_at_stop")})),
          ex.submit(lambda: json.dumps({k: v for k, v in run_mc.run("v8_r2ctl", 900, 8, "bfs", (0, 0), "12g").items() if k in ("name", "result", "violated", "depth", "distinct", "distinct_at_stop")})),
          ex.submit(tv)]
    for f in fs:
        print(f.result(), flush=True)
