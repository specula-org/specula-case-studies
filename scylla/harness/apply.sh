#!/bin/bash
# Apply TLA+ trace instrumentation to ScyllaDB Raft.
#
# Usage: bash harness/apply.sh
# Run from: case-studies/scylla/

set -euo pipefail

CASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCYLLA_ROOT="$CASE_DIR/artifact/scylla"
HARNESS_DIR="$CASE_DIR/harness"

echo "=== Applying TLA+ trace instrumentation ==="
echo "  ScyllaDB root: $SCYLLA_ROOT"
echo "  Harness dir:   $HARNESS_DIR"

# 1. Revert any previous instrumentation
echo "  Reverting previous changes..."
cd "$SCYLLA_ROOT"
git checkout -- raft/fsm.cc raft/fsm.hh 2>/dev/null || true
rm -f raft/tla_trace.hh
git checkout -- test/raft/CMakeLists.txt 2>/dev/null || true

# 2. Run the instrumentation script
echo "  Running instrumentation script..."
python3 "$HARNESS_DIR/apply_instrumentation.py" "$SCYLLA_ROOT"

# 3. Copy trace test into test/raft/
echo "  Copying trace test..."
cp "$HARNESS_DIR/src/trace_test.cc" "$SCYLLA_ROOT/test/raft/trace_test.cc"

# 4. Add trace test to CMakeLists.txt
echo "  Registering trace test in CMakeLists.txt..."
if ! grep -q 'trace_test' "$SCYLLA_ROOT/test/raft/CMakeLists.txt"; then
    cat >> "$SCYLLA_ROOT/test/raft/CMakeLists.txt" <<'EOF'

# TLA+ trace generation test
add_scylla_test(trace_test
  KIND BOOST
  LIBRARIES test-raft)
EOF
fi

# 5. Add -DSCYLLA_TLA_TRACE_ENABLED to raft library build
echo "  Adding trace compile definition..."
if ! grep -q 'SCYLLA_TLA_TRACE_ENABLED' "$SCYLLA_ROOT/raft/CMakeLists.txt"; then
    # Add compile definition after target_link_libraries
    sed -i '/target_link_libraries(raft/a\
target_compile_definitions(raft PUBLIC SCYLLA_TLA_TRACE_ENABLED)' "$SCYLLA_ROOT/raft/CMakeLists.txt"
fi

echo ""
echo "=== Instrumentation applied ==="
echo "  Modified: raft/fsm.cc, raft/fsm.hh, raft/CMakeLists.txt"
echo "  Added:    raft/tla_trace.hh, test/raft/trace_test.cc"
echo ""
echo "  To revert: cd $SCYLLA_ROOT && git checkout -- raft/ test/raft/"
