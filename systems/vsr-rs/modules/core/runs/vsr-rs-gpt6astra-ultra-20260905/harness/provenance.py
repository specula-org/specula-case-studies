#!/usr/bin/env python3
"""Bind the final harness, applied source, spec, traces and validation reports."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys

harness = Path(__file__).resolve().parent
source = Path(sys.argv[1]).resolve()
output = harness.parent

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def command(*args):
    result = subprocess.run(args, cwd=source, capture_output=True, text=True, check=True, timeout=30)
    return (result.stdout + result.stderr).strip()

copied = {"tla_trace.rs": "tla_trace.rs", "specula_trace.rs": "tests/specula_trace.rs",
          "controller.rs": "tests/specula_harness/controller.rs", "scenarios.rs": "tests/specula_harness/scenarios.rs"}
for canonical, applied in copied.items():
    assert sha(harness / "src" / canonical) == sha(source / applied), applied
results = json.loads((harness / "validation/results.json").read_text())
assert results["all_passed"], "validation did not pass"
for check in results["checks"]:
    assert sha(Path(check["path"])) == check["sha256"], "trace changed since validation"
for filename, expected in results["spec_sha256"].items():
    assert sha(Path(filename)) == expected, "spec changed since validation"
artifact_files = sorted([*harness.glob("*.sh"), *harness.glob("*.py"), *harness.glob("*.md"),
                         *harness.glob("src/*.rs"), *harness.glob("patches/*"), harness / "Cargo.lock"])
source_files = [source / p for p in ("lib.rs", "Cargo.toml", "Cargo.lock", *copied.values())]
validation_files = sorted(p for p in (harness / "validation").glob("*") if p.is_file() and p.name != "provenance.json")
report = {
    "created_utc": datetime.now(timezone.utc).isoformat(),
    "source_revision": command("git", "rev-parse", "HEAD"),
    "source_status": command("git", "status", "--short"),
    "tools": {"rustc": command("rustc", "--version"), "cargo": command("cargo", "--version"),
              "java": command("java", "-version"), "python": sys.version},
    "harness_sha256": {str(p.relative_to(harness)): sha(p) for p in artifact_files},
    "source_sha256": {str(p.relative_to(source)): sha(p) for p in source_files},
    "spec_sha256": results["spec_sha256"],
    "traces_sha256": {str(p.relative_to(output)): sha(p) for p in sorted((output / "traces").glob("*.ndjson"))},
    "validation_sha256": {str(p.relative_to(harness)): sha(p) for p in validation_files},
    "applied_copy_mapping": copied,
    "schedule": "Four deterministic Rust integration schedules; no random simulator seed. Raw nonces and timestamps use SystemTime; emitted wire nonces are injectively normalized per replica incarnation.",
}
(harness / "validation/provenance.json").write_text(json.dumps(report, indent=2) + "\n")
print("Source/spec/trace provenance recorded: harness/validation/provenance.json")
