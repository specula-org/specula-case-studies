import sys; sys.path.insert(0, __file__.rsplit("/", 1)[0])
import smoke
from smoke import batch, go
import mkmc
P = ["swarm"]
AC = ('\\A k \\in DOMAIN net : (net\'[k].lost /\\ ~net[k].lost) => net[k].msg.kind \\in {"SWARM_END_WF", "SWARM_END_REPLY"}')
J = [dict(name="x11_d3_moncrash", profile=P, faults=["cjCrash"], inv=["WSwMonCrash"], sites=2, timeout=600, tag="D"),
     dict(name="x11_d3_crash", profile=P, faults=["cjCrash"], inv=["WSwProgress"], sites=2, timeout=600, tag="D", depth=(600, 4000)),
     dict(name="x11_d3_endfail", profile=P, faults=["netLoss"], inv=["WSwEndFail"], sites=2, timeout=600, tag="D",
          grain={"Net": "L"}, action_constraint=AC)]
batch(J, par=3)
