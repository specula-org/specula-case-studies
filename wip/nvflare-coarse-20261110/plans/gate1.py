# Gate 1 (PROMPT step 3): the calibration configurations with the v4 sweep mechanism.
# FILTERS start empty (pass A); later passes add cause-record filters, each naming the
# property items it exempts.
import runpy
_c = runpy.run_path(__file__.replace("gate1.py", "calib2.py"))
DEPS = {k: v for k, v in _c["DEPS"].items() if k != "slowShutdownExit"}
CONFIGS = _c["CONFIGS"]
# message loss by channel (STANDARD 12 v4): replaces the all-kinds netLoss point
_CH = ["netLossJobSP", "netLossJobCP", "netLossRunCJ", "netLossTaskCJ", "netLossCommSJ", "netLossWfSJ",
       "netLossPaySrc", "netLossPayRcv"]
for _k, _cf in CONFIGS.items():
    _pts = [p for p in _cf["points"] if p != "netLoss"] + _CH + (["netLossSwarm"] if "swarm" in _cf["profile"] else [])
    CONFIGS[_k] = dict(_cf, points=_pts)
BUDGET_EXTRA = 2
PAIR_PHASES = [1, 2, 3]
SLICE = True
FILTERS = {}
import os
if os.environ.get("GATE1_FILTERS"):      # cause-record filters of earlier passes (scripts/mkfilters.py)
    for _f in os.environ["GATE1_FILTERS"].split(","):
        FILTERS.update(runpy.run_path(_f)["FILTERS"])
