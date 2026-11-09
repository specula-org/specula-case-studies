import sys; sys.path.insert(0, __file__.rsplit("/", 1)[0])
from smoke import batch
P = ["swarm"]
J = []
def W(name, faults, inv, **kw):
    J.append(dict(name="x11_d2_" + name, profile=P, faults=faults, inv=[inv], sites=2, timeout=600, tag="D", **kw))
W("h06", ["busyReplace", "gatherTimeout"], "WSwH06")
W("h06fin", ["busyReplace", "gatherTimeout"], "WSwH06Finished")
W("crash", ["cjCrash"], "WSwProgress")
W("endfail", ["netLoss"], "WSwEndFail", grain={"Net": "L"})
batch(J, par=4)
