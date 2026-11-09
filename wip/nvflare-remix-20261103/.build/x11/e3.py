import sys; sys.path.insert(0, __file__.rsplit("/", 1)[0])
from smoke import batch
J = [dict(name="x11_e3_orphanfail", profile=["k8sJob"], faults=["cpCrash", "rpcTimeout"], inv=["WOrphanFail"],
          attempt=1, launch=1, timeout=300, tag="E"),
     dict(name="x11_e3_orphanfail_ot", profile=["k8sJob"], faults=["cpCrash", "rpcTimeout", "outcomeTimeout"], inv=["WOrphanFail"],
          attempt=1, launch=1, timeout=300, tag="E")]
batch(J, par=2)
