#!/usr/bin/env bash
set -euo pipefail
harness_dir="$(cd "$(dirname "$0")" && pwd)"
source_dir="${1:-${SOURCE_DIR:-/home/ubuntu/temporal-investigation-20260909/parallel-20260910/source-matching}}"
python3 - "$harness_dir" "$source_dir" <<'PY'
import json
import subprocess
import sys
from pathlib import Path
h, s = map(Path, sys.argv[1:])
modules = {
    "specula_trace.go": "service/matching/specula_trace.go",
    "specula_observer_test.go": "service/matching/specula_observer_test.go",
    "specula_scenarios_test.go": "service/matching/specula_scenarios_test.go",
    "specula_fair_diagnostic_test.go": "service/matching/specula_fair_diagnostic_test.go",
    "specula_sql_trace.go": "common/persistence/sql/specula_trace.go",
}
for name, target in modules.items():
    dest = s / target
    if dest.exists() and dest.read_bytes() != (h / "src" / name).read_bytes():
        raise SystemExit(f"Preserving edited instrumentation file: {dest}")
patch = h / "patches/instrumentation.patch"
reverse = subprocess.run(["git", "apply", "--reverse", "--check", str(patch)], cwd=s, capture_output=True)
if reverse.returncode:
    raise SystemExit("Cannot reverse exactly this harness patch; no files were changed.")
subprocess.run(["git", "apply", "--reverse", str(patch)], cwd=s, check=True)
for target in modules.values():
    (s / target).unlink(missing_ok=True)
print(f"Removed only this harness instrumentation from {s}")
PY
