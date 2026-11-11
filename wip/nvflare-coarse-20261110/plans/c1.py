# Chunk 1 (PROMPT step 5): SP/CP process entry and restart, registration, heartbeat,
# server admin. Same configurations, phases, budgets and slicing as gate 1 (frozen
# mechanism, STANDARD v5). Cells: every cell that involves a chunk-1 failure point
# (adminRemove, adminDisable, slowRegister, loginError), as a single point or in a
# pair, plus the single cells of the two ops events whose behavior chunk 1 changed
# (cpCrash: the restarted CP now goes through Login; spShutdown: the admin precheck).
import runpy
_g = runpy.run_path(__file__.replace("c1.py", "gate1.py"))
DEPS = dict(_g["DEPS"], slowRegister=["cpCrash"], loginError=["cpCrash"])
C1 = ["adminRemove", "adminDisable", "slowRegister", "loginError"]
CONFIGS = {k: dict(cf, points=list(dict.fromkeys(cf["points"] + C1))) for k, cf in _g["CONFIGS"].items()}
BUDGET_EXTRA = _g["BUDGET_EXTRA"]
PAIR_PHASES = _g["PAIR_PHASES"]
SLICE = True
FILTERS = {}
import os
if os.environ.get("C1_FILTERS"):
    for _f in os.environ["C1_FILTERS"].split(","):
        FILTERS.update(runpy.run_path(_f)["FILTERS"])


def KEEP(cell):
    pts = cell["point"].split("__")
    return any(p in C1 for p in pts) or (cell["kind"] == "single" and cell["point"] in ("cpCrash", "spShutdown"))
