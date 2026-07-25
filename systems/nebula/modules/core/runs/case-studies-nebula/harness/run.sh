#!/bin/bash
# Build, run tests, and collect TLA+ traces for nebula raft.
# Usage: cd case-studies/nebula && bash harness/run.sh
#
# Prerequisites: nebula build dependencies installed (CMake, folly, thrift, etc.)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$SCRIPT_DIR/.."
ARTIFACT="$CASE_DIR/artifact/nebula"
BUILD_DIR="$ARTIFACT/build"
TRACES_DIR="$CASE_DIR/traces"

echo "============================================="
echo "  Nebula Raft Trace Harness"
echo "============================================="

# 1. Apply instrumentation
echo ""
echo "=== Step 1: Apply instrumentation ==="
bash "$SCRIPT_DIR/apply.sh"

# 2. Build with trace enabled
echo ""
echo "=== Step 2: Build with NEBULA_ENABLE_TRACE ==="
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

cmake .. \
    -DCMAKE_BUILD_TYPE=Debug \
    -DWITH_NEBULA_TRACE=ON \
    -DENABLE_TESTING=ON \
    -DENABLE_JEMALLOC=ON \
    -DCMAKE_CXX_FLAGS="-Wno-interference-size -Wno-redundant-move" \
    2>&1 | tail -5

# Build only the trace test target
# Note: the test binary links all raftex objects including trace_logger
echo "Building trace_test..."
make -j$(nproc) trace_test 2>&1 | tail -20
echo "Build complete."

# 3. Run tests and collect traces
echo ""
echo "=== Step 3: Run trace tests ==="
mkdir -p "$TRACES_DIR"
cd "$TRACES_DIR"

# Clean old traces
rm -f "$TRACES_DIR"/*.ndjson

# Run the trace test binary
TEST_BIN="$BUILD_DIR/bin/test/trace_test"
if [ ! -f "$TEST_BIN" ]; then
    # Try alternate location
    TEST_BIN=$(find "$BUILD_DIR" -name "trace_test" -type f -executable | head -1)
fi

if [ -z "$TEST_BIN" ] || [ ! -f "$TEST_BIN" ]; then
    echo "ERROR: trace_test binary not found in build directory"
    echo "Listing build dir:"
    find "$BUILD_DIR" -name "*trace*" 2>/dev/null || true
    exit 1
fi

echo "Running: $TEST_BIN"
echo "Trace files will be written to: $TRACES_DIR"

# Run each test filter separately to get separate trace files
# Note: must use absolute paths for --nebula_trace_file
echo ""
echo "--- Running BasicConsensus ---"
"$TEST_BIN" --gtest_filter="TraceTest.BasicConsensus" \
    --nebula_trace_enabled=true \
    --nebula_trace_file="$TRACES_DIR/basic_consensus.ndjson" \
    --raft_heartbeat_interval_secs=1 \
    --v=0 2>&1 | tail -5 || echo "BasicConsensus FAILED (see above)"

echo ""
echo "--- Running LeaderCrashReelection ---"
"$TEST_BIN" --gtest_filter="TraceTest.LeaderCrashReelection" \
    --nebula_trace_enabled=true \
    --nebula_trace_file="$TRACES_DIR/leader_crash_reelection.ndjson" \
    --raft_heartbeat_interval_secs=1 \
    --v=0 2>&1 | tail -5 || echo "LeaderCrashReelection FAILED (see above)"

echo ""
echo "--- Running LogReplication ---"
"$TEST_BIN" --gtest_filter="TraceTest.LogReplication" \
    --nebula_trace_enabled=true \
    --nebula_trace_file="$TRACES_DIR/log_replication.ndjson" \
    --raft_heartbeat_interval_secs=1 \
    --v=0 2>&1 | tail -5 || echo "LogReplication FAILED (see above)"

# 4. Report results
echo ""
echo "=== Step 4: Trace collection results ==="
echo ""
for f in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$f" ]; then
        lines=$(wc -l < "$f")
        events=$(grep -c '"tag":"trace"' "$f" || echo 0)
        echo "  $(basename "$f"): $lines lines, $events trace events"
    fi
done

echo ""
echo "=== Spot-checking trace format ==="
for f in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$f" ]; then
        echo ""
        echo "--- $(basename "$f") first 3 events: ---"
        head -3 "$f"
        # Validate JSON
        if python3 -c "
import json, sys
with open('$f') as fp:
    for i, line in enumerate(fp):
        try:
            json.loads(line)
        except json.JSONDecodeError as e:
            print(f'  ERROR line {i+1}: {e}')
            sys.exit(1)
print('  JSON valid')
" 2>/dev/null; then
            true
        else
            echo "  WARNING: JSON validation failed"
        fi
    fi
done

echo ""
echo "============================================="
echo "  Trace collection complete."
echo "  Traces in: $TRACES_DIR/"
echo "============================================="
