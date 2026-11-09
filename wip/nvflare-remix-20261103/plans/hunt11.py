# v11 hunt (90 min): fused simulation over every v11 profile with the generic property
# set of hunt8 (known findings filtered); v11 lead properties are left to hunt11_leads.
import runpy
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
P8 = runpy.run_path(str(ROOT / "plans" / "hunt8.py"))["PLAN"]
base = [p for p in P8 if p["track"] == "S"][0]
G = dict(JobSP="F", RunCJ="F", JobCP="C", TaskCJ="C", Trainer="C", PaySrc="C", PayRcv="C", CommSJ="C", WfSJ="C",
         Reg="C", Model="C", Swarm="C", Net="R")
COMMON = dict(track="V", inv=base["inv"], prop=base["prop"], extends=base["extends"] + ["WitV11", "JobPhase"],
              known=True, heap="16g", symmetry=False, rarity=4, throttle=20, fuse=True, deadlock=True,
              mode="sim", depth=2500, timeout=2400, workers=6)
FAM = [
    ("fm", ["sjModel"], {}, ["acceptRaise", "saveFail", "cbFail", "cjCrash", "taskTimeout"], 2),
    ("sag", ["sjModel", "sag"], {}, ["acceptRaise", "saveFail", "cbFail", "taskTimeout", "trainerError", "cjCrash"], 2),
    ("cyc", ["sjModel", "cyclic"], {}, ["cbFail", "saveFail", "taskTimeout", "trainerError", "cjCrash", "deadClient"], 2),
    ("cse", ["cseServer"], {}, ["cbFail", "taskTimeout", "taskDataFail", "cjCrash", "submitTimeout"], 2),
    ("att", [], {"Trainer": "A"}, ["tpAttachLate", "tpCrash", "tpReplyLost", "tpSilent", "resultWaitTimeout", "trainerError", "cjCrash"], 2),
    ("swarm", ["swarm"], {}, ["swarmMsgFail", "learnFail", "busyReplace", "gatherTimeout", "cjCrash"], 2),
    ("k8s", ["k8sJob"], {}, ["podDeleteFail", "slowPublish", "cjCrash", "cpCrash", "abort", "rpcTimeout"], 1),
    ("docker", ["dockerJob"], {}, ["cjCrash", "cpCrash", "abort", "rpcTimeout", "deleteJob"], 1),
    ("mjcp", ["multiJobCP"], {}, ["cjCrash", "cpCrash", "abort", "rpcTimeout", "resExpiry"], 1),
    ("samp", ["sampling"], {}, ["taskTimeout", "cjCrash", "deadClient", "submitTimeout"], 2),
    ("gaps", [], {}, ["sjSyncFail", "taskDataFail", "cjCrash", "taskTimeout", "abort"], 2),
    ("combo", ["k8sJob", "sjModel", "sampling"], {}, ["cpCrash", "acceptRaise", "podDeleteFail", "rpcTimeout", "cjCrash"], 2),
]
# V8 (lead, model-level): under k8sJob / dockerJob a CP restart leaves the surviving CJ
# without an allocation on the restarted CP (GNoChildWithoutAlloc in a few steps); filtered there.
CONTAINER = {"k8s", "docker", "combo"}
PLAN = []
for fam, prof, grain, faults, sites in FAM:
    inv = [i for i in COMMON["inv"] if not (fam in CONTAINER and i == "GNoChildWithoutAlloc")]
    PLAN.append(dict(COMMON, name=f"h11_{fam}_s{sites}l2a2", family=fam, profile=prof, grain=dict(G, **grain),
                     faults=faults, sites=sites, launch=2, attempt=2, inv=inv))
    PLAN.append(dict(COMMON, name=f"h11_{fam}_s{sites}l2a2_b", family=fam, profile=prof, grain=dict(G, **grain),
                     faults=faults, sites=sites, launch=2, attempt=2, timeout=2400, inv=inv))
