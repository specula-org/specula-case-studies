import sys; sys.path.insert(0, __file__.rsplit("/", 1)[0])
from smoke import batch
P = ["multiJobCP"]
J = []
def W(name, faults, inv, **kw):
    kw.setdefault("attempt", 1); kw.setdefault("launch", 2)
    J.append(dict(name="x11_f_" + name, profile=P, faults=faults, inv=[inv], tag=kw.pop("tag", "F"), **kw))
W("fin", [], "WFinished"); W("j2run", [], "WJ2Running"); W("j2free", [], "WJ2Freed")
W("j2restart", ["cjCrash"], "WJ2Restart"); W("busy", [], "WCheckBusy"); W("cant", [], "WCantSchedule")
W("cprestart", ["cpCrash", "rpcTimeout"], "WCPRestartBoth")
INV = ["AggregateIsAccepted", "AcceptedWasClaimed", "NoFreeWhileChildAlive", "AtMostOneFree"]
for nm, fl in [("dl0", []), ("dlF", ["cjCrash", "cpCrash", "rpcTimeout", "abort", "resExpiry"])]:
    J.append(dict(name=f"x11_f_{nm}", profile=P, faults=fl, inv=INV, deadlock=True, timeout=300, attempt=1, launch=2, tag="F-dl"))
batch(J, par=9)
