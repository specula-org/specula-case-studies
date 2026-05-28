#!/bin/bash
# run.sh — One-shot: apply instrumentation, build libgomp_3, run all
# scenarios, merge per-thread NDJSON traces into final JSON.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Script lives in .specula-output/harness/.  Case study root is two levels up.
CASE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARTIFACT="$CASE_DIR/artifact/gcc"
LIBGOMP_SRC="$ARTIFACT/libgomp"
BUILD_DIR="$ARTIFACT/build-libgomp"
# Traces live alongside the spec/harness inside .specula-output.
TRACES_DIR="$CASE_DIR/.specula-output/traces"
HARNESS_SRC="$SCRIPT_DIR/src"

mkdir -p "$TRACES_DIR"
# Wipe stale per-thread NDJSON from any prior run.
rm -f "$TRACES_DIR"/*-thread-*.ndjson "$TRACES_DIR"/*.ndjson

echo "=== Step 1: Apply instrumentation ==="
bash "$SCRIPT_DIR/apply.sh"

echo "=== Step 2: Configure (if needed) and build libgomp ==="
if [ ! -f "$BUILD_DIR/Makefile" ]; then
    mkdir -p "$BUILD_DIR"
    (cd "$BUILD_DIR" && ../libgomp/configure \
        --prefix="$BUILD_DIR/install" \
        --disable-multilib \
        CC=gcc CXX=g++)
fi

# Force a rebuild of the instrumented translation units so changes pick up.
rm -f "$BUILD_DIR"/.libs/{bar,task,team,parallel}.o
rm -f "$BUILD_DIR"/{bar,task,team,parallel}.o

(cd "$BUILD_DIR" && timeout 600 make -j$(nproc) CFLAGS="-g -O2 -pthread -Wno-error" >/dev/null)
echo "  libgomp.so built."

LIBGOMP_SO="$BUILD_DIR/.libs/libgomp.so.1.0.0"
if [ ! -f "$LIBGOMP_SO" ]; then
    echo "ERROR: libgomp.so not found at $LIBGOMP_SO"
    exit 1
fi

echo "=== Step 3: Compile test scenarios ==="

# omp.h is generated into the build dir.
OMP_INCLUDE="$BUILD_DIR"
COMPILE_FLAGS=(-g -O1 -fopenmp -I"$OMP_INCLUDE")
LINK_FLAGS=(-L"$BUILD_DIR/.libs" -Wl,-rpath,"$BUILD_DIR/.libs")

for src in "$HARNESS_SRC"/test_*.c; do
    test_name=$(basename "$src" .c)
    echo "  Compiling $test_name"
    gcc "${COMPILE_FLAGS[@]}" "$src" -o "$BUILD_DIR/$test_name" \
        "${LINK_FLAGS[@]}" -lgomp -lpthread -lrt
done

echo "=== Step 4: Run test scenarios ==="

run_scenario() {
    local name="$1"
    local bin="$BUILD_DIR/$name"
    if [ ! -x "$bin" ]; then
        echo "  SKIP $name (no binary)"
        return
    fi
    echo "  Running $name"
    TLA_TRACE_FILE="$name" \
    TLA_TRACE_DIR="$TRACES_DIR" \
    OMP_CANCELLATION=true \
    OMP_NUM_THREADS=2 \
    LD_PRELOAD="$LIBGOMP_SO" \
        timeout 60 "$bin" >/dev/null 2>&1 || {
            echo "    (test exited non-zero — may be OK if cancel-related)"
        }
    # Count lines per per-thread file.
    local per_files=( "$TRACES_DIR/$name"-thread-*.ndjson )
    if [ -e "${per_files[0]}" ]; then
        local sum=0
        for f in "${per_files[@]}"; do
            local n
            n=$(wc -l < "$f")
            sum=$((sum + n))
        done
        echo "    $sum NDJSON lines across $(ls "$TRACES_DIR/$name"-thread-*.ndjson | wc -l) thread files"
    else
        echo "    WARNING: no per-thread files produced for $name"
    fi
}

for src in "$HARNESS_SRC"/test_*.c; do
    name=$(basename "$src" .c)
    run_scenario "$name"
done

echo "=== Step 5: Preprocess traces ==="

for src in "$HARNESS_SRC"/test_*.c; do
    name=$(basename "$src" .c)
    files=( "$TRACES_DIR/$name"-thread-*.ndjson )
    if [ ! -e "${files[0]}" ]; then
        continue
    fi
    output="$TRACES_DIR/${name}.ndjson"
    python3 "$SCRIPT_DIR/preprocess_trace.py" "${files[@]}" "$output"
done

echo "=== Step 6: Trace summary ==="
for f in "$TRACES_DIR"/*.ndjson; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    case "$base" in
        *-thread-*) continue ;;
    esac
    bytes=$(wc -c < "$f")
    echo "  $base — $bytes bytes"
done

echo ""
echo "=== Done ==="
