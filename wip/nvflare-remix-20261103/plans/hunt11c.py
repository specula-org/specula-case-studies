# v11 hunt, extra 12 minutes: cross-block combinations not covered by hunt11 (same property set and filters).
import runpy
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
H = runpy.run_path(str(ROOT / "plans" / "hunt11.py"))
COMMON, G = H["COMMON"], H["G"]
inv_nc = [i for i in COMMON["inv"] if i not in ("GNoChildWithoutAlloc", "SavedAfterOkClose")]
COMBOS = [
    ("cyc_k8s", ["sjModel", "cyclic", "k8sJob"], {}, ["cbFail", "cpCrash", "podDeleteFail", "slowPublish", "cjCrash", "rpcTimeout"], 2),
    ("sag_mjcp", ["sjModel", "sag", "multiJobCP"], {}, ["acceptRaise", "cjCrash", "cpCrash", "resExpiry", "rpcTimeout"], 2),
    ("att_samp", ["sampling"], {"Trainer": "A"}, ["tpCrash", "tpReplyLost", "taskTimeout", "cjCrash"], 2),
    ("swarm_docker", ["swarm", "dockerJob"], {}, ["learnFail", "busyReplace", "gatherTimeout", "cjCrash", "cpCrash", "rpcTimeout"], 2),
    ("cse_k8s", ["cseServer", "k8sJob"], {}, ["taskDataFail", "cbFail", "podDeleteFail", "cjCrash", "cpCrash", "rpcTimeout"], 2),
    ("samp_docker", ["sampling", "dockerJob", "sjModel"], {}, ["acceptRaise", "saveFail", "cpCrash", "cjCrash", "rpcTimeout"], 2),
]
PLAN = []
for fam, prof, grain, faults, sites in COMBOS:
    for k in ("", "_b"):
        PLAN.append(dict(COMMON, name=f"h11c_{fam}{k}", family=fam, profile=prof, grain=dict(G, **grain),
                         faults=faults, sites=sites, launch=2, attempt=2, inv=inv_nc, timeout=720))
