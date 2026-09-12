#!/usr/bin/env python3
import hashlib
import json
import subprocess
import sys
from pathlib import Path

harness = Path(__file__).resolve().parent
source = Path(sys.argv[1]).resolve()
revision = "0c010ce5fe8c0180aa7573c72fe8fc87c6df7025"
actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
if actual != revision:
    raise SystemExit(f"Expected {revision}, got {actual}; rebase the instrumentation patch first.")
patch = harness / "patches/instrumentation.patch"
def check(reverse=False):
    return subprocess.run(
        ["git", "apply", "--check", *(["--reverse"] if reverse else []), str(patch)],
        cwd=source, capture_output=True
    ).returncode == 0
modules = {
    "specula_trace.go": "service/matching/specula_trace.go",
    "specula_observer_test.go": "service/matching/specula_observer_test.go",
    "specula_scenarios_test.go": "service/matching/specula_scenarios_test.go",
    "specula_fair_diagnostic_test.go": "service/matching/specula_fair_diagnostic_test.go",
    "specula_sql_trace.go": "common/persistence/sql/specula_trace.go",
}
state_file = harness / ".applied.json"
previous = json.loads(state_file.read_text()) if state_file.exists() else {}
def digest(data):
    return hashlib.sha256(data).hexdigest()
# Check every destination before mutating any file.
for name, target in modules.items():
    dest = source / target
    data = (harness / "src" / name).read_bytes()
    if dest.exists() and dest.read_bytes() != data and digest(dest.read_bytes()) != previous.get(str(dest)):
        raise SystemExit(f"Preserving edited destination: {dest}; copy its changes into harness/src first.")
if check():
    subprocess.run(["git", "apply", str(patch)], cwd=source, check=True)
elif not check(reverse=True):
    raise SystemExit("Instrumentation patch conflicts with this checkout. No reset or checkout was performed.")
state = {}
for name, target in modules.items():
    dest = source / target
    data = (harness / "src" / name).read_bytes()
    dest.write_bytes(data)
    state[str(dest)] = digest(data)
state_file.write_text(json.dumps(state, indent=2) + "\n")
print(f"Instrumentation ready: {source} @ {actual}")
