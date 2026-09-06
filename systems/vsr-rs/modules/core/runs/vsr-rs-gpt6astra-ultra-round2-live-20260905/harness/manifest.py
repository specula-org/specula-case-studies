#!/usr/bin/env python3
"""Bind this successful run to its source, harness, spec and implementation traces."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
from datetime import datetime, timezone

harness = Path(__file__).resolve().parent
source = Path(os.environ.get("SOURCE_DIR", harness.parent.parent / "source")).resolve()
traces = Path(os.environ.get("TRACE_DIR", harness.parent / "traces")).resolve()
files = [harness / name for name in (
    "apply.sh", "clean.sh", "run.sh", "validate.sh", "audit_traces.py", "manifest.py",
    "Cargo.lock", "INSTRUMENTATION.md", "VALIDATION.md", "patches/instrumentation.patch")]
files += sorted((harness / "src").glob("*.rs"))
files += [source / name for name in ("Cargo.toml", "Cargo.lock", "lib.rs")]
for path in sorted((harness / "src").glob("*.rs")):
    copied = source / "tla_trace" / path.name
    assert copied.read_bytes() == path.read_bytes(), f"Unadopted harness edit: {path}"
    files.append(copied)
files += [harness.parent / "spec" / name for name in ("base.tla", "Trace.tla", "Trace.cfg", "instrumentation-spec.md")]
files += sorted(traces.glob("*.ndjson")) + sorted(traces.glob("*.complete.json"))
files += [harness / "validation" / name for name in ("audit.json", "results.tsv")]
files += sorted((harness / "validation").glob("*.log"))
manifest = {
    "generated_at": datetime.now(timezone.utc).isoformat(),
    "source_revision": subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip(),
    "rustc": subprocess.check_output(["rustc", "--version"], text=True).strip(),
    "cargo": subprocess.check_output(["cargo", "--version"], text=True).strip(),
    "files": [{"path": str(path.resolve()), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
              for path in files],
    "scope": "Real core-library traces with ideal owner persistence; no kvstore filesystem, socket, singleton, clock-policy or DST oracle confirmation.",
}
(harness / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(f"Saved {harness / 'manifest.json'}")
