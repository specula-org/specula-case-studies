import sys, json, runpy
sys.path.insert(0, "/home/ubuntu/nvflare-remix-20261103/scripts")
import ckpt, mkmc, run_mc
h8 = runpy.run_path("/home/ubuntu/nvflare-remix-20261103/plans/hunt8.py")
fl, fine, prof, net, smin = h8["F"]["del"]
G = h8["G"]
for tag, over in [("zdelF", {"JobSP": "F", "JobCP": "F", "CommSJ": "F", "WfSJ": "F"}),
                  ("zdelF2", {"JobSP": "F", "JobCP": "F", "CommSJ": "F", "WfSJ": "F", "RunCJ": "F", "TaskCJ": "F", "Reg": "F"})]:
    g = {k: "C" for k in G}; g.update(over); g["Net"] = net
    kw = dict(grain=g, faults=fl, sites=1, launch=1, attempt=2, profile=prof)
    st = ckpt.harvest(f"{tag}_s1l1a2", kw, 5, 2, timeout=240)
    print(tag, "checkpoints", len(st), flush=True)
    mkmc.build(f"{tag}_p5_k2", grain=g, faults=fl, sites=1, launch=1, attempt=2, profile=prof,
               inv=["GDoneSavedCompletedK"], prop=[], extends=tuple(h8["EXT"]), known=True, deadlock=False,
               rarity=2, init_states=st)
    r = run_mc.run(f"{tag}_p5_k2", 1500, 12, "bfs", (0, 0), "16g")
    print(json.dumps({k: r.get(k) for k in ("name", "result", "violated", "depth", "distinct", "distinct_at_stop")}), flush=True)
