#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_DIR="/home/ubuntu/2pc/opencbdc-tx"
PATCHED="${SCRIPT_DIR}/patched_sources"
SRC="${SCRIPT_DIR}/src"

echo "=== Specula: Applying instrumentation to opencbdc-tx ==="

# 1. Copy trace module into artifact
echo "[1/6] Copying trace module..."
cp "${SRC}/tla_trace.hpp" "${ARTIFACT_DIR}/src/util/common/tla_trace.hpp"
cp "${SRC}/tla_trace.cpp" "${ARTIFACT_DIR}/src/util/common/tla_trace.cpp"

# 2. Add tla_trace.cpp to util/common CMakeLists
echo "[2/6] Adding tla_trace.cpp to util/common CMakeLists..."
if ! grep -q "tla_trace.cpp" "${ARTIFACT_DIR}/src/util/common/CMakeLists.txt"; then
    sed -i 's/random_source.cpp/random_source.cpp\n                         tla_trace.cpp/' \
        "${ARTIFACT_DIR}/src/util/common/CMakeLists.txt"
fi

# 3. Copy patched source files
echo "[3/6] Copying patched source files..."
cp "${PATCHED}/src/uhs/twophase/coordinator/controller.cpp" \
    "${ARTIFACT_DIR}/src/uhs/twophase/coordinator/controller.cpp"
cp "${PATCHED}/src/uhs/twophase/locking_shard/controller.cpp" \
    "${ARTIFACT_DIR}/src/uhs/twophase/locking_shard/controller.cpp"
cp "${PATCHED}/src/uhs/twophase/locking_shard/locking_shard.cpp" \
    "${ARTIFACT_DIR}/src/uhs/twophase/locking_shard/locking_shard.cpp"
cp "${PATCHED}/src/uhs/twophase/locking_shard/locking_shard.hpp" \
    "${ARTIFACT_DIR}/src/uhs/twophase/locking_shard/locking_shard.hpp"
cp "${PATCHED}/src/uhs/twophase/locking_shard/state_machine.cpp" \
    "${ARTIFACT_DIR}/src/uhs/twophase/locking_shard/state_machine.cpp"
cp "${PATCHED}/src/uhs/twophase/locking_shard/state_machine.hpp" \
    "${ARTIFACT_DIR}/src/uhs/twophase/locking_shard/state_machine.hpp"
cp "${PATCHED}/src/uhs/twophase/sentinel_2pc/controller.cpp" \
    "${ARTIFACT_DIR}/src/uhs/twophase/sentinel_2pc/controller.cpp"

# 4. Copy trace test
echo "[4/6] Copying trace test..."
cp "${SRC}/trace_test.cpp" "${ARTIFACT_DIR}/tests/integration/trace_test.cpp"

# 5. Add trace_test.cpp to integration tests CMakeLists
echo "[5/6] Adding trace_test.cpp to integration tests CMakeLists..."
if ! grep -q "trace_test.cpp" "${ARTIFACT_DIR}/tests/integration/CMakeLists.txt"; then
    sed -i 's/watchtower_integration_test.cpp/watchtower_integration_test.cpp\n                                      trace_test.cpp/' \
        "${ARTIFACT_DIR}/tests/integration/CMakeLists.txt"
fi

echo "[6/6] Creating traces output directory..."
mkdir -p "${SCRIPT_DIR}/../traces"

echo "=== Apply complete ==="
