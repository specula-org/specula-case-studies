import sys; sys.path.insert(0, __file__.rsplit("/", 1)[0])
from smoke import batch
P = ["swarm"]
ACE = ('\\A c \\in Sites : (pRunCJ\'[c][1].exit = "crash" /\\ pRunCJ[c][1].exit = "none") => pWfSJ.cw = "ending"')
J = [dict(name="x11_d7_endfail", profile=P, faults=["cjCrash"], inv=["WSwEndFail"], sites=2, timeout=300, action_constraint=ACE, tag="D")]
batch(J, par=1)
