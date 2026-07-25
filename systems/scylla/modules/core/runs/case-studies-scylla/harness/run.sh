#!/bin/bash
# Build instrumented ScyllaDB Raft, run trace tests, collect traces.
#
# Usage: bash harness/run.sh
# Run from: case-studies/scylla/
#
# Prerequisites:
#   - g++-14 (GCC 14+, C++23 support)
#   - libboost-all-dev, libfmt-dev, libxxhash-dev
#   - Git submodules initialized (seastar, abseil)

set -euo pipefail

CASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCYLLA_ROOT="$CASE_DIR/artifact/scylla"
HARNESS_DIR="$CASE_DIR/harness"
TRACES_DIR="$CASE_DIR/traces"
BUILD_DIR="/tmp/scylla_trace_build"

echo "============================================"
echo "  ScyllaDB Raft — TLA+ Trace Generation"
echo "============================================"
echo ""

# --- Step 1: Apply instrumentation ---
echo ">>> Step 1: Apply instrumentation"
bash "$HARNESS_DIR/apply.sh"
echo ""

# --- Step 2: Initialize submodules ---
echo ">>> Step 2: Check submodules"
cd "$SCYLLA_ROOT"
if [ ! -f seastar/include/seastar/core/condition-variable.hh ]; then
    echo "  Initializing git submodules..."
    git submodule update --init --recursive seastar abseil 2>&1 | tail -5
else
    echo "  Submodules already initialized."
fi
echo ""

# --- Step 3: Compile ---
echo ">>> Step 3: Build (standalone compilation)"
mkdir -p "$BUILD_DIR"

CXX="${CXX:-g++-14}"
CXXFLAGS="-std=c++23 -DSCYLLA_TLA_TRACE_ENABLED -DSEASTAR_SCHEDULING_GROUPS_COUNT=16 -DSEASTAR_API_LEVEL=7 -DSEASTAR_LOGGER_COMPILE_TIME_FMT -DXXH_INLINE_ALL -DSEASTAR_SSTRING -DBOOST_TEST_DYN_LINK -I. -Iseastar/include -Iabseil -Iseastar/src -w"

echo "  Compiler: $CXX"
echo "  Compiling raft library..."
for f in raft/fsm.cc raft/log.cc raft/tracker.cc raft/raft.cc; do
    $CXX $CXXFLAGS -c "$f" -o "$BUILD_DIR/$(basename $f .cc).o"
done

echo "  Compiling test helpers (stripped)..."
sed '/^future<> invoke_abortable_on/,/^}$/d' test/raft/helpers.cc > "$BUILD_DIR/helpers_stripped.cc"
$CXX $CXXFLAGS -Itest/raft -c "$BUILD_DIR/helpers_stripped.cc" -o "$BUILD_DIR/helpers.o"

echo "  Compiling trace test..."
$CXX $CXXFLAGS -c test/raft/trace_test.cc -o "$BUILD_DIR/trace_test.o"

echo "  Compiling Seastar sources..."
for f in seastar/src/core/future.cc seastar/src/util/log.cc seastar/src/core/condition-variable.cc seastar/src/core/semaphore.cc; do
    $CXX $CXXFLAGS -c "$f" -o "$BUILD_DIR/seastar_$(basename $f .cc).o"
done

echo "  Compiling stubs..."
$CXX $CXXFLAGS -c "$HARNESS_DIR/src/seastar_stubs.cc" -o "$BUILD_DIR/seastar_stubs.o"

echo "  Linking..."
$CXX -no-pie \
    "$BUILD_DIR/trace_test.o" \
    "$BUILD_DIR/fsm.o" "$BUILD_DIR/log.o" "$BUILD_DIR/tracker.o" "$BUILD_DIR/raft.o" \
    "$BUILD_DIR/helpers.o" \
    "$BUILD_DIR/seastar_future.o" "$BUILD_DIR/seastar_log.o" \
    "$BUILD_DIR/seastar_condition-variable.o" "$BUILD_DIR/seastar_semaphore.o" \
    "$BUILD_DIR/seastar_stubs.o" \
    -lboost_unit_test_framework -lfmt -lxxhash -lboost_program_options \
    -Wl,--allow-multiple-definition \
    -o "$BUILD_DIR/scylla_trace_test"
chmod +x "$BUILD_DIR/scylla_trace_test"
echo "  Build complete: $BUILD_DIR/scylla_trace_test"
echo ""

# --- Step 4: Run trace tests ---
echo ">>> Step 4: Run trace tests"
mkdir -p "$TRACES_DIR"

echo "  --- basic_consensus ---"
SCYLLA_TLA_TRACE=/dev/null \
    "$BUILD_DIR/scylla_trace_test" --run_test=test_trace_basic_consensus 2>&1 | tail -3
cp /tmp/scylla_trace_basic.ndjson "$TRACES_DIR/basic_consensus.ndjson"

echo "  --- leader_change ---"
SCYLLA_TLA_TRACE=/dev/null \
    "$BUILD_DIR/scylla_trace_test" --run_test=test_trace_leader_change 2>&1 | tail -3
cp /tmp/scylla_trace_leader_change.ndjson "$TRACES_DIR/leader_change.ndjson"

echo "  --- commit_and_replicate ---"
SCYLLA_TLA_TRACE=/dev/null \
    "$BUILD_DIR/scylla_trace_test" --run_test=test_trace_commit_and_replicate 2>&1 | tail -3
cp /tmp/scylla_trace_commit.ndjson "$TRACES_DIR/commit_and_replicate.ndjson" 2>/dev/null || true

echo ""

# --- Step 5: Report ---
echo ">>> Step 5: Trace results"
echo ""
for f in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$f" ]; then
        lines=$(wc -l < "$f")
        name=$(basename "$f")
        echo "  $name: $lines events"
        python3 -c "
import json, sys
events = {}
with open('$f') as fh:
    for line in fh:
        obj = json.loads(line)
        name = obj.get('event', {}).get('name', '?')
        events[name] = events.get(name, 0) + 1
for k, v in sorted(events.items()):
    print(f'    {k}: {v}')
" 2>/dev/null
    fi
done

echo ""
echo "=== Trace generation complete ==="
echo "Trace files: $TRACES_DIR/"
