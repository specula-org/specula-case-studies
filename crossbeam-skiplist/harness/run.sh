#!/bin/bash
# Build instrumented crossbeam-skiplist, run test scenarios, collect traces.
# Usage: cd case-studies/crossbeam-skiplist && bash harness/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT_DIR="$CASE_DIR/artifact/crossbeam"
SKIPLIST_DIR="$ARTIFACT_DIR/crossbeam-skiplist"
TRACES_DIR="$CASE_DIR/traces"

echo "=== TLA+ Trace Generation for crossbeam-skiplist ==="
echo "Artifact: $SKIPLIST_DIR"
echo "Traces:   $TRACES_DIR"
echo ""

# Step 1: Apply instrumentation
echo "--- Step 1: Apply instrumentation ---"
bash "$SCRIPT_DIR/apply.sh"
echo ""

# Step 2: Build
echo "--- Step 2: Build ---"
cd "$SKIPLIST_DIR"
cargo build --features tla-trace 2>&1 | tail -3
cargo test --features tla-trace --test trace_tests --no-run 2>&1 | tail -3
echo ""

# Step 3: Run test scenarios (sequentially to avoid OnceLock conflicts)
echo "--- Step 3: Run test scenarios ---"
mkdir -p "$TRACES_DIR"
rm -f "$TRACES_DIR"/*.ndjson "$TRACES_DIR"/*.json

TRACE_DIR="$TRACES_DIR" cargo test --features tla-trace --test trace_tests \
    -- --nocapture --test-threads=1 2>&1 | tail -10
echo ""

# Step 4: Preprocess per-thread traces into merged JSON
echo "--- Step 4: Preprocess traces ---"
TESTS=("basic_ops" "concurrent_insert_remove" "interleaved_ops")

for test in "${TESTS[@]}"; do
    # Check if per-thread files exist
    count=$(ls -1 "$TRACES_DIR/${test}-thread-"*.ndjson 2>/dev/null | wc -l)
    if [ "$count" -gt 0 ]; then
        echo ""
        echo "Processing: $test ($count thread files)"
        python3 "$SCRIPT_DIR/src/preprocess_trace.py" \
            "$TRACES_DIR" "$test" "$TRACES_DIR/${test}.json"
    else
        echo "WARNING: No trace files for $test"
    fi
done
echo ""

# Step 5: Summary
echo "--- Step 5: Trace Summary ---"
echo ""
echo "Per-thread files:"
for f in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$f" ]; then
        lines=$(wc -l < "$f")
        printf "  %-45s %4d events\n" "$(basename "$f")" "$lines"
    fi
done

echo ""
echo "Merged JSON files (for TLC):"
for f in "$TRACES_DIR"/*.json; do
    if [ -f "$f" ]; then
        events=$(python3 -c "
import json, sys
d = json.load(open('$f'))
total = sum(len(v) for k, v in d.items() if k != 'metadata' and isinstance(v, list))
meta = d.get('metadata', {})
print(f'{total} events, {meta.get(\"num_threads\", \"?\")} threads, {meta.get(\"overlap_pairs\", \"?\")} overlapping pairs')
" 2>/dev/null || echo "?")
        printf "  %-45s %s\n" "$(basename "$f")" "$events"
    fi
done

echo ""
echo "Event type coverage:"
python3 -c "
import json, glob, sys
event_types = set()
for f in glob.glob('$TRACES_DIR/*.ndjson'):
    for line in open(f):
        try:
            e = json.loads(line.strip())
            if e.get('tag') == 'trace':
                event_types.add(e['event'])
        except: pass
for et in sorted(event_types):
    print(f'  {et}')
print(f'Total: {len(event_types)} event types')
" 2>/dev/null || echo "  (could not parse)"

echo ""
echo "=== Done. Traces ready for validation. ==="
