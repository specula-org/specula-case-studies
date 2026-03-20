#!/usr/bin/env bash
# One-command: apply instrumentation, build, run tests, collect traces.
# Run from the case study root: cd case-studies/rethinkdb && bash harness/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT_DIR="$CASE_DIR/artifact/rethinkdb"
TRACES_DIR="$CASE_DIR/traces"

echo "============================================================"
echo " RethinkDB Raft Trace Harness"
echo "============================================================"

# ---- Step 1: Apply instrumentation ----
echo ""
echo "[Step 1] Applying instrumentation..."
bash "$SCRIPT_DIR/apply.sh"

# ---- Step 2: Build ----
echo ""
echo "[Step 2] Building rethinkdb with trace instrumentation..."
cd "$ARTIFACT_DIR"

# Build the unit test binary with TLA trace flag
echo "  Building (this may take a while)..."
CXXFLAGS="-DRETHINKDB_TLA_TRACE" make -j"$(nproc)" DEBUG=1 ALLOW_WARNINGS=1 2>&1 | tail -5

UNITTEST_BIN="build/debug/rethinkdb-unittest"
if [ ! -x "$UNITTEST_BIN" ]; then
    echo "ERROR: Could not find $UNITTEST_BIN"
    exit 1
fi
echo "  Found test binary: $UNITTEST_BIN"

# ---- Step 3: Run test scenarios ----
echo ""
echo "[Step 3] Running test scenarios and collecting traces..."
mkdir -p "$TRACES_DIR"

run_scenario() {
    local name="$1"
    local filter="$2"
    local trace_file="$TRACES_DIR/${name}.ndjson"

    echo "  Running scenario: $name ($filter)"
    RAFT_TRACE_FILE="$trace_file" \
        "$ARTIFACT_DIR/$UNITTEST_BIN" \
        --gtest_filter="$filter" \
        2>&1 | tail -3 || true

    if [ -f "$trace_file" ]; then
        local lines
        lines=$(wc -l < "$trace_file")
        echo "    -> $trace_file: $lines trace lines"
    else
        echo "    -> WARNING: No trace file generated"
    fi
}

# Scenario 1: 3-node basic consensus (leader election + writes)
run_scenario "basic_3node" "ClusteringRaft.TraceBasic3"

# Scenario 2: 3-node failover (kill leader, re-election, rejoin)
run_scenario "failover_3node" "ClusteringRaft.TraceFailover3"

# ---- Step 4: Report ----
echo ""
echo "[Step 4] Trace collection summary:"
echo "============================================================"
for f in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$f" ]; then
        lines=$(wc -l < "$f")
        events=$(grep -c '"tag":"raft"' "$f" || echo "0")
        echo "  $(basename "$f"): $lines lines, $events raft events"
    fi
done
echo "============================================================"

# ---- Step 5: Quick validation checks ----
echo ""
echo "[Step 5] Quick trace format validation..."
for f in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$f" ]; then
        name=$(basename "$f")
        if head -10 "$f" | python3 -c "
import sys, json
for line in sys.stdin:
    json.loads(line.strip())
" 2>/dev/null; then
            echo "  $name: JSON valid (first 10 lines)"
        else
            echo "  $name: WARNING - JSON parse error"
        fi
    fi
done

echo ""
echo "Done. Traces are in: $TRACES_DIR/"
echo "To run trace validation:"
echo "  cd spec && java -DJSON=../traces/basic_3node.ndjson \\"
echo "    -cp ../../../lib/tla2tools.jar:../../../lib/CommunityModules-deps.jar \\"
echo "    tlc2.TLC -config Trace.cfg -deadlock Trace"
