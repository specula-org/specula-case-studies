import sys; sys.path.insert(0, __file__.rsplit("/", 1)[0])
import smoke
from smoke import batch
smoke.EXT = smoke.EXT + ["AG"]
J = [dict(name="x11_ag_swarm", profile=["swarm"], faults=["learnFail", "cjCrash", "taskTimeout"], inv=[],
          prop=["AG_WfSJ", "AG_Pay", "AG_RunCJ"], sites=2, timeout=300, tag="D-AG")]
batch(J, par=1)
