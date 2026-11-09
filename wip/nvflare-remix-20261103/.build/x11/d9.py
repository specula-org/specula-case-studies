import sys; sys.path.insert(0, __file__.rsplit("/", 1)[0])
from smoke import batch
J = [dict(name="x11_d9_term", profile=["swarm"], faults=["netLoss"], inv=["WTerminal"], sites=2, timeout=200, tag="D-dbg"),
     dict(name="x11_d9_r2", profile=["swarm"], faults=["netLoss"], inv=["WRound2"], sites=2, timeout=200, tag="D-dbg")]
batch(J, par=2)
