#!/usr/bin/env bash
# Build instrumented Kudu consensus, run trace tests, collect NDJSON traces.
# Usage: cd case-studies/kudu && bash harness/run.sh
set -euo pipefail
cd "$(dirname "$0")/.."

ARTIFACT="artifact/incubator-kudu"
BUILD_DIR="$ARTIFACT/build"
TRACES_DIR="traces"

echo "============================================"
echo " Kudu Raft TLA+ Trace Harness"
echo "============================================"

# Step 1: Apply instrumentation
echo ""
echo "--- Step 1: Apply instrumentation ---"
bash harness/apply.sh

# Step 2: Copy test file into the source tree
echo ""
echo "--- Step 2: Copy test scenario ---"
cp harness/src/tla_trace_test.cc "$ARTIFACT/src/kudu/consensus/tla_trace_test.cc"

# Add test to CMakeLists.txt if not already present
if ! grep -q 'tla_trace_test' "$ARTIFACT/src/kudu/consensus/CMakeLists.txt"; then
  echo 'ADD_KUDU_TEST(tla_trace_test)' >> "$ARTIFACT/src/kudu/consensus/CMakeLists.txt"
fi

# Step 3: Build thirdparty if needed
echo ""
echo "--- Step 3: Build ---"
if [ ! -d "$ARTIFACT/thirdparty/installed" ]; then
  echo "Building thirdparty dependencies (one-time, may take 20-60 min)..."
  (cd "$ARTIFACT" && bash thirdparty/build-if-necessary.sh 2>&1 | tail -5)
fi

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Configure if needed (use release with debug info for speed)
if [ ! -f "CMakeCache.txt" ]; then
  echo "Running CMake..."
  export PATH="$(cd .. && pwd)/thirdparty/installed/common/bin:$PATH"
  cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DNO_TESTS=0 \
    2>&1 | tail -5
fi

echo "Building consensus library and trace test..."
# Build just the consensus library and our test (not the entire project)
make -j"$(nproc)" tla_trace_test 2>&1 | tail -20
cd ../..

echo "Build complete."

# Step 4: Run tests and collect traces
echo ""
echo "--- Step 4: Run tests ---"
mkdir -p "$TRACES_DIR"

TEST_BIN="$BUILD_DIR/bin/tla_trace_test"

if [ ! -x "$TEST_BIN" ]; then
  echo "ERROR: Test binary not found at $TEST_BIN"
  exit 1
fi

# Scenario 1: Basic election + replication
TRACE_FILE="$TRACES_DIR/basic_election.ndjson"
echo "Running BasicElectionAndReplication → $TRACE_FILE"
KUDU_TRACE_FILE="$(pwd)/$TRACE_FILE" \
  "$TEST_BIN" --gtest_filter=TlaTraceTest.BasicElectionAndReplication \
  2>&1 | tail -20

# Step 5: Report
echo ""
echo "--- Step 5: Trace summary ---"
for f in "$TRACES_DIR"/*.ndjson; do
  if [ -f "$f" ]; then
    lines=$(wc -l < "$f")
    events=$(grep -c '"tag":"trace"' "$f" || true)
    echo "  $f: $lines lines, $events trace events"
    # Show first 3 events
    head -3 "$f" | python3 -m json.tool --compact 2>/dev/null || head -3 "$f"
    echo "  ..."
  fi
done

echo ""
echo "============================================"
echo " Trace collection complete."
echo "============================================"
