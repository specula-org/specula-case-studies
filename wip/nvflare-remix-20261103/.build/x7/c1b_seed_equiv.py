# Same seed, 1 worker: does the pre-timing spec (dde11a1d) generate the same simulation as the current spec?
import json, os, runpy, subprocess, sys
NEW = "/home/ubuntu/nvflare-remix-20261103"
OLD = NEW + "/.tmp/pre_timing_ws"
which, name, seed, num = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
ws = OLD if which == "old" else NEW
if sys.argv[5:] != ["nobuild"]:
    sys.path.insert(0, ws + "/scripts")
    import mkmc
    p = [p for p in runpy.run_path(ws + "/plans/hunt8.py")["PLAN"] if p["name"] == "h8D_c1bmulti_s1l1a1"][0]
    kw = {k: p[k] for k in runpy.run_path(ws + "/scripts/hunt.py")["BUILD_KEYS"] if k in p}
    mkmc.build(name, **kw)
env = dict(os.environ, TLC_WORKERS="1", TLC_HEAP="8g")
r = subprocess.run([ws + "/scripts/tlc.sh", "tlc", ws + "/checks/mixes", "MC_" + name, "MC_" + name + ".cfg",
                    "-simulate", f"num={num}", "-depth", "400", "-seed", seed], capture_output=True, text=True, env=env)
keep = [l for l in r.stdout.splitlines() if any(s in l for s in ("states generated", "is violated", "Error:", "trace length", "Finished in", "seed"))]
print(which, name, "\n  " + "\n  ".join(keep[-8:]))
