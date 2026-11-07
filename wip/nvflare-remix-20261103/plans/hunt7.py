# Campaign hunt7 (v7 search: phase-gated fault throttle, checkpoint BFS, no idle
# scheduler passes), same families and properties as hunt6. Tracks:
#   S  fuse simulation: each trace draws the job phase from which faults may fire
#   L  3-site instances, fuse simulation
#   C  BFS from mid-job checkpoints (RUNNING, first result, round 2, end-run), K=1/2
#   D  blind rediscovery of T1, R1, R2 under the new search (regression)
# Checkpoints must be harvested first: plans/hunt7_ckpt.py (C runs whose checkpoints
# are missing are left out and listed on stderr).
import os, runpy, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
h6 = runpy.run_path(str(ROOT / "plans" / "hunt6.py"))
G, F, grain = h6["G"], h6["F"], h6["grain"]
GINV, PINV, GPROP, EXT = h6["GINV"], h6["PINV"], h6["GPROP"], h6["EXT"]
INST = {"s2l1a2": (2, 1, 2), "s2l2a2": (2, 2, 2), "s1l2a2": (1, 2, 2)}
T_S = int(os.environ.get("HUNT7_T", "20"))
BUDGET_S = 4           # rare-event budget per trace (total weight)
CK_PHASES = [2, 3, 4, 5]
CK = ROOT / "checks" / "ckpt"


def sim(name, track, fam, inst, T, allfine=False, timeout=900, workers=6, inv=None, known=True, faults=None,
        rarity=BUDGET_S):
    fl, fine, prof, net, smin = F[fam]
    s, l, a = inst
    depth = 3000 if s >= 3 else 2500   # all-fine, 2 sites: end-run near step 900 (v7 probe)
    return dict(name=name, track=track, family=fam, grain=grain(fine, net, allfine or fam == "allP"),
                faults=faults or fl, sites=s, launch=l, attempt=a, profile=prof, inv=inv or (GINV + PINV),
                prop=GPROP, extends=EXT, known=known, deadlock=True, throttle=T, fuse=True, rarity=rarity,
                mode="sim", depth=depth, timeout=timeout, workers=workers, heap="12g",
                symmetry="cseTasks" not in prof)


def ck_inst(fam):
    return (2, 1, 2) if F[fam][4] >= 2 else (1, 1, 2)


def ck_key(fam):
    s, l, a = ck_inst(fam)
    return f"h7_{fam}_s{s}l{l}a{a}"


def ck_states(fam, phase):
    d = CK / ck_key(fam)
    return [f.read_text() for f in sorted(d.glob(f"p{phase}_*.tla"))] if d.exists() else []


def ckbfs(name, fam, phase, K, timeout=1200, workers=12):
    fl, fine, prof, net, smin = F[fam]
    s, l, a = ck_inst(fam)
    st = ck_states(fam, phase)
    if not st:
        print(f"hunt7: no checkpoints for {fam} phase {phase}, {name} left out", file=sys.stderr)
        return None
    return dict(name=name, track="C", family=fam, grain=grain(fine, net, fam == "allP"), faults=fl, sites=s,
                launch=l, attempt=a, profile=prof, inv=GINV + PINV, prop=GPROP, extends=EXT, known=True,
                deadlock=True, rarity=K, init_states=st, ckpt=f"{ck_key(fam)}/p{phase}", mode="bfs",
                timeout=timeout, workers=workers, heap="24g")


PLAN = []
for fam, (fl, fine, prof, net, smin) in F.items():
    for iname, inst in INST.items():
        if inst[0] < smin:
            continue
        PLAN.append(sim(f"h7S_{fam}_fam_{iname}", "S", fam, inst, T_S))
        if fam != "allP":
            PLAN.append(sim(f"h7S_{fam}_allF_{iname}", "S", fam, inst, T_S, allfine=True))
for fam in ["tail", "net", "cse", "err", "proc", "allP"]:
    PLAN.append(sim(f"h7L_{fam}_s3l1a2", "L", fam, (3, 1, 2), T_S, timeout=1800, workers=8))
# blind rediscovery under the new search (hunt6 D set, fuse on)
REDIS = {"del": ["GSchedulerThreadAlive"], "job": ["GSchedulerThreadAlive"],
         "proc": ["GNoStaleStatusAfterRestart"]}
for fam, props in REDIS.items():
    for iname in ["s1l2a2", "s2l2a2"]:
        PLAN.append(sim(f"h7D_{fam}_{iname}", "D", fam, INST[iname], 50, timeout=1200,
                        inv=GINV + PINV + props, rarity=99))
for iname in ["s1l1a1", "s2l1a1"]:
    s = int(iname[1])
    PLAN.append(sim(f"h7D_cpRestart_{iname}", "D", "proc", (s, 1, 1), 20, timeout=1200,
                    faults=["cpCrash", "rpcTimeout"], known=False, rarity=99))
# checkpoint BFS: K=1 at every phase for every family, K=2 at RUNNING and end-run
for fam in F:
    for ph in CK_PHASES:
        if ph == 4 and ck_inst(fam)[2] < 2:
            continue
        PLAN.append(ckbfs(f"h7C_{fam}_p{ph}_k1", fam, ph, 1))
for fam in ["proc", "del", "jobP", "job", "restart", "net"]:
    for ph in [2, 5]:
        PLAN.append(ckbfs(f"h7C_{fam}_p{ph}_k2", fam, ph, 2))
PLAN = [p for p in PLAN if p]

if os.environ.get("HUNT7_SMOKE") == "1":
    seen, smoke = set(), []
    for p in PLAN:
        key = (p["track"], p["family"])
        if key in seen:
            continue
        seen.add(key)
        smoke.append(dict(p, name=p["name"].replace("h7", "h7smoke", 1), timeout=150,
                          workers=4 if p["mode"] == "sim" else 8))
    PLAN = smoke
