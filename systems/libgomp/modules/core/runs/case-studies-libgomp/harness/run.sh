#!/bin/bash
# run.sh — Build instrumented libgomp, compile tests, run them, collect traces.
# Run from the case study root directory.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT="$CASE_DIR/artifact/gcc"
LIBGOMP="$ARTIFACT/libgomp"
BUILD_DIR="$ARTIFACT/build-libgomp"
TRACES_DIR="$CASE_DIR/traces"
HARNESS_SRC="$SCRIPT_DIR/src"

echo "=== Step 1: Apply instrumentation ==="
bash "$SCRIPT_DIR/apply.sh"

echo "=== Step 2: Build instrumented libgomp ==="
# Configure if needed.
if [ ! -f "$BUILD_DIR/Makefile" ]; then
    mkdir -p "$BUILD_DIR"
    (cd "$BUILD_DIR" && ../libgomp/configure \
        --prefix="$BUILD_DIR/install" \
        --disable-multilib \
        CC=gcc CXX=g++)
fi

# Ensure support files.
mkdir -p "$ARTIFACT/gcc"
[ -f "$ARTIFACT/gcc/BASE-VER" ] || echo "16.0.0" > "$ARTIFACT/gcc/BASE-VER"
[ -f "$ARTIFACT/gcc/DEV-PHASE" ] || echo "" > "$ARTIFACT/gcc/DEV-PHASE"
touch "$BUILD_DIR/stamp-build-info" 2>/dev/null || true

(cd "$BUILD_DIR" && make -j$(nproc) CFLAGS="-g -O2 -pthread -Wno-error")
echo "  libgomp.so built."

LIBGOMP_SO="$BUILD_DIR/.libs/libgomp.so.1.0.0"
if [ ! -f "$LIBGOMP_SO" ]; then
    echo "ERROR: libgomp.so not found at $LIBGOMP_SO"
    exit 1
fi

echo "=== Step 3: Compile test scenarios ==="
mkdir -p "$TRACES_DIR"

# Include path for omp.h from the build.
OMP_INCLUDE="$BUILD_DIR"
# Link against our custom libgomp.
COMPILE="gcc -g -O1 -fopenmp -I$OMP_INCLUDE -L$BUILD_DIR/.libs -Wl,-rpath,$BUILD_DIR/.libs"

for src in "$HARNESS_SRC"/test_*.c; do
    test_name=$(basename "$src" .c)
    echo "  Compiling $test_name..."
    $COMPILE "$src" -o "$BUILD_DIR/$test_name" -lgomp -lpthread -lrt 2>&1 || {
        echo "  WARNING: Failed to compile $test_name, trying with system headers..."
        gcc -g -O1 -fopenmp "$src" -o "$BUILD_DIR/$test_name" -lpthread -lrt 2>&1
    }
done

echo "=== Step 4: Run test scenarios ==="

run_test() {
    local test_name="$1"
    local trace_file="$TRACES_DIR/${test_name}.ndjson"
    echo "  Running $test_name -> $trace_file"
    TLA_TRACE_FILE="$trace_file" \
    OMP_CANCELLATION=true \
    OMP_NUM_THREADS=3 \
    LD_PRELOAD="$LIBGOMP_SO" \
        "$BUILD_DIR/$test_name" 2>&1 || true
    if [ -f "$trace_file" ]; then
        local count=$(wc -l < "$trace_file")
        echo "    $count trace events"
    else
        echo "    WARNING: No trace file generated"
    fi
}

for test_bin in "$BUILD_DIR"/test_*; do
    [ -x "$test_bin" ] || continue
    test_name=$(basename "$test_bin")
    run_test "$test_name"
done

echo "=== Step 5: Trace summary ==="
echo ""
for trace in "$TRACES_DIR"/*.ndjson; do
    [ -f "$trace" ] || continue
    name=$(basename "$trace")
    lines=$(wc -l < "$trace")
    events=$(grep -c '"tag":"barrier"' "$trace" 2>/dev/null || echo 0)
    echo "  $name: $lines lines, $events barrier events"
done
echo ""
echo "=== Done ==="
