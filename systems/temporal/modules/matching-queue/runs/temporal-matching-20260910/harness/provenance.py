#!/usr/bin/env python3
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
harness = Path(__file__).resolve().parent
source, traces, run_id = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
old = [p for p in traces.iterdir() if p.is_file()]
if old:
    archive = traces / "archive" / run_id
    archive.mkdir(parents=True, exist_ok=False)
    for p in old:
        shutil.move(str(p), archive / p.name)
files = list((harness / "src").glob("*.go")) + list((harness / "patches").glob("*.patch")) + [
    harness.parent / "spec" / n for n in ("base.tla", "Trace.tla", "Trace.cfg", "MC.tla")]
data = {
    "run_id": run_id,
    "source": str(source.resolve()),
    "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip(),
    "go": subprocess.check_output(["go", "version"], cwd=source, text=True).strip(),
    "build_tags": ["test_dep"],
    "backend": "file-backed SQLite, SQL TaskStore V1",
    "history": "controlled interface fixture; real Matching and production History retry client, no History internals",
    "sql_effect_schedule": "serialized store effects with independently gated response delivery",
    "root_validator": "controlled gate; separate valid-requeue and obsolete-validator scenarios exercise the real root loop and actual age guard",
    "sha256": {os.path.relpath(p, harness): hashlib.sha256(p.read_bytes()).hexdigest() for p in files},
}
(harness / "logs" / "provenance.json").write_text(json.dumps(data, indent=2) + "\n")
