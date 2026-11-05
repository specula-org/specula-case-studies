# Campaign hunt4 (v4 model): ~4 h at 80 TLC workers. Tracks:
#   S  throttled deep simulation (fault throttle 1/T, depth 600, deadlock on)
#   P  per-site mixes, throttled simulation
#   B  rarity-bounded BFS (K=1), deadlock on, 1 site, restart or 2 rounds
#   R  rarity-bounded BFS (K=2), minimal instance
#   C  control: unthrottled deep simulation (the old way) on the same mixes
#   A  assume-guarantee properties (AG_Trainer, AG_RunCJ) under throttled sim
G = ["JobSP", "JobCP", "RunCJ", "TaskCJ", "Trainer", "PaySrc", "PayRcv", "CommSJ", "WfSJ"]

# fault families (hazard-oriented); network losses always come with the
# timeouts that a real cell request has
FAM = {
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
# outcomeTimeout (900 s grace expiry, H33) is known by design and masks the rest
# (bfs3, COORDINATOR-LOG 04:20); it is left out of every family
ALL = sorted(set(sum(FAM.values(), [])) | {"sjCrash", "netLoss", "slowSJTeardown", "slowEnvelope"})
FAM["all"] = ALL

# groups made fine for a family (the rest coarse)
FINE = {
    "tail":    ["PaySrc", "PayRcv", "RunCJ", "WfSJ", "CommSJ", "TaskCJ"],
    "restart": ["JobSP", "JobCP", "RunCJ", "TaskCJ"],
    "net":     ["TaskCJ", "CommSJ", "PaySrc", "PayRcv", "JobSP"],
    "job":     ["JobSP", "JobCP", "RunCJ"],
    "task":    ["Trainer", "TaskCJ", "PaySrc", "WfSJ"],
    "all":     G,
}
PROFILE = {"net": ["wfTolerant", "lossBudget3"], "tail": ["wfTolerant"], "restart": ["wfTolerant"]}
NET = {"net": "L", "all": "L"}

GINV = ["GFinishedNoAbnormalExitK", "GFinishedNoLiveChild", "GTerminalNoLiveSJ", "GFinishedAllOutcomes",
        "GDoneSavedCompletedK", "GFreeAtMostOnce", "GNoFreeWhileAliveK", "GNoAllocAfterFree",
        "GNoChildWithoutAlloc", "GOneLiveLaunch"]
PINV = ["RClaimNeedsMaterialized", "RMaterializedIsRegistered", "RAggregateIsAccepted", "AcceptedWasClaimed",
        "RNoReleaseBeforeMaterialize",
        "ResendPreservesAuthority", "OneAssignmentRecordPerIdentity", "EnvelopeRefsRegistered",
        "EndRunAfterDone", "SavedAfterOkClose"]   # PropsMR: valid for any number of rounds
# left out: ReceivedMeansAccepted, RReceivedReceiptMeansFinished (a RECEIVED receipt after the workflow
# error retired the task -- seed receipt semantics ambiguous; lead for triage)
# known findings filtered (GenericProps "K" section): #5301, CANT_SCHEDULE over
# ABORTED via the K property variants; S02 and H30 states pruned (KnownPrune)
GPROP = ["GTerminalStableK", "GStatusStableK", "GOutcomeStable", "GExitStable"]
# (no CONSTRAINT pruning: K invariant forms + KnownStuck in the deadlock check)
EXT = ["Mix", "Props", "GenericProps", "PropsMR"]


def grain(fam, allfine=False):
    g = {k: ("F" if (allfine or k in FINE[fam]) else "C") for k in G}
    g["Net"] = NET.get(fam, "R")
    return g


def sim(name, fam, gr, sites, launch, attempt, T, timeout=1500, workers=6, depth=None, track="S",
        extra_prop=(), throttle=True):
    depth = depth or (800 if sites == 1 and attempt == 1 else 1500)
    return dict(name=name, track=track, family=fam, grain=gr, faults=FAM[fam], sites=sites, launch=launch,
                attempt=attempt, profile=PROFILE.get(fam, []), inv=GINV + PINV, prop=GPROP + list(extra_prop),
                extends=EXT + (["AG"] if extra_prop else []), known=True, deadlock=True, throttle=(T if throttle else None), mode="sim", depth=depth,
                timeout=timeout, workers=workers, heap="10g")


PLAN = []
INST = [("s2l1a2", 2, 1, 2), ("s2l2a2", 2, 2, 2), ("s1l2a2", 1, 2, 2)]
for fam in FAM:
    for iname, s, l, at in INST:
        for T in (20, 200):
            PLAN.append(sim(f"h4S_{fam}_fam_{iname}_t{T}", fam, grain(fam), s, l, at, T))
            if fam != "all":
                PLAN.append(sim(f"h4S_{fam}_allF_{iname}_t{T}", fam, grain(fam, True), s, l, at, T))

# per-site mixes: fine at s1 for the splittable groups of the family, coarse at s2
SPLIT = {"JobCP", "PaySrc", "RunCJ", "TaskCJ", "Trainer"}
for fam in FAM:
    gr = grain(fam)
    for k in SPLIT:
        if gr[k] == "F":
            gr[k] = "F@s1"
    PLAN.append(sim(f"h4P_{fam}_s2l2a2_t50", fam, gr, 2, 2, 2, 50, track="P"))

# rarity-bounded BFS (exhaustive within the budget if it finishes)
def bfs(name, fam, gr, sites, launch, attempt, K, timeout=1500, workers=12, track="B"):
    return dict(name=name, track=track, family=fam, grain=gr, faults=FAM[fam], sites=sites, launch=launch,
                attempt=attempt, profile=PROFILE.get(fam, []), inv=GINV + PINV, prop=GPROP,
                extends=EXT, deadlock=True, rarity=K, mode="bfs", known=True, timeout=timeout, workers=workers, heap="24g")


for fam in ["tail", "restart", "net", "job", "task"]:
    PLAN.append(bfs(f"h4B_{fam}_s1l2a1_k1", fam, grain(fam), 1, 2, 1, 1))
    PLAN.append(bfs(f"h4B_{fam}_s1l1a2_k1", fam, grain(fam), 1, 1, 2, 1))
    PLAN.append(bfs(f"h4R_{fam}_s1l1a1_k2", fam, grain(fam), 1, 1, 1, 2, track="R"))

# controls: the old way (no throttle) on the all-fine mixes
for fam in ["tail", "restart", "all"]:
    PLAN.append(sim(f"h4C_{fam}_allF_s2l1a2_nothr", fam, grain(fam, True), 2, 1, 2, 0, track="C",
                    throttle=False, timeout=900))

# assume-guarantee properties in throttled mixes
for fam in ["task", "restart", "all"]:
    PLAN.append(sim(f"h4A_{fam}_s2l2a2_t50", fam, grain(fam, True), 2, 2, 2, 50, track="A",
                    extra_prop=["AG_Trainer", "AG_RunCJ", "AG_Pay", "AG_WfSJ"]))

# re-runs of earlier runs whose violation TLC 2.20 swallowed (worker crash while
# reconstructing the trace), now on the v4 model and the newer TLC
import json, pathlib
_b2 = pathlib.Path(__file__).resolve().parents[1] / "checks" / "sweeps" / "blind2.jsonl"
_hid = ["blind2_CFFs1FFFFs2CCL_none_s2", "blind2_CFs1CFs1Fs2CFs1CFR_none_s2", "blind2_CFs1FFs1Fs1FFs1CCR_none_s2",
        "blind2_CFs1Fs2CFs2Fs1Fs1FCL_none_s2", "blind2_CFs2CFs1FCFFCR_none_s2", "blind2_FCCFs2Fs1Fs2FFCR_none_s2",
        "blind2_FFs1FFs2CFFs2CFL_none_s2"]
for l in _b2.read_text().splitlines():
    r = json.loads(l)
    if r["name"] in _hid:
        gr = dict(r["grain"])
        if isinstance(gr.get("PayRcv"), str) and "@" in gr["PayRcv"]:
            gr["PayRcv"] = "F"          # PayRcv is no longer site-splittable
        PLAN.append(dict(name="h4X_" + r["name"].replace("blind2_", "b2_"), track="X", family="none", grain=gr,
                         faults=[], sites=2, launch=1, attempt=1, inv=GINV + PINV, prop=GPROP, extends=EXT,
                         known=True,
                         deadlock=True, mode="sim", depth=1500, timeout=600, workers=4, heap="10g"))
for n in ["cmp_F10s_s2", "hz3_h30"]:
    PLAN.append(dict(name="h4X_" + n, track="X", family="minClients", prebuilt=True, mode="sim", depth=1500,
                     timeout=600, workers=4, heap="10g"))
