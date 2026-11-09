# v11 hunt, families with saveFail: SavedAfterOkClose (an aggregate only when the workflow did not
# fail) assumes no failure after aggregation; saveFail raises after it (real: persistor.save -> panic).
import runpy
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
P = runpy.run_path(str(ROOT / "plans" / "hunt11.py"))["PLAN"]
PLAN = [dict(p, name=p["name"] + "_nsc", inv=[i for i in p["inv"] if i != "SavedAfterOkClose"], timeout=2100)
        for p in P if p["family"] in ("fm", "sag", "cyc")]
