import sys; sys.path.insert(0, __file__.rsplit("/", 1)[0])
from smoke import go, batch
M = ["sjModel"]
J = []
def W(name, prof, faults, inv, **kw):
    J.append(dict(name="x11_" + name, profile=prof, faults=faults, inv=[inv], tag=kw.pop("tag", "AB"), **kw))
# A: FedAvg + Model
W("a_acc", M, [], "WAccepted"); W("a_rej", M, [], "WRejected"); W("a_artc", M, [], "WArtClean")
W("a_part", M, ["acceptRaise"], "WPartial"); W("a_guard", M, ["acceptRaise"], "WFedPoisonFailed")
W("a_corrupt", M, ["saveFail"], "WArtCorrupt"); W("a_savepanic", M, ["saveFail"], "WSaveFailPanic")
# expected unreachable under FedAvg's guard (bounded sim, no violation expected)
W("a_noagg", M, ["acceptRaise", "saveFail"], "WAggPoisoned", timeout=300, tag="AB-neg")
# B: SAG
S = M + ["sag"]
W("b_sag_aggp", S, ["acceptRaise"], "WAggPoisoned"); W("b_sag_artp", S, ["acceptRaise"], "WArtPoisoned")
W("b_sag_finp", S, ["acceptRaise"], "WFinishedPoisoned"); W("b_sag_empty", S, [], "WArtStale")
W("b_sag_raise", S, ["acceptRaise"], "WAggRaisePanic"); W("b_sag_cb", ["sag"], ["cbFail"], "WRaised")
W("b_sag_nomodel", ["sag"], [], "WFinished")
# B: Cyclic
W("b_cyc_stop", ["cyclic"], ["cbFail"], "WCycStop"); W("b_cyc_stopfin", ["cyclic"], ["cbFail"], "WCycStopFinished")
W("b_cyc_model", ["sjModel", "cyclic"], ["saveFail"], "WSaveFailPanic")
# B: server CSE
W("b_cse_done", ["cseServer"], [], "WCseDone"); W("b_cse_mon", ["cseServer"], [], "WMonitorDead")
W("b_cse_cb", ["cseServer"], ["cbFail"], "WRaised")
# deadlock (hang) checks, no faults: expected clean except cseServer (monitor death = H11 class)
for nm, prof in [("fm", M), ("sag", S), ("cyc", ["sjModel", "cyclic"]), ("cse", ["cseServer"])]:
    J.append(dict(name=f"x11_dl_{nm}", profile=prof, faults=[], inv=["PortSafety"], deadlock=True, timeout=300, tag="AB-dl"))
batch(J, par=12)
