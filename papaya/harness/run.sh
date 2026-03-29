#!/usr/bin/env bash
# Build instrumented papaya, run trace tests, collect and preprocess traces.
# Run from case study root: cd case-studies/papaya && bash harness/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$SCRIPT_DIR/.."
ARTIFACT="$CASE_DIR/artifact/papaya"
TRACES_DIR="$CASE_DIR/traces"

# Step 1: Apply instrumentation
echo "=== Step 1: Apply instrumentation ==="
bash "$SCRIPT_DIR/apply.sh"

# Step 2: Build
echo ""
echo "=== Step 2: Build ==="
cd "$ARTIFACT"
cargo test --features tla-trace --test trace_tests --no-run 2>&1
echo "Build successful."

# Step 3: Run trace tests
echo ""
echo "=== Step 3: Run trace tests ==="
mkdir -p "$TRACES_DIR"

SCENARIOS="basic_insert concurrent_insert_resize concurrent_insert_remove"

for scenario in $SCENARIOS; do
    echo ""
    echo "--- Running: $scenario ---"
    TRACE_DIR="$TRACES_DIR/raw_${scenario}"
    rm -rf "$TRACE_DIR"
    mkdir -p "$TRACE_DIR"

    PAPAYA_TRACE_DIR="$TRACE_DIR" \
        cargo test --features tla-trace --test trace_tests "$scenario" \
        -- --exact --nocapture 2>&1

    # Count raw events per thread
    total=0
    for f in "$TRACE_DIR"/trace-thread-*.ndjson; do
        [ -f "$f" ] || continue
        n=$(wc -l < "$f")
        total=$((total + n))
    done
    echo "  Raw events: $total ($(ls "$TRACE_DIR"/trace-thread-*.ndjson 2>/dev/null | wc -l) threads)"
done

# Step 4: Preprocess traces
echo ""
echo "=== Step 4: Preprocess traces ==="
for scenario in $SCENARIOS; do
    RAW_DIR="$TRACES_DIR/raw_${scenario}"
    OUTPUT="$TRACES_DIR/${scenario}.json"
    echo ""
    echo "--- Preprocessing: $scenario ---"
    python3 "$SCRIPT_DIR/src/preprocess_trace.py" "$RAW_DIR" "$OUTPUT"
done

# Step 5: Summary
echo ""
echo "=== Trace Summary ==="
for scenario in $SCENARIOS; do
    OUTPUT="$TRACES_DIR/${scenario}.json"
    if [ -f "$OUTPUT" ]; then
        size=$(du -h "$OUTPUT" | cut -f1)
        events=$(python3 -c "
import json
d = json.load(open('$OUTPUT'))
total = sum(len(v) for v in d['threads'].values())
types = set()
for evts in d['threads'].values():
    for e in evts:
        types.add(e['event'])
print(f'{total} events, types: {sorted(types)}')
")
        echo "  $scenario: $size, $events"
    fi
done

echo ""
echo "=== Traces collected in: $TRACES_DIR ==="
ls -la "$TRACES_DIR"/*.json 2>/dev/null || echo "  (no preprocessed traces found)"
