#!/bin/bash
# End-to-end: apply instrumentation, build, run tests, collect traces.
# Run from the case study root: cd case-studies/tokio-broadcast && bash harness/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT="$CASE_DIR/artifact/tokio"
TRACES_DIR="$CASE_DIR/traces"

echo "=== tokio-broadcast trace harness ==="
echo "Case dir: $CASE_DIR"
echo "Artifact: $ARTIFACT"
echo ""

# Step 1: Apply instrumentation
echo "--- Step 1: Apply instrumentation ---"
bash "$SCRIPT_DIR/apply.sh"
echo ""

# Step 2: Build
echo "--- Step 2: Build ---"
cd "$ARTIFACT"
cargo build -p tokio --features sync 2>&1
cargo test -p tokio --features sync --test trace_broadcast --no-run 2>&1
echo "Build successful."
echo ""

# Step 3: Run test scenarios
echo "--- Step 3: Run test scenarios ---"
RAW_TRACES="$TRACES_DIR/raw"
rm -rf "$RAW_TRACES"
mkdir -p "$RAW_TRACES"

BROADCAST_TRACE_BASE="$RAW_TRACES" \
BROADCAST_TRACE_DIR="$RAW_TRACES/init" \
cargo test -p tokio --features sync --test trace_broadcast -- --test-threads=1 2>&1
echo ""

# Step 4: Preprocess traces — merge per-thread files per scenario
echo "--- Step 4: Preprocess traces ---"
for scenario_dir in "$RAW_TRACES"/*/; do
    scenario=$(basename "$scenario_dir")
    if [ "$scenario" = "init" ]; then
        continue
    fi
    # Check if there are any trace files
    if ls "$scenario_dir"/trace-thread-*.ndjson >/dev/null 2>&1; then
        output="$TRACES_DIR/${scenario}.json"
        echo "Processing $scenario..."
        python3 "$SCRIPT_DIR/src/preprocess_trace.py" "$scenario_dir" "$output"
    fi
done
echo ""

# Step 5: Report results
echo "--- Step 5: Trace summary ---"
echo "Traces directory: $TRACES_DIR"
for f in "$TRACES_DIR"/*.json; do
    if [ -f "$f" ]; then
        events=$(python3 -c "import json; d=json.load(open('$f')); print(d['meta']['total_events'])")
        threads=$(python3 -c "import json; d=json.load(open('$f')); print(d['meta']['num_threads'])")
        echo "  $(basename $f): $events events, $threads threads"
    fi
done
echo ""

# Step 6: Spot-check trace quality
echo "--- Step 6: Spot checks ---"
for f in "$TRACES_DIR"/*.json; do
    if [ -f "$f" ]; then
        name=$(basename "$f")
        # Check for real timestamps (not sequential integers)
        first_start=$(python3 -c "
import json
d = json.load(open('$f'))
for tid, evts in d['threads'].items():
    if evts:
        print(evts[0]['start'])
        break
")
        echo "  $name: first start=$first_start (should be >=1)"

        # Check event types
        types=$(python3 -c "
import json
d = json.load(open('$f'))
events = set()
for tid, evts in d['threads'].items():
    for e in evts:
        events.add(e['event'])
print(sorted(events))
")
        echo "  $name events: $types"
    fi
done
echo ""

echo "=== Trace generation complete ==="
echo "Preprocessed traces: $TRACES_DIR/*.json"
echo "Run trace validation with:"
echo "  java -DJSON=../traces/<name>.json -jar ../../lib/tla2tools.jar -deadlock Trace"
