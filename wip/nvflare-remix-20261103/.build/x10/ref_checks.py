# v10 taskMode refinement: Worker F->C (+ negative), and the env groups whose taskMode branches changed
import os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
ROOT = "/home/ubuntu/nvflare-remix-20261103"
def ref(args, tag):
    env = dict(os.environ, MIX_INCLUDE_WIP="all")
    p = subprocess.run(["python3", f"{ROOT}/scripts/gen_ref.py"] + args + ["--run", "--tag", tag],
                       capture_output=True, text=True, env=env, cwd=ROOT)
    out = p.stdout + p.stderr
    return tag + ": " + " | ".join(l for l in out.splitlines() if "receipt" in l or "'result'" in l or "rror" in l)[-600:]
WF = "workerCrash,workerFail,ctrlLoss,taskDeadline,taskStageFail,settleTimeout,cjCrash,abort"
ENV = "JobSP=C,JobCP=F,RunCJ=F,TaskCJ=F,Trainer=C,PaySrc=C,PayRcv=C,CommSJ=C,WfSJ=C,Reg=C,Net=R"
COMMON = ["--sites", "1", "--launch", "2", "--profile", "taskMode"]
jobs = [
    (["Worker", "F", "C"] + COMMON + ["--faults", WF, "--grain", ENV, "--timeout", "1800", "--workers", "12"], "w1b"),
    (["Worker", "F", "C"] + COMMON + ["--faults", WF, "--grain", ENV, "--negative", "--timeout", "600", "--workers", "2"], "wnb"),
    (["Worker", "F", "C"] + COMMON + ["--faults", WF, "--grain", ENV, "--timeout", "1800", "--workers", "16"], "w1"),
    (["Worker", "F", "C"] + COMMON + ["--faults", "workerCrash,cjCrash,ctrlLoss", "--grain", ENV, "--timeout", "1800", "--workers", "16"], "w2"),
    (["Worker", "F", "C"] + COMMON + ["--faults", WF, "--grain", ENV, "--negative", "--timeout", "600", "--workers", "4"], "wn"),
    (["TaskCJ", "F", "C"] + COMMON + ["--faults", WF, "--grain", ENV.replace("TaskCJ=F", "Worker=F"), "--timeout", "1800", "--workers", "16"], "t1"),
    (["JobCP", "F", "C"] + COMMON + ["--faults", WF, "--grain", ENV.replace("JobCP=F", "Worker=F"), "--timeout", "1800", "--workers", "12"], "j1"),
    (["WfSJ", "F", "C"] + COMMON + ["--faults", WF, "--grain", ENV + ",Worker=F", "--timeout", "1800", "--workers", "12"], "f1"),
]
which = sys.argv[1:] or [t for _, t in jobs]
with ThreadPoolExecutor(len(which)) as ex:
    fs = [ex.submit(ref, a, t) for a, t in jobs if t in which]
    for f in fs: print(f.result(), flush=True)
