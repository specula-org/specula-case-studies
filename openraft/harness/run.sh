#!/bin/bash
# Build and run TLA+ trace generation for openraft.
#
# Usage:
#   cd case-studies/openraft && bash harness/run.sh
#
# Environment:
#   TLA_TRACE_FILE  Override output path (default: traces/<scenario>.ndjson)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT_DIR="$CASE_DIR/artifact/openraft"
TRACES_DIR="$CASE_DIR/traces"

# Ensure Rust is available
if ! command -v cargo &>/dev/null; then
    if [ -f "$HOME/.cargo/env" ]; then
        . "$HOME/.cargo/env"
    else
        echo "ERROR: cargo not found. Install Rust first."
        exit 1
    fi
fi

echo "=== TLA+ Trace Generation for openraft ==="
echo "Artifact: $ARTIFACT_DIR"
echo "Traces:   $TRACES_DIR"

# Step 1: Apply instrumentation
bash "$SCRIPT_DIR/apply.sh"

# Step 2: Create traces directory
mkdir -p "$TRACES_DIR"

# Step 3: Build (compile check)
echo ""
echo "--- Building openraft with tla-trace feature"
cd "$ARTIFACT_DIR"
cargo test -p tests --test tla_trace --no-run 2>&1 | tail -5

# Step 4: Run test scenarios
echo ""
echo "--- Running: basic_consensus"
TLA_TRACE_FILE="$TRACES_DIR/basic_consensus.ndjson" \
    cargo test -p tests --test tla_trace -- tla_trace_basic_consensus --nocapture --test-threads=1 \
    2>&1 | tail -10

# Step 5: Report results
echo ""
echo "=== Trace Generation Results ==="
for f in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$f" ]; then
        lines=$(wc -l < "$f")
        echo "  $(basename "$f"): $lines lines"
        echo "  First 3 lines:"
        head -3 "$f" | python3 -m json.tool --compact 2>/dev/null || head -3 "$f"
        echo ""
    fi
done

echo "=== Done ==="
