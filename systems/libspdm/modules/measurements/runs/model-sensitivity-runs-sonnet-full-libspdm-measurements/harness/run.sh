#!/usr/bin/env bash
# run.sh — Apply instrumentation, build, run tests, collect traces.
#
# Must be run from the libspdm-measurements/ directory:
#   cd /path/to/libspdm-measurements && bash harness/run.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ARTIFACT="$ROOT_DIR/artifact/libspdm"
TRACES_DIR="$ROOT_DIR/traces"
BUILD_DIR="$ARTIFACT/build"

echo "=== Step 1: Apply instrumentation ==="
bash "$SCRIPT_DIR/apply.sh"

echo ""
echo "=== Step 2: CMake configure ==="
mkdir -p "$BUILD_DIR"
cmake -S "$ARTIFACT" -B "$BUILD_DIR" \
    -DARCH=x64 \
    -DTOOLCHAIN=GCC \
    -DTARGET=Debug \
    -DCRYPTO=mbedtls \
    -DDISABLE_TESTS=0 \
    -DCMAKE_C_FLAGS="-DLIBSPDM_RECORD_TRANSCRIPT_DATA_SUPPORT=1" \
    -DLIBSPDM_DIR="$ARTIFACT" \
    -DDEVICE=sample

echo ""
echo "=== Step 3: Build ==="
timeout 600 cmake --build "$BUILD_DIR" --target spdm_trace_test copy_sample_key -j"$(nproc)"

echo ""
echo "=== Step 4: Run test scenarios ==="
mkdir -p "$TRACES_DIR"
TRACE_BIN="$BUILD_DIR/bin/spdm_trace_test"
if [ ! -f "$TRACE_BIN" ]; then
    # Try alternate build output location
    TRACE_BIN="$(find "$BUILD_DIR" -name "spdm_trace_test" -type f 2>/dev/null | head -1)"
fi
if [ -z "$TRACE_BIN" ] || [ ! -f "$TRACE_BIN" ]; then
    echo "ERROR: spdm_trace_test binary not found in $BUILD_DIR"
    exit 1
fi

# Run from the bin/ directory so cert chain files (ecp256/...) are accessible
BIN_DIR="$BUILD_DIR/bin"
if [ ! -d "$BIN_DIR" ]; then
    BIN_DIR="$(dirname "$TRACE_BIN")"
fi

echo "Running spdm_trace_test from $BIN_DIR..."
(cd "$BIN_DIR" && timeout 120 "$TRACE_BIN" "$TRACES_DIR")

echo ""
echo "=== Step 5: Trace summary ==="
for f in "$TRACES_DIR"/*.ndjson; do
    [ -f "$f" ] || continue
    count=$(wc -l < "$f")
    echo "  $(basename "$f"): $count events"
done

echo ""
echo "=== Done. Traces in $TRACES_DIR/ ==="
