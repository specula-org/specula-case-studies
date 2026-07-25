#!/usr/bin/env bash
# run.sh — apply instrumentation, build, run test, collect traces
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$SCRIPT_DIR/.."
ARTIFACT_DIR="$BASE_DIR/artifact/libspdm"
BUILD_DIR="$BASE_DIR/artifact/build"
TRACES_DIR="$BASE_DIR/traces"

mkdir -p "$TRACES_DIR"

# ---- Step 1: Apply instrumentation ----
echo "[run] Applying instrumentation patch..."
bash "$SCRIPT_DIR/apply.sh"

# ---- Step 2: Configure (only if not already configured) ----
if [ ! -f "$BUILD_DIR/CMakeCache.txt" ]; then
    echo "[run] Configuring cmake build..."
    mkdir -p "$BUILD_DIR"
    cmake -S "$ARTIFACT_DIR" -B "$BUILD_DIR" \
        -DARCH=x64 \
        -DTOOLCHAIN=GCC \
        -DTARGET=Debug \
        -DCRYPTO=mbedtls \
        -DDISABLE_TESTS=0 \
        -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
fi

# ---- Step 3: Build the trace test binary ----
echo "[run] Building test_spdm_psk_trace..."
cmake --build "$BUILD_DIR" --target test_spdm_psk_trace -j"$(nproc)" 2>&1

TEST_BIN=$(find "$BUILD_DIR" -name "test_spdm_psk_trace" -type f | head -1)
if [ -z "$TEST_BIN" ]; then
    echo "[run] ERROR: test_spdm_psk_trace binary not found after build"
    exit 1
fi
echo "[run] Binary: $TEST_BIN"

# ---- Step 4: Run test scenarios ----
echo "[run] Running trace collection..."
export TLA_TRACE_DIR="$TRACES_DIR"

cd "$BUILD_DIR"
timeout 120 "$TEST_BIN"

# ---- Step 5: Report ----
echo ""
echo "[run] Trace files generated:"
for f in "$TRACES_DIR"/*.ndjson; do
    count=$(grep -c '"tag":"trace"' "$f" 2>/dev/null || echo 0)
    echo "  $f  ($count trace events)"
done
