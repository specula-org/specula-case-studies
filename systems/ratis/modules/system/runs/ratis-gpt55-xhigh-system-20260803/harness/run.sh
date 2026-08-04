#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TRACE_DIR="$OUTPUT_ROOT/traces"
SOURCE_DIR="${SPECULA_SOURCE_DIR:-/home/ubuntu/specula-ratis-issue123-20260803/sources/ratis-system}"
HARNESS_TIMEOUT="${SPECULA_HARNESS_TIMEOUT:-30m}"

bash "$SCRIPT_DIR/apply.sh"
mkdir -p "$TRACE_DIR"

cd "$SOURCE_DIR"
timeout "$HARNESS_TIMEOUT" ./mvnw -pl ratis-test -am \
  -DskipShade \
  -Drat.skip=true \
  -Dcheckstyle.skip=true \
  -Dspotbugs.skip=true \
  -Djacoco.skip=true \
  -DfailIfNoTests=false \
  -Dspecula.trace.dir="$TRACE_DIR" \
  -Dtest=TestSpeculaTraceHarnessWithGrpc \
  test

python3 - "$TRACE_DIR" <<'PY'
import collections
import json
import pathlib
import sys

trace_dir = pathlib.Path(sys.argv[1])
expected = [
    "normal-consensus-read.ndjson",
    "leader-loss-restart.ndjson",
    "grpc-reconnect-timeout.ndjson",
    "snapshot-catchup.ndjson",
]

missing = [name for name in expected if not (trace_dir / name).is_file()]
if missing:
    raise SystemExit(f"missing trace files: {', '.join(missing)}")

for name in expected:
    path = trace_dir / name
    counts = collections.Counter()
    total = 0
    with path.open(encoding="utf-8") as handle:
        for lineno, line in enumerate(handle, 1):
            if not line.strip():
                continue
            obj = json.loads(line)
            if obj.get("tag") == "trace":
                event = obj.get("event", {})
                if "name" not in event or "nid" not in event or "state" not in event:
                    raise SystemExit(f"{name}:{lineno}: trace event missing name/nid/state")
                counts[event["name"]] += 1
                total += 1
    if total == 0:
        raise SystemExit(f"{name}: no trace events")
    print(f"{name}: {total} trace events, {len(counts)} event types")
PY
