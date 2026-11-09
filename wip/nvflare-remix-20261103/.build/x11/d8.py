import sys; sys.path.insert(0, __file__.rsplit("/", 1)[0])
from smoke import batch
P = ["swarm"]
ACP = '~(pWfSJ\'.panic /\\ ~pWfSJ.panic /\\ pWfSJ.cw = "monitor")'
J = [dict(name="x11_d8_mon", profile=P, faults=["netLoss"], inv=["WSwMonitor"], sites=2, timeout=200, tag="D-dbg"),
     dict(name="x11_d8_alldone", profile=P, faults=["netLoss"], inv=["WSwAllDoneSeen"], sites=2, timeout=200, action_constraint=ACP, tag="D-dbg")]
batch(J, par=2)
