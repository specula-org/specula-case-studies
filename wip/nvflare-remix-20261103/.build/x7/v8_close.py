#!/usr/bin/env python3
"""v8 closing checks for the 2b goal:
  TV+  : the real POC trace on all-coarse (BFS) and all-fine (simulation) through gen_trace.py --run,
         which prints TRACE ACCEPTED when TraceNotAccepted (tpos <= Len(TR)) is violated (cursor past the end)
  TV-  : the same trace with SendStart moved before ServerLaunch on all-coarse, BFS: must be rejected
  C1B  : blind simulation (no constraint) with the other job's exit priced: dead completion thread while
         J2 is not finalized (OtherFinalizable), and the resulting hang (deadlock, KnownStuck off)
"""
import json, os, re, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
ROOT = "/home/ubuntu/nvflare-remix-20261103"
sys.path.insert(0, f"{ROOT}/scripts")
import mkmc, run_mc  # noqa: E402

G = ["JobSP", "JobCP", "RunCJ", "TaskCJ", "Trainer", "PaySrc", "PayRcv", "CommSJ", "WfSJ", "Reg"]
ENV = dict(os.environ, MIX_INCLUDE_WIP="all")
ALLF = "JobSP=F,JobCP=F,RunCJ=F,TaskCJ=F,Trainer=F,PaySrc=F,PayRcv=F,CommSJ=F,WfSJ=F,Reg=F,Net=R"


def grain(over):
    g = {k: "C" for k in G}; g.update(over); g["Net"] = "R"; return g


def tv_pos_allC():
    out = subprocess.run(["python3", "scripts/gen_trace.py", "allC", "--run", "--timeout", "900", "--workers", "16"],
                         capture_output=True, text=True, cwd=ROOT, env=ENV).stdout
    return "TV+ allC (BFS): " + " | ".join(l for l in out.splitlines() if "TRACE" in l or "'result'" in l)[-300:]


def tv_neg_allC():
    subprocess.run(["python3", "scripts/gen_trace.py", "allC"], capture_output=True, text=True, cwd=ROOT, env=ENV)
    t = open(f"{ROOT}/checks/trace/TraceMix_allC.tla").read()
    launch = '[a |-> "ServerLaunch", c |-> None]'
    start = '[a |-> "SendStart", c |-> s1]'
    assert launch in t and start in t
    i, j = t.index(launch), t.index(start)
    assert i < j
    # swap the two events: SendStart(s1) now precedes ServerLaunch
    t = t[:i] + start + t[i + len(launch):j] + launch + t[j + len(start):]
    t = t.replace("MODULE TraceMix_allC", "MODULE MC_TraceMix_allCneg")
    open(f"{ROOT}/checks/mixes/MC_TraceMix_allCneg.tla", "w").write(t)
    open(f"{ROOT}/checks/mixes/MC_TraceMix_allCneg.cfg", "w").write(open(f"{ROOT}/checks/trace/TraceMix_allC.cfg").read())
    r = run_mc.run("TraceMix_allCneg", 900, 16, "bfs", (0, 0), "16g")
    verdict = ("REJECTED (exhaustive, no behavior reaches the end)" if r.get("result") == "pass_exhaustive"
               else "ACCEPTED (wrong)" if r.get("violated") == "TraceNotAccepted" else f"inconclusive: {r.get('result')}")
    return f"TV- allC reordered (BFS): {verdict}; distinct={r.get('distinct')}"


def tv_pos_allF():
    out = subprocess.run(["python3", "scripts/gen_trace.py", "allF", "--grain", ALLF], capture_output=True, text=True, cwd=ROOT, env=ENV).stdout
    t = open(f"{ROOT}/checks/trace/TraceMix_allF.tla").read().replace("MODULE TraceMix_allF", "MODULE MC_TraceMix_allFz")
    open(f"{ROOT}/checks/mixes/MC_TraceMix_allFz.tla", "w").write(t)
    open(f"{ROOT}/checks/mixes/MC_TraceMix_allFz.cfg", "w").write(open(f"{ROOT}/checks/trace/TraceMix_allF.cfg").read())
    r = run_mc.run("TraceMix_allFz", 1200, 16, "sim", (2000, 10 ** 9), "16g")
    acc = r.get("violated") == "TraceNotAccepted"
    return f"TV+ allF (simulation): {'TRACE ACCEPTED' if acc else 'NOT ACCEPTED: ' + str(r.get('result'))} in {r.get('wall_seconds')} s"


def c1b(name, inv, deadlock, T):
    mkmc.build(name, grain=grain({"JobSP": "F", "JobCP": "F", "RunCJ": "F"}),
               faults=["storeError", "rpcTimeout", "abort", "cjCrash"], sites=1, launch=1, attempt=1, prop=[],
               extends=("Mix", "Props", "GenericProps"), profile=["multiJob"], inv=inv, deadlock=deadlock,
               known=False, throttle=T, rarity=99,
               extra_defs='OtherFinalizable == ~(pJobSP.completionCrashed /\\ pJobSP.other \\in {"queued", "running", "exited"})')
    r = run_mc.run(name, 900, 8, "sim", (1500, 10 ** 9), "12g")
    other = ""
    if r.get("violated"):
        log = open(f"{ROOT}/logs/{name}.log").read()
        k = log.find("is violated") if "is violated" in log else log.find("Deadlock")
        m = re.findall(r'other \|-> "(\w+)"', log[k:])
        c = re.findall(r'completionCrashed \|-> (\w+)', log[k:])
        other = f" (end: other={m[-1] if m else '?'}, completionCrashed={c[-1] if c else '?'})"
    return f"{name}: {r.get('result')} {r.get('violated') or ''}{other} traces={r.get('traces')}"


if __name__ == "__main__":
    with ThreadPoolExecutor(7) as ex:
        fs = [ex.submit(tv_pos_allC), ex.submit(tv_neg_allC), ex.submit(tv_pos_allF),
              ex.submit(c1b, "mj_c1b_blind_t20", ["OtherFinalizable"], False, 20),
              ex.submit(c1b, "mj_c1b_blind_t50", ["OtherFinalizable"], False, 50),
              ex.submit(c1b, "mj_c1b_hangb_t20", [], True, 20),
              ex.submit(c1b, "mj_c1b_hangb_t50", [], True, 50)]
        for f in fs:
            print(f.result(), flush=True)
