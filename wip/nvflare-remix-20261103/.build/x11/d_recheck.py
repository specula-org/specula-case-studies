import sys; sys.path.insert(0, __file__.rsplit("/", 1)[0])
from smoke import batch
P = ["swarm"]
ACC = ('\\A c \\in Sites : (pRunCJ\'[c][1].exit = "crash" /\\ pRunCJ[c][1].exit = "none") => pWfSJ.cw = "monitor"')
J = [dict(name="x11_dr_fin", profile=P, faults=[], inv=["WFinished"], sites=2, tag="D"),
     dict(name="x11_dr_h05", profile=P, faults=[], inv=["WSwH05"], sites=2, tag="D"),
     dict(name="x11_dr_err", profile=P, faults=["learnFail"], inv=["WSwErrPanic"], sites=2, tag="D"),
     dict(name="x11_dr_crash", profile=P, faults=["cjCrash"], inv=["WSwProgress"], sites=2, action_constraint=ACC, tag="D"),
     dict(name="x11_dr_relaunch", profile=P, faults=["cjCrash", "learnFail"], inv=["WRelaunch"], sites=2, launch=2, tag="D"),
     dict(name="x11_dr_dl", profile=P, faults=["learnFail", "swarmMsgFail", "busyReplace", "gatherTimeout", "cjCrash"],
          inv=["AggregateIsAccepted", "AcceptedWasClaimed"], sites=2, launch=2, deadlock=True, timeout=300, tag="D-dl")]
batch(J, par=6)
