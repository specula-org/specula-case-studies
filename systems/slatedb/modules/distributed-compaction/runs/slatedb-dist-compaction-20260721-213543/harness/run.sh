#!/usr/bin/env bash

set -euo pipefail

OUTPUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS_DIR="$OUTPUT_ROOT/harness"
SPEC_DIR="$OUTPUT_ROOT/spec"
TRACE_DIR="$OUTPUT_ROOT/traces"
ARTIFACT_DIR="${ARTIFACT_DIR:-/home/ubuntu/Specula/case-studies/slatedb-dist-compaction/artifact/slatedb}"
TLC_CP="/home/ubuntu/Specula/lib/tla2tools.jar:/home/ubuntu/Specula/lib/CommunityModules-deps.jar"
TEST_FILTER="${TEST_FILTER:-trace_}"

bash "$HARNESS_DIR/apply.sh"

mkdir -p "$TRACE_DIR"
rm -f "$TRACE_DIR"/*.ndjson

(
    cd "$ARTIFACT_DIR"
    timeout 15m env SPECULA_TRACE_DIR="$TRACE_DIR" cargo test -p slatedb "$TEST_FILTER" -- --nocapture --test-threads=1
)

python - "$TRACE_DIR" <<'PY'
import json
import pathlib
import sys

trace_dir = pathlib.Path(sys.argv[1])
expected = [
    "StartCoordinator",
    "CrashCoordinator",
    "CoordinatorRefreshCompactions",
    "CoordinatorRefreshManifest",
    "MaybeScheduleCompactions",
    "ExternalSubmit",
    "MaybeValidateSubmittedFail",
    "MaybeValidateSubmittedSchedule",
    "MaybeValidateSubmittedDrain",
    "PollAndClaimStopDuplicate",
    "PollAndClaim",
    "DispatchClaimedJob",
    "ReleaseClaimPostClaimInvalid",
    "WriteOutputSst",
    "HeartbeatLoseOwnership",
    "HeartbeatOwnedJobs",
    "HandleFinishedSuccess",
    "HandleFinishedLostOwnership",
    "HandleFinishedExecError",
    "ReclaimStaleWorkers",
    "CommitCompactedEntriesFail",
    "CommitCompactedEntriesWriteManifest",
    "CommitCompactedEntriesWriteCompactions",
    "RefreshCheckpoint",
    "GcSweep",
]

counts = {}
seen = set()
for path in sorted(trace_dir.glob("*.ndjson")):
    if path.name == "trace.ndjson":
        continue
    line_count = 0
    for line_no, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip():
            continue
        obj = json.loads(line)
        assert obj.get("tag") == "trace", f"{path}:{line_no}: missing trace tag"
        assert isinstance(obj.get("ts"), str) and obj["ts"], f"{path}:{line_no}: missing ts"
        event = obj["event"]
        assert "name" in event and "state" in event, f"{path}:{line_no}: malformed event"
        seen.add(event["name"])
        line_count += 1
    counts[path.name] = line_count

print("Trace line counts:")
for name, count in counts.items():
    print(f"  {name}: {count}")

missing = [name for name in expected if name not in seen]
print("Observed event types:")
for name in sorted(seen):
    print(f"  {name}")

if missing:
    print("Uncovered instrumented/spec events:")
    for name in missing:
        print(f"  {name}")
PY

cd "$SPEC_DIR"
for trace in "$TRACE_DIR"/*.ndjson; do
    base="$(basename "$trace")"
    if [[ "$base" == "trace.ndjson" ]]; then
        continue
    fi
    ln -sf "$trace" "$TRACE_DIR/trace.ndjson"
    log_file="$TRACE_DIR/${base%.ndjson}.tlc.log"
    state_dir="$(mktemp -d "/tmp/${base%.ndjson}-tlc-XXXXXX")"
    if timeout 15m java -XX:+UseParallelGC -cp "$TLC_CP" tlc2.TLC -config Trace.cfg Trace.tla -lncheck final -metadir "$state_dir" -fpmem 0.9 >"$log_file" 2>&1; then
        printf '%s\n' "TLC PASS $base"
    else
        printf '%s\n' "TLC FAIL $base" >&2
        tail -n 80 "$log_file" >&2 || true
        rm -rf "$state_dir"
        rm -f "$TRACE_DIR/trace.ndjson"
        exit 1
    fi
    rm -rf "$state_dir"
done
rm -f "$TRACE_DIR/trace.ndjson"

printf '%s\n' "Harness run completed."
