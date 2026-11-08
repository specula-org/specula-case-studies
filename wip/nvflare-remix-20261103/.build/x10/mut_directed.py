"""Directed mutation check: start BFS in the mutant from a state of a real (unmutated) witness trace,
a few steps before the path the guard protects, so the mutant's bad step is within reach.
mut_directed.py MUT WITNESS_LOG STATE_FROM_END"""
import json, re, runpy, sys
m, log, back = sys.argv[1], sys.argv[2], int(sys.argv[3])
MR = "/home/ubuntu/nvflare-remix-20261103" if m == "base" else f"/home/ubuntu/nvflare-remix-20261103/.tmp/mut/{m}"
sys.path.insert(0, MR + "/scripts")
import mkmc, run_mc
lines = open(log).read().splitlines()
heads = [i for i, l in enumerate(lines) if re.match(r"^State \d+: ", l)]
i = heads[-1 - back] + 1
blk = []
while i < len(lines) and lines[i].strip() != "":
    blk.append(lines[i]); i += 1
W = runpy.run_path("/home/ubuntu/nvflare-remix-20261103/plans/hunt10_W.py")
C = W["COMMON"]
name = f"mutd_{m}_{back}"
mkmc.build(name, grain=C["grain"], faults=W["FAM"]["rec"], sites=1, launch=2, attempt=2, inv=C["inv"],
           prop=C["prop"], symmetry=False, deadlock=False, profile=["taskMode"], known=True, extends=C["extends"],
           rarity=4, throttle=20, fuse=True, init_states=["\n".join(blk)])
r = run_mc.run(name, 600, 16, "bfs", (0, 0), "24g"); r.pop("cfg", None)
print(m, back, json.dumps({k: v for k, v in r.items() if k in ("result", "violated", "distinct", "depth", "error")}))
