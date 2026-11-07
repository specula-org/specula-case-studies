# v9 shutdown model: JobSP F->C refinement (with/without multiJob, negative control) and TV regressions
import os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
ROOT = "/home/ubuntu/nvflare-remix-20261103"
sys.path.insert(0, ROOT + "/scripts")
import run_mc
def ref(args, tag):
    env = dict(os.environ, MIX_INCLUDE_WIP="all")
    out = subprocess.run(["python3", f"{ROOT}/scripts/gen_ref.py"] + args + ["--run", "--tag", tag], capture_output=True, text=True, env=env, cwd=ROOT).stdout
    return tag + ": " + " | ".join(l for l in out.splitlines() if "receipt" in l or "'result'" in l or "rror" in l)[-400:]
def tv(name, grain, timeout):
    subprocess.run(["python3", "scripts/gen_trace.py", name, "--grain", grain], cwd=ROOT, capture_output=True)
    t = open(f"{ROOT}/checks/trace/TraceMix_{name}.tla").read().replace(f"MODULE TraceMix_{name}", f"MODULE MC_TraceMix_{name}V9")
    open(f"{ROOT}/checks/mixes/MC_TraceMix_{name}V9.tla", "w").write(t)
    open(f"{ROOT}/checks/mixes/MC_TraceMix_{name}V9.cfg", "w").write(open(f"{ROOT}/checks/trace/TraceMix_{name}.cfg").read())
    r = run_mc.run(f"TraceMix_{name}V9", timeout, 12, "sim", (2000, 10**9), "16g")
    return f"TV {name}: {r.get('result')} {r.get('violated')} {r.get('wall_seconds')}"
SF = "spShutdown,slowShutdownAbort,deleteJob,abort,storeError,rpcTimeout"
ALLF = "JobSP=F,JobCP=F,RunCJ=F,TaskCJ=F,Trainer=F,PaySrc=F,PayRcv=F,CommSJ=F,WfSJ=F,Reg=F,Net=R"
ALLC = "JobSP=C,JobCP=C,RunCJ=C,TaskCJ=C,Trainer=C,PaySrc=C,PayRcv=C,CommSJ=C,WfSJ=C,Reg=C,Net=R"
with ThreadPoolExecutor(5) as ex:
    fs = [ex.submit(ref, ["JobSP", "F", "C", "--sites", "1", "--faults", SF, "--profile", "multiJob", "--timeout", "900", "--workers", "16"], "sd1"),
          ex.submit(ref, ["JobSP", "F", "C", "--sites", "1", "--faults", SF + ",spCrash", "--timeout", "900", "--workers", "12"], "sd0"),
          ex.submit(ref, ["JobSP", "F", "C", "--sites", "1", "--faults", SF, "--profile", "multiJob", "--negative", "--timeout", "600", "--workers", "4"], "sd1n"),
          ex.submit(tv, "allF", ALLF, 1200), ex.submit(tv, "allC", ALLC, 900)]
    for f in fs: print(f.result(), flush=True)
