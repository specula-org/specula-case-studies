import os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
ROOT = "/home/ubuntu/nvflare-remix-20261103"
sys.path.insert(0, f"{ROOT}/scripts")
import run_mc
ENV = dict(os.environ, MIX_INCLUDE_WIP="all")
def tv(name, grain):
    subprocess.run(["python3", "scripts/gen_trace.py", name] + (["--grain", grain] if grain else []), capture_output=True, cwd=ROOT, env=ENV)
    t = open(f"{ROOT}/checks/trace/TraceMix_{name}.tla").read().replace(f"MODULE TraceMix_{name}", f"MODULE MC_TraceMix_{name}Tm")
    open(f"{ROOT}/checks/mixes/MC_TraceMix_{name}Tm.tla", "w").write(t)
    open(f"{ROOT}/checks/mixes/MC_TraceMix_{name}Tm.cfg", "w").write(open(f"{ROOT}/checks/trace/TraceMix_{name}.cfg").read())
    r = run_mc.run(f"TraceMix_{name}Tm", 1200, 12, "sim", (2000, 10**9), "16g")
    return f"TV {name}: {'TRACE ACCEPTED' if r.get('violated') == 'TraceNotAccepted' else 'NOT ACCEPTED ' + str(r.get('result'))} {r.get('wall_seconds')} s"
with ThreadPoolExecutor(2) as ex:
    for f in [ex.submit(tv, "allF", "JobSP=F,JobCP=F,RunCJ=F,TaskCJ=F,Trainer=F,PaySrc=F,PayRcv=F,CommSJ=F,WfSJ=F,Reg=F,Net=R"), ex.submit(tv, "allC", "")]:
        print(f.result(), flush=True)
