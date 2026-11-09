import sys; sys.path.insert(0, __file__.rsplit("/", 1)[0])
import smoke
from smoke import batch
smoke.EXT = smoke.EXT + ["AG"]
AG = ["AG_WfSJ", "AG_Pay", "AG_RunCJ", "AG_Trainer"]
J = []
for nm, prof, fl in [("fm", ["sjModel"], ["acceptRaise", "saveFail", "cbFail"]),
                     ("sag", ["sjModel", "sag"], ["acceptRaise", "saveFail", "cbFail", "taskTimeout"]),
                     ("cyc", ["sjModel", "cyclic"], ["cbFail", "saveFail", "taskTimeout"]),
                     ("cse", ["cseServer"], ["cbFail", "taskTimeout"])]:
    J.append(dict(name=f"x11_ag_{nm}", profile=prof, faults=fl, inv=[], prop=AG, sites=2, timeout=300, tag="AB-AG"))
batch(J, par=4)
