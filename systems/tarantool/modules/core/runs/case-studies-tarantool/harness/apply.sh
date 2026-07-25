#!/bin/bash
# Apply TLA+ trace instrumentation to tarantool artifact.
#
# Usage: cd case-studies/tarantool && bash harness/apply.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT="$CASE_DIR/artifact/tarantool"

echo "=== Applying TLA+ trace instrumentation ==="

# 1. Reset artifact to clean state
echo "Resetting artifact to clean state..."
git -C "$ARTIFACT" checkout -- .

# 2. Apply instrumentation patch to raft.c
echo "Applying instrumentation patch to src/lib/raft/raft.c..."
git -C "$ARTIFACT" apply "$SCRIPT_DIR/patches/instrumentation.patch"

# 3. Copy trace module into the raft library directory
echo "Copying trace module..."
cp "$SCRIPT_DIR/src/tla_trace.h" "$ARTIFACT/src/lib/raft/"
cp "$SCRIPT_DIR/src/tla_trace.c" "$ARTIFACT/src/lib/raft/"

# 4. Copy test file
echo "Copying test scenario..."
cp "$SCRIPT_DIR/src/raft_trace_test.c" "$ARTIFACT/test/unit/"

# 5. Patch CMakeLists to add tla_trace.c to raft_algo library and add test target
echo "Patching build system..."

# Add tla_trace.c to raft_algo (used by unit tests)
RAFT_CMAKE="$ARTIFACT/src/lib/raft/CMakeLists.txt"
if ! grep -q "tla_trace" "$RAFT_CMAKE"; then
    cat >> "$RAFT_CMAKE" <<'CMAKE'

# TLA+ trace instrumentation (conditional on RAFT_TLA_TRACE)
if(RAFT_TLA_TRACE)
    add_definitions(-DRAFT_TLA_TRACE)
    target_sources(raft_algo PRIVATE tla_trace.c)
endif()
CMAKE
    echo "  Added tla_trace.c to raft_algo library"
fi

# Add test target
TEST_CMAKE="$ARTIFACT/test/unit/CMakeLists.txt"
if ! grep -q "raft_trace" "$TEST_CMAKE"; then
    cat >> "$TEST_CMAKE" <<'CMAKE'

# TLA+ trace test
if(RAFT_TLA_TRACE)
    create_unit_test(PREFIX raft_trace
                     SOURCES raft_trace_test.c raft_test_utils.c core_test_utils.c
                     LIBRARIES vclock unit fakesys raft_algo
    )
endif()
CMAKE
    echo "  Added raft_trace test target"
fi

echo "=== Instrumentation applied successfully ==="
echo ""
echo "Build with: cd $ARTIFACT && cmake -B build -DRAFT_TLA_TRACE=ON && cmake --build build --target raft_trace.test"
