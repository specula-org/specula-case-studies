import sys; sys.path.insert(0, __file__.rsplit("/", 1)[0])
from smoke import batch
P = ["swarm"]
J = []
def W(name, faults, inv, **kw):
    J.append(dict(name="x11_d_" + name, profile=P, faults=faults, inv=[inv], sites=2, tag=kw.pop("tag", "D"), **kw))
W("fin", [], "WFinished"); W("agg2", [], "WSwAgg2"); W("h05", [], "WSwH05")
W("h06", ["busyReplace"], "WSwH06"); W("h06fin", ["busyReplace"], "WSwH06Finished", timeout=300)
W("err", ["learnFail"], "WSwErrPanic"); W("msgfail", ["swarmMsgFail"], "WSwErrPanic")
W("crash", ["cjCrash"], "WSwPanicNoErr"); W("cfg", ["cjCrash", "taskTimeout"], "WSwCfgPanic")
W("endfail", ["netLoss"], "WSwEndFail"); W("gto", ["gatherTimeout"], "WSwGatherTimeoutPartial")
W("failed", ["learnFail"], "WFailedJob")
INV = ["AggregateIsAccepted", "AcceptedWasClaimed", "NoFreeWhileChildAlive", "AtMostOneFree"]
for nm, fl in [("dl0", []), ("dlF", ["learnFail", "swarmMsgFail", "busyReplace", "gatherTimeout", "cjCrash"])]:
    J.append(dict(name=f"x11_d_{nm}", profile=P, faults=fl, inv=INV, sites=2, deadlock=True, timeout=300, tag="D-dl"))
batch(J, par=14)
