"""Mutation checks: do the GW properties catch the bug class if the code lacked its guard?
m1: no can_restart task-owner gate (JobCP_F) -> expect W2a/W2b; m2: no recover_checkpoint_result -> expect W1."""
import json, runpy, sys
m = sys.argv[1]
MR = f"/home/ubuntu/nvflare-remix-20261103/.tmp/mut/{m}"
sys.path.insert(0, MR + "/scripts")
import mkmc, run_mc
W = runpy.run_path("/home/ubuntu/nvflare-remix-20261103/plans/hunt10_W.py")
C = W["COMMON"]
mkmc.build(f"mut_{m}", grain=C["grain"], faults=W["FAM"]["rec"], sites=1, launch=2, attempt=2, inv=C["inv"],
           prop=C["prop"], symmetry=False, deadlock=False, profile=["taskMode"], known=True, extends=C["extends"],
           rarity=4, throttle=20, fuse=True)
r = run_mc.run(f"mut_{m}", int(sys.argv[2]) if len(sys.argv) > 2 else 900, int(sys.argv[3]) if len(sys.argv) > 3 else 4, "sim", (2500, 10**9), "24g"); r.pop("cfg", None)
print(m, json.dumps({k: v for k, v in r.items() if k in ("result", "violated", "traces", "wall_seconds", "error")}))
