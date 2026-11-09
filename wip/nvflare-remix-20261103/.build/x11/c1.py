import sys; sys.path.insert(0, __file__.rsplit("/", 1)[0])
import smoke
from smoke import batch
smoke.EXT = smoke.EXT + ["WitLocalV11"]
G = dict(Trainer="A")
J = []
def W(name, faults, inv, **kw):
    J.append(dict(name="x11_c_" + name, profile=[], faults=faults, inv=[inv], grain=G, tag=kw.pop("tag", "C"), **kw))
W("fin", [], "WFinished"); W("pub", [], "WAttPublished"); W("stop", [], "WAttStopped")
W("late", ["tpAttachLate"], "WAttErr"); W("crash", ["tpCrash"], "WAttErr"); W("lost", ["tpReplyLost"], "WAttErr")
W("h01", ["tpReplyLost"], "WAttH01"); W("rwt", ["resultWaitTimeout"], "WAttErr")
W("crash_fin", ["tpCrash"], "WAttErrFinished"); W("reattach", ["tpCrash"], "WAttReattach")
W("silent", ["tpSilent"], "WAttErr")
for nm, fl in [("dl0", []), ("dlF", ["tpAttachLate", "tpCrash", "tpReplyLost", "resultWaitTimeout", "trainerError"])]:
    J.append(dict(name=f"x11_c_{nm}", profile=[], faults=fl, grain=G, deadlock=True, timeout=300, tag="C-dl",
                  inv=["AggregateIsAccepted", "AcceptedWasClaimed", "NoFreeWhileChildAlive", "AtMostOneFree"]))
batch(J, par=13)
