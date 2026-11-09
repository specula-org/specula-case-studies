import sys; sys.path.insert(0, __file__.rsplit("/", 1)[0])
from smoke import batch
P = ["swarm"]
ACP = '~(pWfSJ\'.panic /\\ ~pWfSJ.panic /\\ pWfSJ.cw = "monitor")'
J = [dict(name="x11_d6_endR", profile=P, faults=["netLoss"], inv=["WSwEnding"], sites=2, timeout=200, action_constraint=ACP, tag="D-dbg"),
     dict(name="x11_d6_mon", profile=P, faults=["netLoss"], inv=["WSwEnding"], sites=2, timeout=200, tag="D-dbg"),
     dict(name="x11_d6_end0", profile=P, faults=[], inv=["WSwEnding"], sites=2, timeout=200, tag="D-dbg")]
batch(J, par=3)
