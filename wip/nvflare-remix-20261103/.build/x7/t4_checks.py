import os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
ROOT = "/home/ubuntu/nvflare-remix-20261103"
sys.path.insert(0, f"{ROOT}/scripts")
import run_mc
ENV = dict(os.environ, MIX_INCLUDE_WIP="all")
def ref(args, tag):
    out = subprocess.run(["python3", "scripts/gen_ref.py"] + args + ["--run", "--tag", tag], capture_output=True, text=True, env=ENV, cwd=ROOT).stdout
    return tag + ": " + " | ".join(l for l in out.splitlines() if "receipt" in l or "'result'" in l or "rror" in l)[-300:]
def tv(name, grain):
    args = ["python3", "scripts/gen_trace.py", name] + (["--grain", grain] if grain else [])
    subprocess.run(args, capture_output=True, cwd=ROOT, env=ENV)
    t = open(f"{ROOT}/checks/trace/TraceMix_{name}.tla").read().replace(f"MODULE TraceMix_{name}", f"MODULE MC_TraceMix_{name}T4")
    open(f"{ROOT}/checks/mixes/MC_TraceMix_{name}T4.tla", "w").write(t)
    open(f"{ROOT}/checks/mixes/MC_TraceMix_{name}T4.cfg", "w").write(open(f"{ROOT}/checks/trace/TraceMix_{name}.cfg").read())
    r = run_mc.run(f"TraceMix_{name}T4", 1200, 12, "sim", (2000, 10**9), "16g")
    return f"TV {name}: {'TRACE ACCEPTED' if r.get('violated') == 'TraceNotAccepted' else 'NOT ACCEPTED ' + str(r.get('result'))} {r.get('wall_seconds')} s"
with ThreadPoolExecutor(4) as ex:
    fs = [ex.submit(ref, ["CommSJ", "F", "C", "--sites", "2", "--faults", "cjCrash,deadClient,taskTimeout,rpcTimeout,slowFinalize", "--timeout", "900", "--workers", "16"], "t4a"),
          ex.submit(ref, ["CommSJ", "F", "C", "--sites", "2", "--faults", "cjCrash,deadClient", "--negative", "--timeout", "300", "--workers", "8"], "t4an"),
          ex.submit(tv, "allF", "JobSP=F,JobCP=F,RunCJ=F,TaskCJ=F,Trainer=F,PaySrc=F,PayRcv=F,CommSJ=F,WfSJ=F,Reg=F,Net=R"),
          ex.submit(tv, "allC", "")]
    for f in fs: print(f.result(), flush=True)
