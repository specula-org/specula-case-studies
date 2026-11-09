import sys; sys.path.insert(0, __file__.rsplit("/", 1)[0])
from smoke import batch
J = []
def W(name, prof, faults, inv, **kw):
    kw.setdefault("attempt", 1); kw.setdefault("launch", 2)
    J.append(dict(name="x11_e_" + name, profile=prof, faults=faults, inv=[inv], tag=kw.pop("tag", "E"), **kw))
K, D = ["k8sJob"], ["dockerJob"]
W("k_fin", K, [], "WFinished"); W("d_fin", D, [], "WFinished")
W("k_pub", K, [], "WPubDone")
W("k_orphan", K, ["cpCrash", "rpcTimeout"], "WOrphanCJ"); W("d_orphan", D, ["cpCrash", "rpcTimeout"], "WOrphanCJ")
W("k_h20", K, ["podDeleteFail", "abort"], "WFreeWhileAlive", timeout=300)
W("k_relaunch", K, ["cjCrash"], "WRelaunch")
W("k_h07", K, ["slowPublish", "cjCrash"], "WWsLost", timeout=300)
W("k_orphan_fin", K, ["cpCrash", "rpcTimeout"], "WFinished", timeout=300)
INV = ["AggregateIsAccepted", "AcceptedWasClaimed", "AtMostOneFree"]
for nm, prof, fl in [("k_dl0", K, []), ("k_dlF", K, ["podDeleteFail", "abort", "slowPublish", "cjCrash", "cpCrash", "rpcTimeout"]),
                     ("d_dlF", D, ["abort", "cjCrash", "cpCrash", "rpcTimeout"])]:
    J.append(dict(name=f"x11_e_{nm}", profile=prof, faults=fl, inv=INV, deadlock=True, timeout=300, attempt=1, launch=2, tag="E-dl"))
batch(J, par=12)
