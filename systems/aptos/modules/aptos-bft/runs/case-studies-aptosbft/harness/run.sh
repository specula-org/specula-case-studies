#!/bin/bash
# Build and run the TLA+ trace generation scenario.
#
# Usage:
#   ./run.sh [trace_file]
#
# The trace file defaults to ../traces/trace.ndjson

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT_DIR="$(cd "$SCRIPT_DIR/../artifact/aptos-core" && pwd)"
TRACES_DIR="$(cd "$SCRIPT_DIR/../traces" && pwd)"
TRACE_FILE="${1:-$TRACES_DIR/trace.ndjson}"

# Ensure Rust is available
if ! command -v cargo &>/dev/null; then
    if [ -f "$HOME/.cargo/env" ]; then
        . "$HOME/.cargo/env"
    else
        echo "ERROR: cargo not found. Install Rust first."
        exit 1
    fi
fi

echo "=== TLA+ Trace Generation for Aptos BFT ==="
echo "Artifact dir: $ARTIFACT_DIR"
echo "Trace output: $TRACE_FILE"
echo ""

# Step 1: Apply instrumentation
echo "--- Step 1: Apply instrumentation ---"
bash "$SCRIPT_DIR/apply.sh"
echo ""

# Step 2: Build and run
echo "--- Step 2: Build and run test ---"
mkdir -p "$(dirname "$TRACE_FILE")"

cd "$ARTIFACT_DIR"
export TLA_TRACE_FILE="$TRACE_FILE"
export RUST_LOG=info

# Run only the TLA trace test
cargo test \
    -p aptos-consensus \
    -- tla_trace_basic_consensus \
    --nocapture \
    --test-threads=1 \
    2>&1 | tee "$SCRIPT_DIR/../traces/build.log"

echo ""

# Step 3: Verify trace
if [ -f "$TRACE_FILE" ]; then
    LINES=$(wc -l < "$TRACE_FILE")
    echo "--- Trace generated: $TRACE_FILE ($LINES lines) ---"
    echo "First 5 lines:"
    head -5 "$TRACE_FILE" | python3 -m json.tool --compact 2>/dev/null || head -5 "$TRACE_FILE"
else
    echo "WARNING: Trace file not generated"
fi

echo ""
echo "=== Done ==="
