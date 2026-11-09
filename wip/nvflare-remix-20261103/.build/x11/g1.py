import sys; sys.path.insert(0, __file__.rsplit("/", 1)[0])
from smoke import batch
J = []
def W(name, prof, faults, inv, **kw):
    J.append(dict(name="x11_g_" + name, profile=prof, faults=faults, inv=[inv], tag=kw.pop("tag", "G"), **kw))
W("samp", ["sampling"], [], "WSampled", sites=2); W("samp_fin", ["sampling"], [], "WSampledFinished", sites=2)
W("sync", [], ["sjSyncFail"], "WSyncFail"); W("data", [], ["taskDataFail"], "WTaskDataResend")
W("data_cse", ["cseServer"], ["taskDataFail"], "WMonitorDead")
INV = ["AggregateIsAccepted", "AcceptedWasClaimed", "NoFreeWhileChildAlive", "AtMostOneFree"]
for nm, prof, fl, st in [("dl_samp", ["sampling"], ["taskTimeout"], 2), ("dl_G", [], ["sjSyncFail", "taskDataFail"], 1)]:
    J.append(dict(name=f"x11_g_{nm}", profile=prof, faults=fl, inv=INV, deadlock=True, timeout=300, sites=st, tag="G-dl"))
batch(J, par=7)
