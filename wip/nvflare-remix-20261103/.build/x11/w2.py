import sys; sys.path.insert(0, __file__.rsplit("/", 1)[0])
import smoke
from smoke import batch
smoke.EXT = smoke.EXT + ["WitLocalV11"]
J = [
 dict(name="x11_w2_sag_err", profile=["sag"], faults=["trainerError"], inv=["WSagErrPanic"], sites=2, tag="B"),
 dict(name="x11_w2_sag_to", profile=["sag"], faults=["taskTimeout"], inv=["WSagPartialFinished"], sites=2, tag="B"),
 dict(name="x11_w2_cyc_to", profile=["cyclic"], faults=["taskTimeout"], inv=["WCycTimeoutFinished"], sites=2, tag="B"),
 dict(name="x11_w2_cyc_err", profile=["cyclic"], faults=["trainerError"], inv=["WCycStop"], sites=2, tag="B"),
 dict(name="x11_w2_att_te", profile=[], faults=["trainerError"], inv=["WAttTrainerError"], grain={"Trainer": "A"}, tag="C"),
 dict(name="x11_w2_sw_start", profile=["swarm"], faults=["swarmMsgFail"], inv=["WSwStartFail"], sites=2, tag="D"),
 dict(name="x11_w2_sw_status", profile=["swarm"], faults=[], inv=["WSwStatusSeen"], sites=2, tag="D"),
 dict(name="x11_w2_j2abort", profile=["multiJobCP"], faults=["abort"], inv=["WFailedJob"], attempt=1, launch=2, tag="F"),
]
batch(J, par=8)
