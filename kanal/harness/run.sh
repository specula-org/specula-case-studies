#!/bin/bash
# Build the instrumented kanal and run tests to generate traces.
#
# Usage: cd case-studies/kanal && bash harness/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT_DIR="$(cd "$SCRIPT_DIR/../artifact/kanal" && pwd)"
TRACES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/traces"

if ! command -v cargo &>/dev/null; then
    if [ -f "$HOME/.cargo/env" ]; then
        . "$HOME/.cargo/env"
    else
        echo "ERROR: cargo not found."
        exit 1
    fi
fi

echo "=== TLA+ Trace Generation for kanal ==="
echo "Artifact dir: $ARTIFACT_DIR"
echo "Trace output: $TRACES_DIR"
echo ""

# Step 1: Apply instrumentation
echo "--- Step 1: Apply instrumentation ---"
bash "$SCRIPT_DIR/apply.sh"
echo ""

# Step 2: Build
echo "--- Step 2: Build ---"
cd "$ARTIFACT_DIR"
cargo build 2>&1 | tail -5
cargo test --no-run 2>&1 | tail -5
echo ""

# Step 3: Run tests with tracing
echo "--- Step 3: Run trace tests ---"
mkdir -p "$TRACES_DIR"

# Clean up old per-thread files
rm -f "$TRACES_DIR"/trace-thread-*.ndjson
rm -f "$TRACES_DIR"/*.json

SCENARIOS=(
    "trace_basic_send_recv"
    "trace_direct_handoff"
    "trace_close_protocol"
    "trace_contention"
)

for scenario in "${SCENARIOS[@]}"; do
    echo "  Running $scenario..."
    TRACE_SUBDIR="$TRACES_DIR/$scenario"
    mkdir -p "$TRACE_SUBDIR"
    rm -f "$TRACE_SUBDIR"/trace-thread-*.ndjson
    KANAL_TRACE_DIR="$TRACE_SUBDIR" \
        cargo test --test trace_tests -- "$scenario" --exact --nocapture 2>&1 | tail -3

    # Preprocess: merge per-thread files into single JSON
    echo "  Preprocessing $scenario..."
    python3 "$SCRIPT_DIR/src/preprocess_trace.py" \
        "$TRACE_SUBDIR" \
        "$TRACES_DIR/${scenario}.json"
    echo ""
done

echo ""

# Step 4: Verify
echo "--- Step 4: Verify traces ---"
for trace in "$TRACES_DIR"/*.json; do
    if [ -f "$trace" ]; then
        EVENTS=$(python3 -c "
import json
data = json.load(open('$trace'))
total = sum(len(v) for k,v in data.items() if isinstance(v, list))
threads = sum(1 for k,v in data.items() if isinstance(v, list))
print(f'{total} events, {threads} threads')
" 2>/dev/null || echo '?')
        echo "  $(basename "$trace"): $EVENTS"
    fi
done

echo ""

# Step 5: Event coverage summary
echo "--- Step 5: Event coverage ---"
python3 -c "
import json, glob, os
all_events = set()
for f in glob.glob('$TRACES_DIR/*.json'):
    data = json.load(open(f))
    for key, events in data.items():
        if isinstance(events, list):
            for e in events:
                all_events.add(e.get('event', '?'))
print(f'Event types found ({len(all_events)}):')
for e in sorted(all_events):
    print(f'  {e}')
"

echo ""
echo "=== Done ==="
