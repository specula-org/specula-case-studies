import sys, json, subprocess, os
sys.path.insert(0, "/home/ubuntu/nvflare-remix-20261103/scripts")
import mkmc, run_mc
from concurrent.futures import ThreadPoolExecutor
ROOT = "/home/ubuntu/nvflare-remix-20261103"
G = ["JobSP", "JobCP", "RunCJ", "TaskCJ", "Trainer", "PaySrc", "PayRcv", "CommSJ", "WfSJ", "Reg"]
def grain(over): g = {k: "C" for k in G}; g.update(over); g["Net"] = "R"; return g
base = dict(sites=1, launch=1, attempt=2, prop=[], extends=("Mix", "Props", "GenericProps", "PropsLocal"), deadlock=False)
B = {"trn_h03": dict(grain=grain({"Trainer": "X", "TaskCJ": "F"}), faults=["tpSilent", "monitorStale"], rarity=5, inv=["LTrainerStopOwner"]),
     "trn_h03ctl": dict(grain=grain({"Trainer": "X", "TaskCJ": "F"}), faults=["tpSilent"], rarity=5, inv=["LTrainerStopOwner"]),
     "trn_h03_tc": dict(grain=grain({"Trainer": "X"}), faults=["tpSilent", "monitorStale"], rarity=5, inv=["LTrainerStopOwner"])}
for n, kw in B.items(): mkmc.build(n, **base, **kw)
def ref(args, tag):
    env = dict(os.environ, MIX_INCLUDE_WIP="all")
    out = subprocess.run(["python3", f"{ROOT}/scripts/gen_ref.py"] + args + ["--run", "--tag", tag], capture_output=True, text=True, env=env, cwd=ROOT).stdout
    return tag + ": " + " | ".join(l for l in out.splitlines() if "receipt" in l or "'result'" in l or "rror" in l)[-350:]
def mc(n):
    r = run_mc.run(n, 900, 10, "bfs", (0, 0), "16g")
    return json.dumps({k: v for k, v in r.items() if k in ("name", "result", "violated", "depth", "distinct", "distinct_at_stop")})
with ThreadPoolExecutor(5) as ex:
    fs = [ex.submit(ref, ["Trainer", "X", "C", "--sites", "1", "--attempt", "2", "--faults", "tpSilent,monitorStale,trainerError", "--timeout", "900", "--workers", "16"], "x1"),
          ex.submit(ref, ["Trainer", "X", "C", "--sites", "1", "--attempt", "2", "--faults", "tpSilent,monitorStale", "--negative", "--timeout", "300", "--workers", "8"], "x1n")]
    fs += [ex.submit(mc, n) for n in B]
    for f in fs: print(f.result(), flush=True)
