# Campaign hunt6 (v6 model: thread-death audit, admin delete, SP/CP restart, TV-checked
# fine variants), <= 8 h at 80 TLC workers. Tracks:
#   S  throttled deep simulation, every family, known findings filtered (K forms + KnownStuck)
#   L  3-site instances (simulation) for the families where more sites change the protocol
#   D  blind rediscovery of the round-6 findings (T1, R1, R2), their properties unfiltered
#   B  rarity-bounded BFS (K=1, K=2) on the new families
# Rule kept from hunt4: network loss and process death always come with request timeouts
# (rpcTimeout), since every real admin request has one.
import os

G = ["JobSP", "JobCP", "RunCJ", "TaskCJ", "Trainer", "PaySrc", "PayRcv", "CommSJ", "WfSJ"]
# family: (faults, fine groups, profile switches, Net variant, min sites)
F = {
    "tail":    (["taskTimeout", "minClients", "cancel", "slowEnvelope", "slowSJTeardown", "pullTimeout",
                 "txTimeout", "sourceFailure", "payConsumer", "payProduce", "submitTimeout"],
                ["PaySrc", "PayRcv", "RunCJ", "WfSJ", "CommSJ", "TaskCJ"], ["wfTolerant"], "R", 1),
    "restart": (["cjCrash", "sjCrash", "launchError", "deployError", "abort", "resExpiry", "rpcTimeout",
                 "taskTimeout"], ["JobSP", "JobCP", "RunCJ", "TaskCJ"], ["wfTolerant"], "R", 1),
    "net":     (["netLoss", "rpcTimeout", "pullTimeout", "txTimeout", "submitTimeout", "transportFail",
                 "deadClient", "taskTimeout"], ["TaskCJ", "CommSJ", "PaySrc", "PayRcv", "JobSP"],
                ["wfTolerant", "lossBudget3"], "L", 1),
    "job":     (["abort", "abortCmdError", "storeError", "archiveError", "outcomeReportFail",
                 "admissionError", "launchError", "deployError", "rpcTimeout", "deleteJob"],
                ["JobSP", "JobCP", "RunCJ"], [], "R", 1),
    "task":    (["trainerError", "resultWaitTimeout", "taskTimeout", "cbFail", "prepFail", "payCallback",
                 "paySubmit", "payCompute", "payDelete", "payConsumer"], ["Trainer", "TaskCJ", "PaySrc", "WfSJ"],
                [], "R", 1),
    "jobP":    (["rpcTimeout", "cjCrash", "launchError", "storeError", "abort", "outcomeReportFail", "sjCrash",
                 "taskTimeout", "deleteJob"], ["JobSP", "JobCP", "RunCJ", "TaskCJ"], ["nonStrictStart", "otherJob"],
                "R", 1),
    "cse":     (["netLoss", "cjCrash", "rpcTimeout", "submitTimeout", "taskTimeout", "pullTimeout", "deadClient"],
                ["CommSJ", "TaskCJ", "WfSJ", "PaySrc", "PayRcv", "RunCJ"], ["cseTasks", "wfTolerant"], "L", 2),
    "err":     (["trainerError", "cbFail", "prepFail", "taskTimeout", "resultWaitTimeout", "payConsumer",
                 "submitTimeout", "cjCrash"], ["Trainer", "TaskCJ", "WfSJ", "CommSJ"], ["errResilient", "wfTolerant"],
                "R", 1),
    "proc":    (["spCrash", "cpCrash", "cjCrash", "rpcTimeout", "taskTimeout", "deadClient", "abort"],
                ["JobSP", "JobCP", "RunCJ", "CommSJ", "TaskCJ"], ["wfTolerant"], "R", 1),
    "del":     (["deleteJob", "rpcTimeout", "deployError", "abort", "storeError", "admissionError"],
                ["JobSP", "JobCP"], [], "R", 1),
}
# all-in family; slowAdminStop (the timing escape behind the timing-implausible
# ABORT_classified_completed lead) is left out
ALLF = sorted(set(sum((v[0] for v in F.values()), [])) | {"sjCrash"})
F["allP"] = (ALLF, G, ["nonStrictStart", "otherJob", "errResilient", "cseTasks", "wfTolerant", "lossBudget3"], "L", 2)

GINV = ["GFinishedNoAbnormalExitK2", "GFinishedNoLiveChildK", "GTerminalNoLiveSJ", "GFinishedAllOutcomesK",
        "GDoneSavedCompletedK", "GFreeAtMostOnce", "GNoFreeWhileAliveK", "GNoAllocAfterFree",
        "GNoChildWithoutAlloc", "GOneLiveLaunch"]
PINV = ["RClaimNeedsMaterialized", "RMaterializedIsRegistered", "RAggregateIsAccepted", "AcceptedWasClaimed",
        "RNoReleaseBeforeMaterialize", "ResendPreservesAuthority", "OneAssignmentRecordPerIdentity",
        "EnvelopeRefsRegistered", "EndRunAfterDone", "SavedAfterOkClose"]
GPROP = ["GTerminalStableK", "GStatusStableK", "GOutcomeStable", "GExitStable"]
EXT = ["Mix", "Props", "GenericProps", "PropsMR", "PropsLocal"]


def grain(fine, net, allfine=False):
    g = {k: ("F" if (allfine or k in fine) else "C") for k in G}
    g["Net"] = net
    return g


def sim(name, track, fam, inst, T, allfine=False, timeout=1650, workers=6, inv=None, known=True, faults=None):
    fl, fine, prof, net, smin = F[fam]
    s, l, a = inst
    depth = 800 if s == 1 and a == 1 else (2000 if s >= 3 else 1500)
    return dict(name=name, track=track, family=fam, grain=grain(fine, net, allfine or fam == "allP"),
                faults=faults or fl, sites=s, launch=l, attempt=a, profile=prof, inv=inv or (GINV + PINV),
                prop=GPROP, extends=EXT, known=known, deadlock=True, throttle=T, mode="sim", depth=depth,
                timeout=timeout, workers=workers, heap="12g", symmetry="cseTasks" not in prof)


def bfs(name, fam, inst, K, timeout=3000, workers=12):
    fl, fine, prof, net, smin = F[fam]
    s, l, a = inst
    return dict(name=name, track="B", family=fam, grain=grain(fine, net), faults=fl, sites=s, launch=l, attempt=a,
                profile=prof, inv=GINV + PINV, prop=GPROP, extends=EXT, known=True, deadlock=True, rarity=K,
                mode="bfs", timeout=timeout, workers=workers, heap="24g", symmetry="cseTasks" not in prof)


INST = {"s2l1a2": (2, 1, 2), "s2l2a2": (2, 2, 2), "s1l2a2": (1, 2, 2)}
PLAN = []
for fam, (fl, fine, prof, net, smin) in F.items():
    for iname, inst in INST.items():
        if inst[0] < smin:
            continue
        for T in (20, 200):
            PLAN.append(sim(f"h6S_{fam}_fam_{iname}_t{T}", "S", fam, inst, T))
            if fam != "allP":
                PLAN.append(sim(f"h6S_{fam}_allF_{iname}_t{T}", "S", fam, inst, T, allfine=True))
# 3 sites: more than one other client per site (tolerant policies, per-site tasks, partial failures)
for fam in ["tail", "net", "cse", "err", "proc", "allP"]:
    for T in (20, 200):
        PLAN.append(sim(f"h6L_{fam}_s3l1a2_t{T}", "L", fam, (3, 1, 2), T, timeout=2400, workers=8))
# blind rediscovery, the round-6 properties unfiltered
REDIS = {"del": ["GSchedulerThreadAlive"], "job": ["GSchedulerThreadAlive"],
         "proc": ["GNoStaleStatusAfterRestart"]}
for fam, props in REDIS.items():
    for iname in ["s1l2a2", "s2l2a2"]:
        PLAN.append(sim(f"h6D_{fam}_{iname}_t50", "D", fam, INST[iname], 50, timeout=1500,
                        inv=GINV + PINV + props, known=True))
# R2 (CP restart hang) shows as a deadlock: KnownStuck off, minimal fault set
for iname in ["s1l1a1", "s2l1a1"]:
    s = int(iname[1])
    PLAN.append(sim(f"h6D_cpRestart_{iname}_t20", "D", "proc", (s, 1, 1), 20, timeout=1200,
                    faults=["cpCrash", "rpcTimeout"], known=False))
# rarity-bounded BFS
for fam in ["jobP", "cse", "err", "proc", "del", "job"]:
    s = max(1, F[fam][4])
    PLAN.append(bfs(f"h6B_{fam}_s{s}l2a1_k1", fam, (s, 2, 1), 1))
    PLAN.append(bfs(f"h6B_{fam}_s{s}l1a2_k1", fam, (s, 1, 2), 1))
for fam in ["proc", "del", "jobP"]:
    PLAN.append(bfs(f"h6B_{fam}_s1l1a1_k2", fam, (1, 1, 1), 2, timeout=2400))

if os.environ.get("HUNT6_SMOKE") == "1":
    # one short run per family and track kind (model sanity before the campaign)
    seen, smoke = set(), []
    for p in PLAN:
        key = (p["track"], p["family"])
        if key in seen or p["track"] == "B":
            continue
        seen.add(key)
        q = dict(p, name=p["name"].replace("h6", "h6smoke", 1), timeout=150, workers=4)
        smoke.append(q)
    PLAN = smoke
