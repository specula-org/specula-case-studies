# Campaign hunt5 (v5 model: A's gaps filled where feasible). Tracks:
#   S  throttled deep simulation over the NEW profile families (deadlock on, known findings filtered)
#   O  throttled simulation over the v4 families on the v5 model (regression of the changed groups)
#   D  rediscovery: blind throttled simulation with the properties of the findings confirmed in
#      round 5 (H11 monitor death, C1-B completion-thread death, H08 env), no filters for them
#   B  rarity-bounded BFS (K=1) on the new profile families
# HUNT5_SMOKE=1 -> one short run per new family and track (model sanity before the campaign).
import os

G = ["JobSP", "JobCP", "RunCJ", "TaskCJ", "Trainer", "PaySrc", "PayRcv", "CommSJ", "WfSJ"]
OLD = {
    "tail":    ["taskTimeout", "minClients", "cancel", "slowEnvelope", "slowSJTeardown", "pullTimeout",
                "txTimeout", "sourceFailure", "payConsumer", "payProduce", "submitTimeout"],
    "restart": ["cjCrash", "sjCrash", "launchError", "deployError", "abort", "resExpiry", "rpcTimeout",
                "taskTimeout"],
    "net":     ["netLoss", "rpcTimeout", "pullTimeout", "txTimeout", "submitTimeout", "transportFail",
                "deadClient", "taskTimeout"],
    "job":     ["abort", "abortCmdError", "slowAdminStop", "storeError", "archiveError", "outcomeReportFail",
                "admissionError", "launchError", "deployError", "rpcTimeout"],
    "task":    ["trainerError", "resultWaitTimeout", "taskTimeout", "cbFail", "prepFail", "payCallback",
                "paySubmit", "payCompute", "payDelete", "payConsumer"],
}
OLD_FINE = {
    "tail":    ["PaySrc", "PayRcv", "RunCJ", "WfSJ", "CommSJ", "TaskCJ"],
    "restart": ["JobSP", "JobCP", "RunCJ", "TaskCJ"],
    "net":     ["TaskCJ", "CommSJ", "PaySrc", "PayRcv", "JobSP"],
    "job":     ["JobSP", "JobCP", "RunCJ"],
    "task":    ["Trainer", "TaskCJ", "PaySrc", "WfSJ"],
}
OLD_PROFILE = {"net": ["wfTolerant", "lossBudget3"], "tail": ["wfTolerant"], "restart": ["wfTolerant"]}

# new families: (faults, fine groups, profile switches, Net variant, min sites)
NEW = {
    # lifecycle with NVFlare's default non-strict start replies and a second job on every CP
    "jobP": (["rpcTimeout", "cjCrash", "launchError", "storeError", "abort", "outcomeReportFail", "sjCrash",
              "taskTimeout"], ["JobSP", "JobCP", "RunCJ", "TaskCJ"], ["nonStrictStart", "otherJob"], "R", 1),
    # concurrent per-site tasks (client-controlled CSE pattern) with retries from loss and relaunch
    "cse":  (["netLoss", "cjCrash", "rpcTimeout", "submitTimeout", "taskTimeout", "pullTimeout", "deadClient"],
             ["CommSJ", "TaskCJ", "WfSJ", "PaySrc", "PayRcv", "RunCJ"], ["cseTasks", "wfTolerant"], "L", 2),
    # resilient result-error handling with trainer and callback failures
    "err":  (["trainerError", "cbFail", "prepFail", "taskTimeout", "resultWaitTimeout", "payConsumer",
              "submitTimeout", "cjCrash"], ["Trainer", "TaskCJ", "WfSJ", "CommSJ"], ["errResilient", "wfTolerant"],
             "R", 1),
}
ALLF = sorted(set(sum(OLD.values(), [])) | {"netLoss", "sjCrash", "cjCrash"})
NEW["allP"] = (ALLF, G, ["nonStrictStart", "otherJob", "errResilient", "cseTasks", "wfTolerant", "lossBudget3"],
               "L", 2)

# K forms (GenericProps K section): K11 skips sites the non-strict START check dropped (N1 / H32 class)
GINV = ["GFinishedNoAbnormalExitK2", "GFinishedNoLiveChildK", "GTerminalNoLiveSJ", "GFinishedAllOutcomesK",
        "GDoneSavedCompletedK", "GFreeAtMostOnce", "GNoFreeWhileAliveK", "GNoAllocAfterFree",
        "GNoChildWithoutAlloc", "GOneLiveLaunch"]
PINV = ["RClaimNeedsMaterialized", "RMaterializedIsRegistered", "RAggregateIsAccepted", "AcceptedWasClaimed",
        "RNoReleaseBeforeMaterialize", "ResendPreservesAuthority", "OneAssignmentRecordPerIdentity",
        "EnvelopeRefsRegistered", "EndRunAfterDone", "SavedAfterOkClose"]
GPROP = ["GTerminalStableK", "GStatusStableK", "GOutcomeStable", "GExitStable"]
REDISCOVER = ["GTaskMonitorAlive", "GCompletionThreadAlive", "LEnvMatchesAllocation"]
EXT = ["Mix", "Props", "GenericProps", "PropsMR", "PropsLocal"]


def grain(fine, net, allfine=False):
    g = {k: ("F" if (allfine or k in fine) else "C") for k in G}
    g["Net"] = net
    return g


def sim(name, track, fam, faults, gr, profile, sites, launch, attempt, T, timeout=1500, workers=6,
        inv=None, known=True):
    depth = 800 if sites == 1 and attempt == 1 else 1500
    return dict(name=name, track=track, family=fam, grain=gr, faults=faults, sites=sites, launch=launch,
                attempt=attempt, profile=profile, inv=inv or (GINV + PINV), prop=GPROP, extends=EXT,
                known=known, deadlock=True, throttle=T, mode="sim", depth=depth, timeout=timeout,
                workers=workers, heap="10g", symmetry="cseTasks" not in profile)


def bfs(name, fam, faults, gr, profile, sites, launch, attempt, K, timeout=1500, workers=12):
    return dict(name=name, track="B", family=fam, grain=gr, faults=faults, sites=sites, launch=launch,
                attempt=attempt, profile=profile, inv=GINV + PINV, prop=GPROP, extends=EXT, known=True,
                deadlock=True, rarity=K, mode="bfs", timeout=timeout, workers=workers, heap="24g",
                symmetry="cseTasks" not in profile)


INST = [("s2l1a2", 2, 1, 2), ("s2l2a2", 2, 2, 2), ("s1l2a2", 1, 2, 2)]
PLAN = []
SMOKE = os.environ.get("HUNT5_SMOKE") == "1"

if SMOKE:
    for fam, (faults, fine, prof, net, smin) in NEW.items():
        PLAN.append(sim(f"h5smoke_{fam}", "S", fam, faults, grain(fine, net, fam == "allP"), prof, 2, 2, 2, 20,
                        timeout=150, workers=4))
        PLAN.append(sim(f"h5smokeD_{fam}", "D", fam, faults, grain(fine, net, fam == "allP"), prof, 2, 2, 2, 20,
                        timeout=150, workers=4, inv=GINV + PINV + REDISCOVER, known=False))
else:
    for fam, (faults, fine, prof, net, smin) in NEW.items():
        for iname, s, l, at in INST:
            if s < smin:
                continue
            for T in (20, 200):
                PLAN.append(sim(f"h5S_{fam}_fam_{iname}_t{T}", "S", fam, faults, grain(fine, net), prof, s, l, at, T))
                if fam != "allP":
                    PLAN.append(sim(f"h5S_{fam}_allF_{iname}_t{T}", "S", fam, faults, grain(fine, net, True), prof,
                                    s, l, at, T))
            PLAN.append(sim(f"h5D_{fam}_{iname}_t50", "D", fam, faults, grain(fine, net, fam == "allP"), prof,
                            s, l, at, 50, inv=GINV + PINV + REDISCOVER, known=False))
    for fam in OLD:
        PLAN.append(sim(f"h5O_{fam}_s2l2a2_t20", "O", fam, OLD[fam], grain(OLD_FINE[fam], "L" if fam == "net" else "R"),
                        OLD_PROFILE.get(fam, []), 2, 2, 2, 20))
    for fam, (faults, fine, prof, net, smin) in NEW.items():
        if fam == "allP":
            continue
        s = max(1, smin)
        PLAN.append(bfs(f"h5B_{fam}_s{s}l2a1_k1", fam, faults, grain(fine, net), prof, s, 2, 1, 1))
        PLAN.append(bfs(f"h5B_{fam}_s{s}l1a2_k1", fam, faults, grain(fine, net), prof, s, 1, 2, 1))
