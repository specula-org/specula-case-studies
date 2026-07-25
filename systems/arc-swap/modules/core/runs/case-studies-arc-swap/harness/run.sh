#!/bin/bash
# Build the instrumented arc-swap and run tests to generate traces.
#
# Usage: ./run.sh [trace_dir]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT_DIR="$(cd "$SCRIPT_DIR/../artifact/arc-swap" && pwd)"
TRACES_DIR="${1:-$(cd "$SCRIPT_DIR/../traces" && pwd)}"

if ! command -v cargo &>/dev/null; then
    if [ -f "$HOME/.cargo/env" ]; then
        . "$HOME/.cargo/env"
    else
        echo "ERROR: cargo not found."
        exit 1
    fi
fi

echo "=== TLA+ Trace Generation for arc-swap ==="
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

# Test 1: single_swap_load
echo "  Running single_swap_load..."
ARCSWAP_TRACE_FILE="$TRACES_DIR/single_swap_load.ndjson" \
    cargo test --test trace_tests -- single_swap_load --exact --nocapture 2>&1 | tail -5

# Test 2: two_thread_swap_load
echo "  Running two_thread_swap_load..."
ARCSWAP_TRACE_FILE="$TRACES_DIR/two_thread_swap_load.ndjson" \
    cargo test --test trace_tests -- two_thread_swap_load --exact --nocapture 2>&1 | tail -5

# Test 3: load_initial
echo "  Running load_initial..."
ARCSWAP_TRACE_FILE="$TRACES_DIR/load_initial.ndjson" \
    cargo test --test trace_tests -- load_initial --exact --nocapture 2>&1 | tail -5

echo ""

# Step 4: Verify
echo "--- Step 4: Verify traces ---"
for trace in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$trace" ]; then
        LINES=$(wc -l < "$trace")
        echo "  $(basename "$trace"): $LINES events"
        if [ "$LINES" -gt 0 ]; then
            echo "    First event: $(head -1 "$trace" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("event","?"))' 2>/dev/null || echo '?')"
            echo "    Last event:  $(tail -1 "$trace" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("event","?"))' 2>/dev/null || echo '?')"
        fi
    fi
done

echo ""
echo "=== Done ==="
