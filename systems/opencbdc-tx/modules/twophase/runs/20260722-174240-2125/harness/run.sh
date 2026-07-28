#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPECULA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACT_DIR="/home/ubuntu/2pc/opencbdc-tx"
BUILD_DIR="${ARTIFACT_DIR}/build"
TRACES_DIR="${SPECULA_DIR}/traces"
PREFIX="${ARTIFACT_DIR}/prefix"

echo "=== Specula: Trace Harness Run ==="

# 1. Apply instrumentation
echo ""
echo "--- Step 1: Apply instrumentation ---"
bash "${SCRIPT_DIR}/apply.sh"

# 2. Rebuild
echo ""
echo "--- Step 2: Build ---"
cd "${BUILD_DIR}"
cmake "${ARTIFACT_DIR}" \
    -DCMAKE_BUILD_TYPE=Debug \
    -DCMAKE_PREFIX_PATH="${PREFIX}" \
    -DNURAFT_LIBRARY="${PREFIX}/lib/libnuraft.a" \
    -DLE\VELDB_LIBRARY=/usr/lib/x86_64-linux-gnu/libleveldb.so \
    -DLUA_LIBRARY="${PREFIX}/lib/liblua.a" \
    -DJSON_LIBRARY="${PREFIX}/lib/libjsoncpp.a" \
    -DCURL_LIBRARY="${PREFIX}/lib/libcurl.a" \
    -DMHD_LIBRARY="${PREFIX}/lib/libmicrohttpd.a" \
    -DSECP256K1_LIBRARY="${PREFIX}/lib/libsecp256k1.a" \
    -DGTEST_LIBRARY=/usr/local/lib/libgtest.a \
    -DGTEST_MAIN_LIBRARY=/usr/local/lib/libgtest_main.a \
    -DKECCAK_LIBRARY="${PREFIX}/lib/libkeccak.a" \
    -DEVMC_INSTRUCTIONS_LIBRARY="${PREFIX}/lib/libevmc-instructions.a" \
    -DEVMONE_LIBRARY="${PREFIX}/lib/libevmone.a" \
    2>&1 | tail -3
echo "Building..."
make -j$(nproc) run_integration_tests 2>&1 | tail -5

# 3. Clean old traces and run test scenarios
echo ""
echo "--- Step 3: Run trace scenarios ---"
cd "${ARTIFACT_DIR}/tests/integration"

mkdir -p traces "${TRACES_DIR}"
rm -f traces/*.ndjson

echo "Running: normal_transaction..."
timeout 120 "${BUILD_DIR}/tests/integration/run_integration_tests" \
    --gtest_filter="normal_tx_test.*" 2>&1 | grep -E "^\[       OK |^\[  PASSED |^\[  FAILED" || echo "WARN: normal_transaction timed out or failed"

echo "Running: duplicate_transaction..."
timeout 120 "${BUILD_DIR}/tests/integration/run_integration_tests" \
    --gtest_filter="duplicate_tx_test.*" 2>&1 | grep -E "^\[       OK |^\[  PASSED |^\[  FAILED" || echo "WARN: duplicate_transaction timed out or failed"

echo "Running: double_spend_transaction..."
timeout 120 "${BUILD_DIR}/tests/integration/run_integration_tests" \
    --gtest_filter="double_spend_tx_test.*" 2>&1 | grep -E "^\[       OK |^\[  PASSED |^\[  FAILED" || echo "WARN: double_spend_transaction timed out or failed"

# 4. Collect traces
echo ""
echo "--- Step 4: Collect traces ---"
cp traces/*.ndjson "${TRACES_DIR}/" 2>/dev/null || echo "No trace files to copy"

# 5. Report
echo ""
echo "--- Step 5: Trace summary ---"
for f in "${TRACES_DIR}"/*.ndjson; do
    if [ -f "$f" ]; then
        count=$(wc -l < "$f")
        events=$(python3 -c "import json; n=0; [None for l in open('$f') if json.loads(l).get('tag')=='trace' and (n:=n+1)]; print(n)" 2>/dev/null || echo "$count")
        echo "  $(basename "$f"): $count lines, ~$events trace events"
    fi
done

echo ""
echo "=== Run complete ==="
