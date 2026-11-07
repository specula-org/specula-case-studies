# hunt8 D-track rediscovery of the v8 findings at full length (T2, T3, L13, C1-B cross-job)
import runpy
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
PLAN = [p for p in runpy.run_path(str(ROOT / "plans" / "hunt8.py"))["PLAN"]
        if p["track"] == "D" and p["family"] in ("reg", "status", "multi")]
