#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT_DIR="$PROJECT_ROOT/artifact/libspdm"
TRACES_DIR="$PROJECT_ROOT/traces"
HARNESS_DIR="$SCRIPT_DIR"

echo "================================"
echo "libspdm Trace Harness"
echo "================================"
echo "Project root: $PROJECT_ROOT"
echo "Artifact dir: $ARTIFACT_DIR"
echo "Harness dir: $HARNESS_DIR"
echo "Traces output: $TRACES_DIR"
echo ""

# Step 1: Clean previous traces
echo "[1] Cleaning previous traces..."
rm -f "$TRACES_DIR"/*.ndjson

# Step 2: Check if traces directory exists
if [ ! -d "$TRACES_DIR" ]; then
    echo "[2] Creating traces directory..."
    mkdir -p "$TRACES_DIR"
else
    echo "[2] Traces directory exists: $TRACES_DIR"
fi

# Step 3: Build the test harness
echo "[3] Building test harness..."
cd "$HARNESS_DIR"
make clean
make all

# Step 4: Run the test harness
echo "[4] Running test harness to collect traces..."
timeout 30 "$HARNESS_DIR/build/test_measurements" "$TRACES_DIR/trace.ndjson" || true

# Step 5: Verify traces were generated
echo "[5] Verifying trace collection..."
if [ -f "$TRACES_DIR/trace.ndjson" ]; then
    TRACE_LINES=$(wc -l < "$TRACES_DIR/trace.ndjson")
    echo "✓ Trace file generated: $TRACES_DIR/trace.ndjson"
    echo "  Lines: $TRACE_LINES"

    if [ "$TRACE_LINES" -eq 0 ]; then
        echo "  ⚠ WARNING: Trace file is empty!"
    else
        echo "✓ Trace collection complete"
        # Show first few lines
        echo ""
        echo "First 3 trace lines:"
        head -3 "$TRACES_DIR/trace.ndjson"
    fi
else
    echo "✗ ERROR: Trace file was not created!"
    exit 1
fi

echo ""
echo "================================"
echo "Harness execution complete"
echo "================================"
