#!/bin/bash
# Build the instrumented flurry and run tests to generate traces.
#
# Usage: cd case-studies/flurry && bash harness/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT_DIR="$CASE_DIR/artifact/flurry"
TRACES_DIR="$CASE_DIR/traces"

# Ensure cargo is available
if ! command -v cargo &>/dev/null; then
    if [ -f "$HOME/.cargo/env" ]; then
        source "$HOME/.cargo/env"
    else
        echo "ERROR: cargo not found" >&2
        exit 1
    fi
fi

# Step 1: Apply instrumentation
echo "=== Step 1: Apply instrumentation ==="
bash "$SCRIPT_DIR/apply.sh"

# Step 2: Build
echo ""
echo "=== Step 2: Build ==="
cd "$ARTIFACT_DIR"
cargo build 2>&1 | tail -5
cargo test --test trace_tests --no-run 2>&1 | tail -5

# Step 3: Run trace tests (one at a time with separate trace dirs)
echo ""
echo "=== Step 3: Run trace tests ==="
mkdir -p "$TRACES_DIR"

for test_name in test_basic_put test_resize test_treeify; do
    echo "  Running $test_name..."
    TRACE_TMP=$(mktemp -d)
    FLURRY_TRACE_DIR="$TRACE_TMP" \
        cargo test --test trace_tests -- "$test_name" --exact --nocapture 2>&1 | tail -3

    # Merge per-thread files into a single JSON for TLC
    OUTPUT_JSON="$TRACES_DIR/${test_name}.json"
    python3 "$SCRIPT_DIR/src/preprocess_trace.py" "$TRACE_TMP" "$OUTPUT_JSON"

    # Also keep raw NDJSON for debugging
    RAW_DIR="$TRACES_DIR/raw_${test_name}"
    rm -rf "$RAW_DIR"
    mv "$TRACE_TMP" "$RAW_DIR"
done

# Step 4: Report
echo ""
echo "=== Step 4: Trace Summary ==="
for trace in "$TRACES_DIR"/*.json; do
    if [ -f "$trace" ]; then
        NAME=$(basename "$trace")
        THREADS=$(python3 -c "import json; d=json.load(open('$trace')); print(len(d))")
        EVENTS=$(python3 -c "import json; d=json.load(open('$trace')); print(sum(len(v) for v in d.values()))")
        echo "  $NAME: $THREADS threads, $EVENTS events"
    fi
done

echo ""
echo "=== Trace files in $TRACES_DIR ==="
ls -la "$TRACES_DIR"/*.json 2>/dev/null || echo "  (no traces found)"
echo ""
echo "Done. Traces ready for validation."
