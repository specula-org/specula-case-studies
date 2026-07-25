#!/bin/bash
# One-command: apply instrumentation, build, run tests, collect traces.
#
# Usage: cd case-studies/tarantool && bash harness/run.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT="$CASE_DIR/artifact/tarantool"
TRACES_DIR="$CASE_DIR/traces"
BUILD_DIR="$ARTIFACT/build"

echo "========================================"
echo "  Tarantool Raft TLA+ Trace Collection"
echo "========================================"

# Step 1: Apply instrumentation
echo ""
echo "[1/5] Applying instrumentation..."
bash "$SCRIPT_DIR/apply.sh"

# Step 2: Build
echo ""
echo "[2/5] Building with TLA+ tracing enabled..."
cmake -B "$BUILD_DIR" -S "$ARTIFACT" \
    -DRAFT_TLA_TRACE=ON \
    -DCMAKE_BUILD_TYPE=Debug \
    2>&1 | tail -5
cmake --build "$BUILD_DIR" --target raft_trace.test -j "$(nproc)" 2>&1 | tail -10
echo "Build complete."

# Step 3: Create traces directory
echo ""
echo "[3/5] Preparing trace output directory..."
mkdir -p "$TRACES_DIR"

# Step 4: Run test scenarios
# Each scenario is run in the same test binary but we run
# multiple times with different RAFT_TRACE_FILE values to separate traces.
# However, since the test binary runs all scenarios sequentially in one process,
# we collect a single combined trace and then split by scenario if needed.
echo ""
echo "[4/5] Running test scenarios..."

TEST_BIN="$BUILD_DIR/test/unit/raft_trace.test"
if [ ! -f "$TEST_BIN" ]; then
    echo "ERROR: Test binary not found at $TEST_BIN"
    echo "Trying alternate location..."
    TEST_BIN=$(find "$BUILD_DIR" -name "raft_trace.test" -type f 2>/dev/null | head -1)
    if [ -z "$TEST_BIN" ]; then
        echo "FATAL: Cannot find raft_trace.test binary"
        exit 1
    fi
fi

TRACE_FILE="$TRACES_DIR/basic_election.ndjson"
echo "  Running all scenarios -> $TRACE_FILE"
RAFT_TRACE_FILE="$TRACE_FILE" "$TEST_BIN" 2>&1 | tail -20
echo ""

# Step 5: Report results
echo ""
echo "[5/5] Trace collection results:"
echo "----------------------------------------"
for f in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$f" ]; then
        lines=$(wc -l < "$f")
        events=$(grep -c '"tag":"trace"' "$f" || true)
        basename_f=$(basename "$f")
        echo "  $basename_f: $lines lines, $events trace events"
    fi
done
echo "----------------------------------------"

# Spot-check: verify JSON validity and event names
echo ""
echo "Spot-checking trace format..."
TRACE_FILE="$TRACES_DIR/basic_election.ndjson"
if [ -f "$TRACE_FILE" ]; then
    # Check first line is valid JSON
    head -1 "$TRACE_FILE" | python3 -m json.tool > /dev/null 2>&1 && \
        echo "  ✓ First line is valid JSON" || \
        echo "  ✗ First line is NOT valid JSON"

    # Check all lines have tag:trace
    non_trace=$(grep -cv '"tag":"trace"' "$TRACE_FILE" || true)
    echo "  Non-trace lines: $non_trace"

    # List unique event names
    echo "  Unique event names:"
    grep -o '"event":"[^"]*"' "$TRACE_FILE" | sort -u | while read -r e; do
        count=$(grep -c "$e" "$TRACE_FILE" || true)
        echo "    $e ($count occurrences)"
    done

    # Check timestamps are real (not sequential integers)
    echo "  Sample timestamps:"
    head -3 "$TRACE_FILE" | grep -o '"ts":"[^"]*"' | head -3
fi

echo ""
echo "Done. Traces are in: $TRACES_DIR/"
