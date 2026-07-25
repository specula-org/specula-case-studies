#!/bin/bash
# Build instrumented crossbeam-deque, run tests, collect and preprocess traces.
#
# Usage: cd case-studies/crossbeam-deque && bash harness/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT_DIR="$CASE_DIR/artifact/crossbeam/crossbeam-deque"
TRACES_DIR="$CASE_DIR/traces"

if ! command -v cargo &>/dev/null; then
    if [ -f "$HOME/.cargo/env" ]; then
        . "$HOME/.cargo/env"
    else
        echo "ERROR: cargo not found."
        exit 1
    fi
fi

echo "=== TLA+ Trace Generation for crossbeam-deque ==="
echo "Artifact: $ARTIFACT_DIR"
echo "Traces:   $TRACES_DIR"
echo ""

# Step 1: Apply instrumentation
echo "--- Step 1: Apply instrumentation ---"
bash "$SCRIPT_DIR/apply.sh"
echo ""

# Step 2: Build
echo "--- Step 2: Build ---"
(cd "$ARTIFACT_DIR" && cargo build 2>&1 | tail -5)
(cd "$ARTIFACT_DIR" && cargo test --test trace_tests --no-run 2>&1 | tail -5)
echo ""

# Step 3: Run tests with tracing
echo "--- Step 3: Run trace tests ---"
mkdir -p "$TRACES_DIR"

declare -A FLAVORS
FLAVORS[push_lifo_pop]=LIFO
FLAVORS[push_fifo_pop]=FIFO
FLAVORS[steal_single]=LIFO
FLAVORS[concurrent_fifo]=FIFO

TESTS=(push_lifo_pop push_fifo_pop steal_single concurrent_fifo)

for test_name in "${TESTS[@]}"; do
    trace_dir="$TRACES_DIR/$test_name"
    rm -rf "$trace_dir"
    mkdir -p "$trace_dir"

    echo "  Running test_$test_name..."
    CROSSBEAM_DEQUE_TRACE_DIR="$trace_dir" \
        cargo test --manifest-path "$ARTIFACT_DIR/Cargo.toml" \
        --test trace_tests "test_$test_name" -- --exact --nocapture 2>&1 | tail -3
done
echo ""

# Step 4: Preprocess traces (merge per-thread + compress timestamps)
echo "--- Step 4: Preprocess traces ---"
for test_name in "${TESTS[@]}"; do
    trace_dir="$TRACES_DIR/$test_name"
    flavor="${FLAVORS[$test_name]}"
    output="$TRACES_DIR/${test_name}.json"

    python3 "$SCRIPT_DIR/src/preprocess_trace.py" "$trace_dir" "$output" "$flavor"
done
echo ""

# Step 5: Verify
echo "--- Step 5: Verify traces ---"
for test_name in "${TESTS[@]}"; do
    output="$TRACES_DIR/${test_name}.json"
    if [ -f "$output" ]; then
        # Count events per thread
        event_count=$(python3 -c "
import json, sys
data = json.load(open('$output'))
total = 0
for k, v in data.items():
    if isinstance(v, list):
        total += len(v)
        types = {}
        for e in v:
            t = e.get('event', '?')
            types[t] = types.get(t, 0) + 1
        summary = ', '.join(f'{t}={n}' for t, n in sorted(types.items()))
        print(f'  {k}: {len(v)} events ({summary})')
print(f'  Total: {total} events')
" 2>/dev/null || echo "  (parse error)")
        echo "$test_name.json:"
        echo "$event_count"
    fi
done

echo ""
echo "=== Done ==="
echo "Traces in: $TRACES_DIR/"
echo "For TLC validation: java -jar tla2tools.jar -config Trace.cfg Trace.tla -deadlock -DJSON=../traces/<name>.json"
