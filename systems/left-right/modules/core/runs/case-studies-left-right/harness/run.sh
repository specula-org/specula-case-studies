#!/bin/bash
# Build instrumented left-right, run test scenarios, collect and preprocess traces.
# Run from case study root: cd case-studies/left-right && bash harness/run.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(dirname "$SCRIPT_DIR")"
ARTIFACT="$CASE_DIR/artifact/left-right"
TRACES_DIR="$CASE_DIR/traces"

echo "=== left-right trace generation ==="

# 1. Apply instrumentation
bash "$SCRIPT_DIR/apply.sh"

# 2. Build
echo ""
echo "=== Building instrumented artifact ==="
cd "$ARTIFACT"
cargo build --tests 2>&1 | tail -5

# 3. Prepare trace output directory
rm -rf "$TRACES_DIR"
mkdir -p "$TRACES_DIR"

# 4. Run test scenarios
echo ""
echo "=== Running test scenarios ==="
export TLA_TRACE_DIR="$TRACES_DIR"
cargo test --test tla_scenarios -- --test-threads=1 --nocapture 2>&1 | tail -20

# 5. Preprocess traces (merge per-thread files -> JSON for TLC)
echo ""
echo "=== Preprocessing traces ==="
for scenario_dir in "$TRACES_DIR"/*/; do
    scenario=$(basename "$scenario_dir")
    output="$TRACES_DIR/${scenario}.json"
    echo "--- $scenario ---"
    python3 "$SCRIPT_DIR/src/preprocess_trace.py" "$scenario_dir" "$output"
done

# 6. Report
echo ""
echo "=== Trace files ==="
ls -la "$TRACES_DIR"/*.json 2>/dev/null || echo "No trace files generated!"

echo ""
echo "=== Event counts per trace ==="
for f in "$TRACES_DIR"/*.json; do
    if [ -f "$f" ]; then
        name=$(basename "$f")
        count=$(python3 -c "import json; d=json.load(open('$f')); print(sum(len(v) for v in d['threads'].values()))")
        echo "  $name: $count events"
    fi
done

echo ""
echo "=== Done ==="
