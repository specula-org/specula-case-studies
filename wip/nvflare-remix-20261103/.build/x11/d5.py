import sys; sys.path.insert(0, __file__.rsplit("/", 1)[0])
from smoke import batch
P = ["swarm"]
AC = ('(\\A k \\in DOMAIN net : (net\'[k].lost /\\ ~net[k].lost) => net[k].msg.kind \\in {"SWARM_END_WF", "SWARM_END_REPLY"})'
      ' /\\ ~(pWfSJ\'.panic /\\ ~pWfSJ.panic /\\ pWfSJ.cw = "monitor")')
J = [dict(name="x11_d5_endfail", profile=P, faults=["netLoss"], inv=["WSwEndFail"], sites=2, timeout=400, grain={"Net": "L"}, action_constraint=AC, tag="D")]
batch(J, par=1)
