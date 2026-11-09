"""v11 non-interference: the same BFS configurations on the pre-v11 spec (5b6f008d,
.tmp/v10ws) and on the current spec, all v11 switches off; compare distinct states."""
import json, subprocess, sys
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
ROOT = Path(__file__).resolve().parents[2]
OLD = ROOT / ".tmp" / "v10ws"
# whole-job BFS from Init does not finish (v7 diagnosis); the same depth bound on both trees
CONFIGS = {
  "ni_allC": dict(grain={}, faults=["cjCrash", "taskTimeout"], sites=1, launch=2, attempt=1, profile=[], level=40),
  "ni_fine": dict(grain={"JobCP": "F", "RunCJ": "F", "TaskCJ": "F", "CommSJ": "F", "WfSJ": "F"}, faults=[], sites=1, launch=1, attempt=1, profile=[], level=45),
  "ni_cse": dict(grain={}, faults=["cbFail"], sites=2, launch=1, attempt=1, profile=["cseTasks"], level=30),
  "ni_task": dict(grain={"Worker": "F", "TaskCJ": "F", "JobCP": "F"}, faults=["workerCrash"], sites=1, launch=2, attempt=1, profile=["taskMode"], level=40),
}
CODE = """
import sys, json
sys.path.insert(0, %r)
import mkmc, run_mc
cfg = json.loads(%r)
mkmc.build(%r, grain=cfg['grain'], faults=cfg['faults'], sites=cfg['sites'], launch=cfg['launch'], attempt=cfg['attempt'],
           inv=[], prop=[], symmetry=False, deadlock=False, profile=cfg['profile'], constraint='LevelBound',
           extra_defs='LevelBound == TLCGet("level") <= %%d' %% cfg['level'])
r = run_mc.run(%r, 1200, 12, 'bfs', (0, 0), '24g')
print(json.dumps({k: r.get(k) for k in ('result', 'distinct', 'generated', 'depth', 'wall_seconds', 'error')}))
"""
def run(ws, name, cfg):
    code = CODE % (str(ws / "scripts"), json.dumps(cfg), name, name)
    p = subprocess.run([sys.executable, "-B", "-c", code], capture_output=True, text=True, cwd=ws,
                       env={"PYTHONDONTWRITEBYTECODE": "1", "PATH": "/usr/bin:/bin", "MIX_INCLUDE_WIP": "all"})
    out = p.stdout.strip().splitlines()
    return json.loads(out[-1]) if out else {"error": p.stderr[-500:]}
jobs = []
with ThreadPoolExecutor(8) as ex:
    for name, cfg in CONFIGS.items():
        jobs.append((name, "old", ex.submit(run, OLD, name, cfg)))
        jobs.append((name, "new", ex.submit(run, ROOT, name, cfg)))
    res = {}
    for name, which, f in jobs:
        res.setdefault(name, {})[which] = f.result()
        print(name, which, json.dumps(res[name][which]), flush=True)
(ROOT / ".build" / "x11" / "ni_results2.json").write_text(json.dumps(res, indent=1))
