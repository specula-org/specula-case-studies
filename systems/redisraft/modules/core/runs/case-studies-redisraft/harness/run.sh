#!/bin/bash
# Build instrumented raft library and run trace-generating tests.
# Run from: case-studies/redisraft/
#
# Output: traces/*.ndjson

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT_DIR="$CASE_DIR/artifact/redisraft"
RAFT_DIR="$ARTIFACT_DIR/deps/raft"
TRACES_DIR="$CASE_DIR/traces"

echo "=== RedisRaft Trace Harness ==="

# Step 1: Apply instrumentation
echo ""
echo "--- Step 1: Apply instrumentation ---"
bash "$SCRIPT_DIR/apply.sh"

# Step 2: Build instrumented raft library
echo ""
echo "--- Step 2: Build instrumented raft library ---"
(
    cd "$RAFT_DIR"
    make clean 2>/dev/null || true
    mkdir -p bin

    # Compile raft library objects with trace enabled
    TRACE_CFLAGS="-Iinclude -fno-omit-frame-pointer -fno-common -fsigned-char -g -O2 -DREDISRAFT_ENABLE_TRACE"

    cc $TRACE_CFLAGS -c -o src/raft_server.o src/raft_server.c
    cc $TRACE_CFLAGS -c -o src/raft_server_properties.o src/raft_server_properties.c
    cc $TRACE_CFLAGS -c -o src/raft_node.o src/raft_node.c
    cc $TRACE_CFLAGS -c -o src/raft_log.o src/raft_log.c
    cc $TRACE_CFLAGS -c -o src/tla_trace.o src/tla_trace.c

    ar -r libraft.a src/raft_server.o src/raft_server_properties.o src/raft_node.o src/raft_log.o src/tla_trace.o

    echo "  Built libraft.a with trace instrumentation"
)

# Step 3: Build test binary
echo ""
echo "--- Step 3: Build test binary ---"
(
    cd "$RAFT_DIR"
    TEST_CFLAGS="-Iinclude -fno-omit-frame-pointer -fno-common -fsigned-char -g -O2 -DREDISRAFT_ENABLE_TRACE -fprofile-arcs -ftest-coverage"

    # Compile test objects with trace enabled
    cc $TEST_CFLAGS -c -o src/test-raft_server.o src/raft_server.c
    cc $TEST_CFLAGS -c -o src/test-raft_server_properties.o src/raft_server_properties.c
    cc $TEST_CFLAGS -c -o src/test-raft_node.o src/raft_node.c
    cc $TEST_CFLAGS -c -o src/test-raft_log.o src/raft_log.c
    cc $TEST_CFLAGS -c -o src/test-tla_trace.o src/tla_trace.c

    # Compile test helpers
    cc $TEST_CFLAGS -c -o tests/CuTest.o tests/CuTest.c
    cc $TEST_CFLAGS -c -o tests/linked_list_queue.o tests/linked_list_queue.c
    cc $TEST_CFLAGS -c -o tests/mock_send_functions.o tests/mock_send_functions.c

    # Link test binary — put .o files after .c so linker resolves symbols
    cc $TEST_CFLAGS -Iinclude -o bin/test_trace \
        tests/test_trace.c \
        src/test-raft_server.o src/test-raft_server_properties.o \
        src/test-raft_node.o src/test-raft_log.o src/test-tla_trace.o \
        tests/CuTest.o tests/linked_list_queue.o tests/mock_send_functions.o

    echo "  Built bin/test_trace"
)

# Step 4: Run tests and collect traces
echo ""
echo "--- Step 4: Run tests and collect traces ---"
mkdir -p "$TRACES_DIR"

# Run individual test scenarios with absolute trace paths
(
    cd "$RAFT_DIR"
    RAFT_TRACE_FILE="$TRACES_DIR/basic_consensus.ndjson" ./bin/test_trace basic_consensus
    RAFT_TRACE_FILE="$TRACES_DIR/leader_failover.ndjson" ./bin/test_trace leader_failover
    RAFT_TRACE_FILE="$TRACES_DIR/snapshot_basic.ndjson" ./bin/test_trace snapshot_basic
)

# Step 5: Report
echo ""
echo "--- Step 5: Trace summary ---"
for f in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$f" ]; then
        lines=$(wc -l < "$f")
        name=$(basename "$f")
        echo "  $name: $lines lines"
    fi
done

echo ""
echo "=== Done ==="
