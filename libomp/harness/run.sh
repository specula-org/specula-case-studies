#!/bin/bash
# run.sh — One-command: apply instrumentation, build libomp, run tests, collect traces
#
# Usage: cd case-studies/libomp && bash harness/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT="$CASE_DIR/artifact/llvm-project"
BUILD_DIR="$CASE_DIR/artifact/build-trace"
TRACES_DIR="$CASE_DIR/traces"
SRC="$ARTIFACT/openmp/runtime/src"

echo "========================================"
echo "  libomp Trace Harness"
echo "========================================"

# Step 1: Apply instrumentation
echo ""
echo "[Step 1/5] Applying instrumentation..."
bash "$SCRIPT_DIR/apply.sh"

# Step 2: Build libomp with LIBOMP_TRACE enabled
echo ""
echo "[Step 2/5] Building libomp with LIBOMP_TRACE..."
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

cmake -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Debug \
    -DCMAKE_C_COMPILER=clang \
    -DCMAKE_CXX_COMPILER=clang++ \
    -DLLVM_ENABLE_RUNTIMES=openmp \
    -DLIBOMP_ENABLE_ASSERTIONS=ON \
    -DLIBOMP_OMPT_SUPPORT=OFF \
    -DLIBOMP_OMPD_SUPPORT=OFF \
    -DCMAKE_C_FLAGS="-DLIBOMP_TRACE" \
    -DCMAKE_CXX_FLAGS="-DLIBOMP_TRACE" \
    "$ARTIFACT/runtimes" 2>&1 | tail -5

make -j$(nproc) omp 2>&1 | tail -5

# Find the built library
LIBOMP_SO=$(find "$BUILD_DIR" -name "libomp.so" -o -name "libomp.dylib" | head -1)
if [ -z "$LIBOMP_SO" ]; then
    echo "ERROR: Could not find built libomp.so"
    exit 1
fi
LIBOMP_DIR=$(dirname "$LIBOMP_SO")
echo "  Built: $LIBOMP_SO"

# Also find the omp.h header
OMP_HEADER=$(find "$BUILD_DIR" -name "omp.h" | head -1)
if [ -z "$OMP_HEADER" ]; then
    echo "ERROR: Could not find omp.h"
    exit 1
fi
OMP_INCLUDE=$(dirname "$OMP_HEADER")

# Step 3: Compile test scenarios
echo ""
echo "[Step 3/5] Compiling test scenarios..."
TEST_DIR="$BUILD_DIR/tests"
mkdir -p "$TEST_DIR"

COMPILE_FLAGS="-fopenmp -I$OMP_INCLUDE -L$LIBOMP_DIR -Wl,-rpath,$LIBOMP_DIR"

clang $COMPILE_FLAGS -o "$TEST_DIR/test_basic_barrier" \
    "$SCRIPT_DIR/src/test_basic_barrier.c" 2>&1
echo "  Compiled test_basic_barrier"

clang $COMPILE_FLAGS -o "$TEST_DIR/test_task_steal" \
    "$SCRIPT_DIR/src/test_task_steal.c" 2>&1
echo "  Compiled test_task_steal"

clang $COMPILE_FLAGS -o "$TEST_DIR/test_detach_task" \
    "$SCRIPT_DIR/src/test_detach_task.c" 2>&1
echo "  Compiled test_detach_task"

clang $COMPILE_FLAGS -o "$TEST_DIR/test_cancel_barrier" \
    "$SCRIPT_DIR/src/test_cancel_barrier.c" 2>&1
echo "  Compiled test_cancel_barrier"

# Step 4: Run tests and collect traces
echo ""
echo "[Step 4/5] Running tests and collecting traces..."
mkdir -p "$TRACES_DIR"

run_test() {
    local test_name="$1"
    local test_bin="$TEST_DIR/$test_name"
    local trace_file="$TRACES_DIR/${test_name}.ndjson"

    echo "  Running $test_name..."
    OMP_TRACE_FILE="$trace_file" \
    OMP_NUM_THREADS=3 \
    KMP_PLAIN_BARRIER_PATTERN="linear,linear" \
    LD_LIBRARY_PATH="$LIBOMP_DIR:${LD_LIBRARY_PATH:-}" \
    "$test_bin" 2>&1 | sed 's/^/    /'

    if [ -f "$trace_file" ]; then
        # Preprocess: sort by timestamp, filter out fork barrier events
        python3 "$SCRIPT_DIR/src/preprocess_trace.py" "$trace_file" "$trace_file.tmp"
        mv "$trace_file.tmp" "$trace_file"
        local lines=$(wc -l < "$trace_file")
        echo "    -> $trace_file ($lines lines)"
    else
        echo "    -> WARNING: No trace file generated"
    fi
}

run_test "test_basic_barrier"
run_test "test_task_steal"
run_test "test_detach_task"
run_test "test_cancel_barrier"

# Step 5: Report
echo ""
echo "[Step 5/5] Trace summary:"
echo "========================================"
for f in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$f" ]; then
        lines=$(wc -l < "$f")
        name=$(basename "$f")
        # Verify JSON
        bad_lines=$(python3 -c "
import json, sys
bad = 0
for line in open('$f'):
    line = line.strip()
    if not line: continue
    try:
        json.loads(line)
    except:
        bad += 1
print(bad)
" 2>/dev/null || echo "?")
        echo "  $name: $lines events ($bad_lines bad JSON lines)"
    fi
done
echo "========================================"
echo "DONE. Traces are in $TRACES_DIR"
