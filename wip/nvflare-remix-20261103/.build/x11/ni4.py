import json, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import mkmc, run_mc
mkmc.build("ni_allC32", grain={}, faults=["cjCrash", "taskTimeout"], sites=1, launch=2, attempt=1, inv=[], prop=[],
           symmetry=False, deadlock=False, profile=[], constraint="LevelBound", extra_defs='LevelBound == TLCGet("level") <= 32')
r = run_mc.run("ni_allC32", 2700, 24, "bfs", (0, 0), "32g")
print(json.dumps({k: r.get(k) for k in ("result", "distinct", "generated", "depth", "wall_seconds")}))
