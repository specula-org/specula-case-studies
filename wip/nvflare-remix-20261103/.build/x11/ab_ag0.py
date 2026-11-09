import sys; sys.path.insert(0, __file__.rsplit("/", 1)[0])
import smoke
from smoke import batch
smoke.EXT = smoke.EXT + ["AG"]
J = [dict(name="x11_ag_base", profile=[], faults=["cbFail", "saveFail", "acceptRaise"], inv=[], prop=["AG_Trainer"], sites=2, timeout=200, tag="AB-AG"),
     dict(name="x11_ag_base2", profile=[], faults=["cbFail"], inv=[], prop=["AG_WfSJ", "AG_Pay", "AG_RunCJ"], sites=2, timeout=200, tag="AB-AG")]
batch(J, par=2)
