#!/usr/bin/env bash
# run.sh — Build and run trace-collection tests, deposit traces.
# Usage: bash harness/run.sh
# Run from: .../libspdm-secured-message/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="$(dirname "$SCRIPT_DIR")"
ARTIFACT="$RUN_DIR/artifact/libspdm"
BUILD_DIR="$RUN_DIR/artifact/build_tla"
TRACE_DIR="$RUN_DIR/traces"

# Step 1: Apply harness source files
echo "=== Step 1: Apply harness ==="
bash "$SCRIPT_DIR/apply.sh"

# Step 2: Build
echo "=== Step 2: Configure ==="
mkdir -p "$BUILD_DIR"
cmake -S "$ARTIFACT" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DARCH=x64 \
    -DTOOLCHAIN=GCC \
    -DTARGET=Release \
    -DCRYPTO=mbedtls \
    -DDEVICE=sample \
    -DSPDM_TLA_TRACE=ON \
    -DLIBSPDM_DIR="$ARTIFACT" \
    -DUSE_STATIC_MBEDTLS_LIBRARY=ON \
    -DUSE_SHARED_MBEDTLS_LIBRARY=OFF \
    -DENABLE_PROGRAMS=OFF \
    -DENABLE_TESTING=OFF \
    2>&1 | tail -20

echo "=== Step 3: Build test target ==="
cmake --build "$BUILD_DIR" --target test_spdm_secured_message -j"$(nproc)" 2>&1 | tail -30

# Step 4: Run tests and collect traces
echo "=== Step 4: Run trace scenarios ==="
mkdir -p "$TRACE_DIR"
TEST_BIN="$BUILD_DIR/bin/test_spdm_secured_message"
if [ ! -f "$TEST_BIN" ]; then
    TEST_BIN="$BUILD_DIR/unit_test/test_spdm_secured_message/test_spdm_secured_message"
fi
TLA_TRACE_DIR="$TRACE_DIR" timeout 120 "$TEST_BIN"

# Step 5: Report
echo ""
echo "=== Traces collected ==="
for f in "$TRACE_DIR"/*.ndjson; do
    [ -f "$f" ] || continue
    count=$(wc -l < "$f")
    echo "  $(basename "$f"): $count events"
    # Quick sanity: check tag=trace is present
    tag_count=$(grep -c '"tag":"trace"' "$f" 2>/dev/null || echo 0)
    echo "    tag=trace lines: $tag_count"
done
echo ""
echo "Done. Traces are in: $TRACE_DIR"
