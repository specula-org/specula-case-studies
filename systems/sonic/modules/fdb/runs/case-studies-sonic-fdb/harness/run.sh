#!/bin/bash
# Build and run FDB trace harness, collect traces
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SPECULA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TRACES_DIR="$SPECULA_DIR/traces"
SRC_DIR="$SCRIPT_DIR/src"

mkdir -p "$TRACES_DIR"

echo "=============================================="
echo "  SONiC FDB Trace Harness"
echo "=============================================="

# Step 1: Apply instrumentation to real source files
echo ""
echo "--- Step 1: Apply instrumentation ---"
bash "$SCRIPT_DIR/apply.sh"

# Step 2: Build standalone harness
echo ""
echo "--- Step 2: Build standalone harness ---"
HARNESS_BIN="$SCRIPT_DIR/fdb_harness"

g++ -std=c++17 -O2 -Wall -Wno-unused-function \
    -I"$SRC_DIR" \
    -o "$HARNESS_BIN" \
    "$SRC_DIR/fdb_harness.cpp" \
    -lgtest -lgtest_main -pthread

echo "Built: $HARNESS_BIN"

# Step 3: Run test scenarios
echo ""
echo "--- Step 3: Run test scenarios ---"
TRACE_OUTPUT_DIR="$TRACES_DIR" "$HARNESS_BIN" --gtest_print_time=0

# Step 4: Report trace statistics
echo ""
echo "--- Step 4: Trace statistics ---"
echo ""
for f in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$f" ]; then
        lines=$(wc -l < "$f")
        events=$(python3 -c "
import json, sys
counts = {}
for line in open('$f'):
    obj = json.loads(line)
    ev = obj.get('event', 'unknown')
    counts[ev] = counts.get(ev, 0) + 1
for k, v in sorted(counts.items()):
    print(f'    {k}: {v}')
" 2>/dev/null || echo "    (could not parse)")
        echo "  $(basename "$f"): $lines events"
        echo "$events"
        echo ""
    fi
done

# Step 5: Validate JSON format
echo "--- Step 5: Format validation ---"
errors=0
for f in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$f" ]; then
        if ! python3 -c "
import json, sys
for i, line in enumerate(open('$f'), 1):
    obj = json.loads(line)
    assert 'tag' in obj, f'Line {i}: missing tag field'
    assert obj['tag'] == 'trace', f'Line {i}: tag is not trace'
    assert 'event' in obj, f'Line {i}: missing event field'
    assert 'ts' in obj, f'Line {i}: missing ts field'
    ts = obj['ts']
    # Ensure timestamp is not a simple sequential integer
    assert isinstance(ts, int) and ts > 1000000, f'Line {i}: suspicious timestamp {ts}'
print(f'  $(basename $f): OK')
" 2>&1; then
            echo "  $(basename "$f"): VALIDATION FAILED"
            errors=$((errors + 1))
        fi
    fi
done

if [ $errors -gt 0 ]; then
    echo ""
    echo "WARNING: $errors trace file(s) failed validation"
else
    echo ""
    echo "All trace files pass format validation."
fi

echo ""
echo "=============================================="
echo "  Traces written to: $TRACES_DIR/"
echo "=============================================="
