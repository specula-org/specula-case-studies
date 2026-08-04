#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SPEC_DIR="$OUTPUT_DIR/spec"
TRACE_DIR="${SPECULA_TRACE_DIR:-$OUTPUT_DIR/traces}"
SPECULA_ROOT="${SPECULA_ROOT:-$(cd "$OUTPUT_DIR/../../../.." && pwd)}"

if [ -n "${SPECULA_SOURCE_DIR:-}" ]; then
  SOURCE_DIR="$(cd "$SPECULA_SOURCE_DIR" && pwd)"
else
  SOURCE_DIR="$(cd "$OUTPUT_DIR/../../../../../sources/ratis-server" && pwd)"
fi

mkdir -p "$TRACE_DIR"
rm -f "$TRACE_DIR"/*.ndjson

bash "$SCRIPT_DIR/apply.sh"

cd "$SOURCE_DIR"
timeout "${SPECULA_MVN_TIMEOUT:-900}" ./mvnw -pl ratis-server -am \
  -Dtest=org.apache.ratis.SpeculaTraceHarnessTest \
  -DfailIfNoTests=false \
  -Dspecula.trace.dir="$TRACE_DIR" \
  -Dspecula.trace.maxIndex="${SPECULA_TRACE_MAX_INDEX:-8}" \
  -Dspotbugs.skip=true \
  -Dcheckstyle.skip=true \
  -Drat.skip=true \
  test

python3 - "$TRACE_DIR" <<'PY'
import collections
import json
import pathlib
import sys

trace_dir = pathlib.Path(sys.argv[1])
expected = {
    "normal_append.ndjson",
    "crash_recover.ndjson",
    "read_index.ndjson",
    "reconfiguration.ndjson",
}
files = sorted(trace_dir.glob("*.ndjson"))
missing = expected - {p.name for p in files}
if missing:
    raise SystemExit("missing trace files: " + ", ".join(sorted(missing)))

event_counts = collections.Counter()
file_summaries = []
for path in files:
    line_count = 0
    trace_count = 0
    with path.open(encoding="utf-8") as f:
        for lineno, line in enumerate(f, 1):
            line_count += 1
            try:
                record = json.loads(line)
            except json.JSONDecodeError as e:
                raise SystemExit(f"{path}:{lineno}: invalid JSON: {e}") from e
            tag = record.get("tag")
            if tag == "trace":
                event = record.get("event")
                if not isinstance(event, dict):
                    raise SystemExit(f"{path}:{lineno}: trace record missing event object")
                name = event.get("name")
                if not name:
                    raise SystemExit(f"{path}:{lineno}: trace event missing name")
                if "ts" not in record:
                    raise SystemExit(f"{path}:{lineno}: trace event missing ts")
                trace_count += 1
                event_counts[name] += 1
            elif tag != "config":
                raise SystemExit(f"{path}:{lineno}: unexpected tag {tag!r}")
    if trace_count == 0:
        raise SystemExit(f"{path}: no trace events")
    file_summaries.append((path.name, line_count, trace_count))

print("Trace files:")
for name, line_count, trace_count in file_summaries:
    print(f"  {name}: {line_count} line(s), {trace_count} trace event(s)")

print("Event coverage:")
for name, count in sorted(event_counts.items()):
    print(f"  {name}: {count}")
PY

shopt -s nullglob
TRACE_FILES=("$TRACE_DIR"/*.ndjson)
VALIDATE="$SPECULA_ROOT/scripts/tlc/validate.sh"
if [ -x "$VALIDATE" ] && [ "${#TRACE_FILES[@]}" -gt 0 ]; then
  export TERM="${TERM:-xterm}"
  echo "Running TLC trace validation for ${#TRACE_FILES[@]} trace file(s)."
  set +e
  timeout "${SPECULA_TLC_TIMEOUT:-300}" "$VALIDATE" \
    -p "${SPECULA_TLC_PARALLEL:-1}" \
    -s "$SPEC_DIR/Trace.tla" \
    -c "$SPEC_DIR/Trace.cfg" \
    "${TRACE_FILES[@]}"
  TLC_STATUS=$?
  set -e
  if [ "$TLC_STATUS" -ne 0 ]; then
    echo "TLC trace validation failed with status $TLC_STATUS."
    echo "Set SPECULA_TLC_STRICT=1 to make this a hard failure."
    if [ "${SPECULA_TLC_STRICT:-0}" = "1" ]; then
      exit "$TLC_STATUS"
    fi
  else
    echo "TLC trace validation passed."
  fi
else
  echo "Skipping TLC trace validation; validator not found or no traces were generated."
fi
