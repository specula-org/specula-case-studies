"""v10 taskMode smoke: build one mix and run it (sim or bfs)."""
import sys, json
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import mkmc, run_mc

def go(name, grain, faults, sites=1, launch=2, attempt=1, mode="sim", depth=(300, 2000), timeout=300,
       inv=mkmc.PORT_INVS, prop=(), deadlock=True, constraint=None, extra_defs="", workers=8, extends=("Mix", "Props")):
    mkmc.build(name, grain=grain, faults=faults, sites=sites, launch=launch, attempt=attempt, inv=inv, prop=prop,
               symmetry=False, deadlock=deadlock, profile=["taskMode"], constraint=constraint,
               extra_defs=extra_defs, extends=extends)
    r = run_mc.run(name, timeout, workers, mode, depth, "16g")
    r.pop("cfg", None)
    print(name, json.dumps({k: v for k, v in r.items() if k in ("result", "violated", "distinct", "depth", "traces", "error", "secs")}))
    return r

if __name__ == "__main__":
    F = dict(Worker="F", TaskCJ="F", JobCP="F")
    which = sys.argv[1] if len(sys.argv) > 1 else "sim"
    if which == "sim":
        go("x10_smoke_sim", F, ["workerCrash"], mode="sim")
    elif which == "simC":
        go("x10_smoke_simC", dict(Worker="C", TaskCJ="F", JobCP="F"), ["workerCrash"], mode="sim")
    elif which == "bfs":
        go("x10_smoke_bfs", F, ["workerCrash"], mode="bfs", timeout=900, workers=16)
