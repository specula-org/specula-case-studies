import sys; sys.path.insert(0, __file__.rsplit("/", 1)[0])
from smoke import go, batch
INV = ["AggregateIsAccepted", "AcceptedWasClaimed", "NoFreeWhileChildAlive", "AtMostOneFree", "ClaimNeedsMaterialized"]
J = []
for nm, prof, fl in [("fm", ["sjModel"], []), ("sag", ["sjModel", "sag"], []),
                     ("fmF", ["sjModel"], ["acceptRaise", "saveFail"]), ("sagF", ["sjModel", "sag"], ["acceptRaise", "saveFail", "cbFail"]),
                     ("cycF", ["sjModel", "cyclic"], ["cbFail", "saveFail"]), ("cseF", ["cseServer"], ["cbFail"])]:
    J.append(dict(name=f"x11_dl2_{nm}", profile=prof, faults=fl, inv=INV, deadlock=True, timeout=300, tag="AB-dl"))
batch(J, par=6)
