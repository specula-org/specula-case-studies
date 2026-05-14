#!/usr/bin/env bash
# One-command driver: apply instrumentation, build, run the trace scenarios,
# postprocess, and report counts.
#
#   bash .specula-output/harness/run.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ART="$(cd "$HERE/../../artifact/arc-swap" && pwd)"
TRACES_DIR="$(cd "$HERE/.." && pwd)/traces"
RAW_DIR="$TRACES_DIR/raw"

mkdir -p "$TRACES_DIR" "$RAW_DIR"

echo "[run] applying instrumentation"
bash "$HERE/apply.sh"

echo "[run] building (cargo test --no-run)"
( cd "$ART" && cargo test --test tla_trace_scenarios --no-run --quiet )

run_one() {
    local name="$1"
    echo "[run] scenario: $name"
    rm -f "$RAW_DIR/$name.ndjson" "$TRACES_DIR/$name.ndjson"
    (
        cd "$ART"
        ARC_SWAP_TRACE_OUT="$RAW_DIR" \
            cargo test --test tla_trace_scenarios --quiet -- \
                --test-threads=1 --exact --nocapture "$name"
    )
    if [[ -s "$RAW_DIR/$name.ndjson" ]]; then
        python3 "$HERE/postprocess.py" "$RAW_DIR/$name.ndjson" "$TRACES_DIR/$name.ndjson"
    else
        echo "[run] WARNING: $name produced no events"
    fi
}

run_one basic_read_write
run_one concurrent_readers_writer

echo
echo "[run] trace summary:"
for f in "$TRACES_DIR"/*.ndjson; do
    [[ -f "$f" ]] || continue
    lines=$(wc -l < "$f")
    echo "  $(basename "$f"): $lines events"
done

echo
echo "[run] event-type coverage (post-processed traces):"
for f in "$TRACES_DIR"/*.ndjson; do
    [[ -f "$f" ]] || continue
    echo "--- $(basename "$f") ---"
    python3 -c "
import json, sys, collections
counts = collections.Counter()
for line in open('$f'):
    line = line.strip()
    if not line: continue
    ev = json.loads(line)
    counts[ev.get('event','?')] += 1
for k, v in sorted(counts.items()):
    print(f'  {k}: {v}')
"
done

echo
echo "[run] running quick TLC validation pass on each trace:"
SPEC_DIR="$(cd "$HERE/../spec" && pwd)"
TLA_JAR="${TLA_JAR:-/home/ubuntu/Specula/lib/tla2tools.jar}"
COMMUNITY_JAR="${COMMUNITY_JAR:-/home/ubuntu/Specula/lib/CommunityModules-deps.jar}"
if [[ -r "$TLA_JAR" && -r "$COMMUNITY_JAR" ]]; then
    for f in "$TRACES_DIR"/*.ndjson; do
        [[ -f "$f" ]] || continue
        rel="$(realpath --relative-to="$SPEC_DIR" "$f")"
        echo "--- validating $(basename "$f") ---"
        ( cd "$SPEC_DIR" && JSON="$rel" \
            java -cp "$TLA_JAR:$COMMUNITY_JAR" tlc2.TLC \
                -config Trace.cfg Trace.tla 2>&1 ) \
            | tail -10
    done
else
    echo "  [skip] tla2tools jar not found at $TLA_JAR; skipping inline validation"
fi
