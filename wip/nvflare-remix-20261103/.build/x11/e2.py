import sys; sys.path.insert(0, __file__.rsplit("/", 1)[0])
from smoke import batch
J = [dict(name="x11_e2_orphan_fin", profile=["k8sJob"], faults=["cpCrash", "rpcTimeout", "outcomeTimeout"], inv=["WFinished"],
          attempt=1, launch=2, timeout=300, tag="E"),
     dict(name="x11_e2_orphan_fin_proc", profile=[], faults=["cpCrash", "rpcTimeout", "outcomeTimeout"], inv=["WFinished"],
          attempt=1, launch=2, timeout=300, tag="E-ctrl")]
batch(J, par=2)
