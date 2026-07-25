#!/bin/bash
# Build the instrumented Autobahn and run the tests to generate traces.
#
# Usage:
#   ./run.sh [trace_dir]
#
# The trace directory defaults to ../traces/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT_DIR="$(cd "$SCRIPT_DIR/../artifact/autobahn-artifact" && pwd)"
TRACES_DIR="${1:-$(cd "$SCRIPT_DIR/../traces" && pwd)}"

# Ensure Rust is available
if ! command -v cargo &>/dev/null; then
    if [ -f "$HOME/.cargo/env" ]; then
        . "$HOME/.cargo/env"
    else
        echo "ERROR: cargo not found. Install Rust first."
        exit 1
    fi
fi

echo "=== TLA+ Trace Generation for Autobahn BFT ==="
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
cargo build -p primary 2>&1 | tail -5
echo ""

# Step 3: Run tests with tracing enabled
echo "--- Step 3: Run tests ---"
mkdir -p "$TRACES_DIR"

export TLA_TRACE_FILE="$TRACES_DIR/basic_consensus.ndjson"
export RUST_LOG=debug

# Run the existing core tests (which exercise consensus processing)
cargo test -p primary -- --nocapture --test-threads=1 2>&1 | tee "$TRACES_DIR/build.log" | tail -20

echo ""

# Step 4: Verify traces
echo "--- Step 4: Verify traces ---"
for trace in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$trace" ]; then
        LINES=$(wc -l < "$trace")
        echo "  $trace: $LINES lines"
        if [ "$LINES" -gt 0 ]; then
            echo "  First 3 lines:"
            head -3 "$trace" | python3 -m json.tool --compact 2>/dev/null || head -3 "$trace"
        fi
    fi
done

if [ ! -f "$TRACES_DIR/basic_consensus.ndjson" ] || [ ! -s "$TRACES_DIR/basic_consensus.ndjson" ]; then
    echo ""
    echo "WARNING: No trace events generated. This is expected if the existing"
    echo "tests don't exercise multi-node consensus. A dedicated test scenario"
    echo "or local 4-node deployment is needed to generate traces."
    echo ""
    echo "To run with a local cluster, use the benchmark framework:"
    echo "  cd $ARTIFACT_DIR/benchmark"
    echo "  python3 -m venv .venv && source .venv/bin/activate"
    echo "  pip install -r requirements.txt"
    echo "  python3 -c 'from benchmark.local import LocalBench; LocalBench(4).run()'"
fi

echo ""
echo "=== Done ==="
