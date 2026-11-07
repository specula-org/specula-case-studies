import sys, json, subprocess, os
sys.path.insert(0, "/home/ubuntu/nvflare-remix-20261103/scripts")
import mkmc, run_mc
from concurrent.futures import ThreadPoolExecutor
ROOT = "/home/ubuntu/nvflare-remix-20261103"
G = ["JobSP", "JobCP", "RunCJ", "TaskCJ", "Trainer", "PaySrc", "PayRcv", "CommSJ", "WfSJ", "Reg"]
def grain(fine): g = {k: ("F" if k in fine else "C") for k in G}; g["Net"] = "R"; return g
base = dict(launch=1, attempt=1, prop=[], extends=("Mix", "Props", "GenericProps"))
B = {
 "v8_t2_s2":  dict(grain=grain(["Reg"]), sites=2, faults=["deadClient"], rarity=3, inv=["GCleanupThreadAlive"], deadlock=False),
 "v8_t2_s1":  dict(grain=grain(["Reg"]), sites=1, faults=["deadClient"], rarity=6, inv=["GCleanupThreadAlive"], deadlock=False),
 "v8_t3_s2":  dict(grain=grain(["Reg"]), sites=2, faults=["deadClient", "jobExitRace"], profile=["otherJob"], rarity=5, inv=["GCleanupThreadAliveK"], deadlock=False),
 "v8_r2":     dict(grain=grain(["Reg", "CommSJ", "JobCP"]), sites=1, faults=["cpCrash", "rpcTimeout"], inv=["GCleanupThreadAlive"], deadlock=True, known=False),
 "v8_r2ctl":  dict(grain=grain(["Reg", "CommSJ", "JobCP"]), sites=1, faults=["cjCrash", "rpcTimeout"], inv=["GCleanupThreadAlive"], deadlock=True, known=False),
}
for n, kw in B.items():
    mkmc.build(n, **base, **kw)
def ref(args, tag):
    env = dict(os.environ, MIX_INCLUDE_WIP="all")
    out = subprocess.run(["python3", f"{ROOT}/scripts/gen_ref.py"] + args + ["--run", "--tag", tag], capture_output=True, text=True, env=env, cwd=ROOT).stdout
    return tag + ": " + " | ".join(l for l in out.splitlines() if "receipt" in l or "'result'" in l)[-300:]
def mc(n, t=600, w=8):
    r = run_mc.run(n, t, w, "bfs", (0, 0), "12g")
    return json.dumps({k: v for k, v in r.items() if k in ("name", "result", "violated", "depth", "distinct", "distinct_at_stop")})
with ThreadPoolExecutor(7) as ex:
    fs = [ex.submit(ref, ["Reg", "F", "C", "--sites", "2", "--faults", "deadClient,jobExitRace,cpCrash,cjCrash,rpcTimeout", "--profile", "otherJob", "--timeout", "900", "--workers", "16"], "v8d"),
          ex.submit(ref, ["Reg", "F", "C", "--sites", "2", "--faults", "deadClient,jobExitRace", "--profile", "otherJob", "--negative", "--timeout", "300", "--workers", "8"], "v8dn")]
    fs += [ex.submit(mc, n) for n in B]
    for f in fs:
        print(f.result(), flush=True)
