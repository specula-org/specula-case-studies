import sys; sys.path.insert(0, __file__.rsplit("/", 1)[0])
from smoke import go, batch
jobs = [
  dict(name="x11_base_term", profile=[], faults=[], inv=["WTerminal"], tag="base"),
  dict(name="x11_fm_term", profile=["sjModel"], faults=[], inv=["WFinished"], tag="A"),
  dict(name="x11_sag_term", profile=["sjModel", "sag"], faults=[], inv=["WFinished"], tag="B"),
  dict(name="x11_cyc_term", profile=["sjModel", "cyclic"], faults=[], inv=["WFinished"], tag="B"),
  dict(name="x11_cse_term", profile=["cseServer"], faults=[], inv=["WFinished"], tag="B"),
]
batch(jobs, par=5)
