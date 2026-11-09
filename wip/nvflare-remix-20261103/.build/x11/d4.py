import sys; sys.path.insert(0, __file__.rsplit("/", 1)[0])
from smoke import batch
P = ["swarm"]
AC = ('\\A k \\in DOMAIN net : (net\'[k].lost /\\ ~net[k].lost) => net[k].msg.kind \\in {"SWARM_END_WF", "SWARM_END_REPLY"}')
ACC = ('\\A c \\in Sites : (pRunCJ\'[c][1].exit = "crash" /\\ pRunCJ[c][1].exit = "none") => pWfSJ.cw = "monitor"')
J = [dict(name="x11_d4_ending", profile=P, faults=["netLoss"], inv=["WSwEnding"], sites=2, timeout=300, grain={"Net": "L"}, action_constraint=AC, tag="D"),
     dict(name="x11_d4_endlost", profile=P, faults=["netLoss"], inv=["WSwEndLost"], sites=2, timeout=300, grain={"Net": "L"}, action_constraint=AC, tag="D"),
     dict(name="x11_d4_endfail", profile=P, faults=["netLoss"], inv=["WSwEndFail"], sites=2, timeout=300, grain={"Net": "L"}, action_constraint=AC, tag="D"),
     dict(name="x11_d4_moncrash", profile=P, faults=["cjCrash"], inv=["WSwMonCrash"], sites=2, timeout=300, action_constraint=ACC, tag="D"),
     dict(name="x11_d4_crash", profile=P, faults=["cjCrash"], inv=["WSwProgress"], sites=2, timeout=300, action_constraint=ACC, tag="D")]
batch(J, par=5)
