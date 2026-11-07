import subprocess, os
from concurrent.futures import ThreadPoolExecutor
ROOT = "/home/ubuntu/nvflare-remix-20261103"
def ref(args, tag):
    env = dict(os.environ, MIX_INCLUDE_WIP="all")
    out = subprocess.run(["python3", f"{ROOT}/scripts/gen_ref.py"] + args + ["--run", "--tag", tag], capture_output=True, text=True, env=env, cwd=ROOT).stdout
    return tag + ": " + " | ".join(l for l in out.splitlines() if "receipt" in l or "'result'" in l or "rror" in l)[-400:]
MJ = ["JobSP", "F", "C", "--sites", "1", "--faults", "deleteJob,storeError,rpcTimeout,abort,spCrash", "--profile", "multiJob"]
with ThreadPoolExecutor(3) as ex:
    fs = [ex.submit(ref, MJ + ["--timeout", "900", "--workers", "16"], "mj1t"),
          ex.submit(ref, ["JobSP", "F", "C", "--sites", "1", "--faults", "deleteJob,rpcTimeout,storeError,deployError,abort,spCrash", "--timeout", "600", "--workers", "12"], "mj0t"),
          ex.submit(ref, MJ + ["--negative", "--timeout", "600", "--workers", "8"], "mj1tn")]
    for f in fs: print(f.result(), flush=True)
