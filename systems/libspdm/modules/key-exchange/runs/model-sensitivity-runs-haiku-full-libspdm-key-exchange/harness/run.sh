#!/bin/bash
#
# run.sh: One-command trace collection for SPDM KEY_EXCHANGE / FINISH protocol
#
# This script:
# 1. Applies instrumentation (via apply.sh)
# 2. Builds the test harness
# 3. Runs test scenarios
# 4. Collects NDJSON traces
#
# Usage: bash harness/run.sh
#        cd .. && bash harness/run.sh
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ARTIFACT_DIR="$PROJECT_DIR/artifact/libspdm"
TRACES_DIR="$PROJECT_DIR/traces"
HARNESS_SRC="$SCRIPT_DIR/src"

echo "========================================"
echo "SPDM KEY_EXCHANGE / FINISH Trace Generation"
echo "========================================"

# Ensure traces directory exists
mkdir -p "$TRACES_DIR"

# Step 1: Apply instrumentation
echo ""
echo "[1/4] Applying instrumentation..."
bash "$SCRIPT_DIR/apply.sh"

# Step 2: Compile test harness and trace module
echo ""
echo "[2/4] Compiling test harness..."
COMPILE_CMD="gcc -pthread -o $TRACES_DIR/test_harness $HARNESS_SRC/tla_trace.c $HARNESS_SRC/test_harness.c"
echo "  Running: $COMPILE_CMD"
if ! eval "$COMPILE_CMD" 2>/dev/null; then
    # Try with standard library flags
    COMPILE_CMD="gcc -pthread -lm -o $TRACES_DIR/test_harness $HARNESS_SRC/tla_trace.c $HARNESS_SRC/test_harness.c"
    echo "  Retrying with math library: $COMPILE_CMD"
    eval "$COMPILE_CMD" || {
        echo "[!] Compilation failed. Trying minimal flags..."
        gcc -o $TRACES_DIR/test_harness $HARNESS_SRC/tla_trace.c $HARNESS_SRC/test_harness.c
    }
fi

if [ ! -f "$TRACES_DIR/test_harness" ]; then
    echo "[!] Failed to compile test harness"
    exit 1
fi

# Step 3: Run test scenarios with timeout
echo ""
echo "[3/4] Running test scenarios..."
timeout 30 "$TRACES_DIR/test_harness" "$TRACES_DIR" || {
    EXIT_CODE=$?
    if [ $EXIT_CODE -eq 124 ]; then
        echo "[!] Test harness timed out (deadlock detected)"
        exit 1
    fi
    # Other exit codes might indicate test failure
    exit $EXIT_CODE
}

# Step 4: Verify traces were generated
echo ""
echo "[4/4] Verifying traces..."
TRACE_COUNT=$(find "$TRACES_DIR" -name "*.ndjson" -type f | wc -l)
if [ $TRACE_COUNT -eq 0 ]; then
    echo "[!] No trace files generated"
    exit 1
fi

echo ""
echo "========================================"
echo "Trace Collection Complete"
echo "========================================"
echo ""

for tracefile in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$tracefile" ]; then
        LINES=$(wc -l < "$tracefile")
        echo "✓ $(basename "$tracefile"): $LINES events"
    fi
done

echo ""
echo "Traces are in: $TRACES_DIR"
echo ""
echo "Event type coverage:"
for tracefile in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$tracefile" ]; then
        echo ""
        echo "  $(basename "$tracefile"):"
        grep -o '"name":"[^"]*"' "$tracefile" | cut -d'"' -f4 | sort | uniq -c | sed 's/^/    /'
    fi
done

echo ""
echo "Ready for trace validation with Trace.tla"
