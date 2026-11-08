import sys, json
sys.path.insert(0, "/home/ubuntu/nvflare-remix-20261103/scripts")
sys.path.insert(0, "/home/ubuntu/nvflare-remix-20261103/.build/x10")
import smoke2
G = dict(smoke2.G_ALLF, JobSP="F", CommSJ="F", WfSJ="F")
smoke2.go("x10_try_rar", G, ["workerCrash", "cjCrash", "ctrlLoss", "netLoss"], sites=1, launch=2, attempt=2,
          mode="bfs", timeout=240, workers=6, inv=smoke2.BASE_INV + smoke2.GW_INV + ["LWAtMostOnce"],
          rarity=2, extends_extra=None) if False else None
import mkmc, run_mc
mkmc.build("x10_try_rar", grain=G, faults=["workerCrash", "cjCrash", "ctrlLoss", "netLoss"], sites=1, launch=2, attempt=2,
           inv=smoke2.BASE_INV + smoke2.GW_INV + ["LWAtMostOnce"], prop=smoke2.GW_PROP, symmetry=False, deadlock=False,
           profile=["taskMode"], rarity=2, known=True, extends=smoke2.EXT + ["JobPhase"],
           extra_defs="UpTo == JobPhase <= 5", constraint="UpTo")
r = run_mc.run("x10_try_rar", 240, 6, "bfs", (0, 0), "16g"); r.pop("cfg", None)
print(json.dumps({k: v for k, v in r.items() if k in ("result", "violated", "distinct", "depth", "error")}))
