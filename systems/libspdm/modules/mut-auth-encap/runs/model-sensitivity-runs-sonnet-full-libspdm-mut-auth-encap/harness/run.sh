#!/usr/bin/env bash
# run.sh — full pipeline: apply instrumentation, build, run, collect traces.
#
# Usage:
#   harness/run.sh [CRYPTO] [DEVICE]
#
# Defaults: CRYPTO=mbedtls  DEVICE=sample
#
# Outputs:
#   traces/trace_basic_cert.ndjson
#   traces/trace_basic_pk.ndjson
#   traces/trace_encap_error.ndjson
#   traces/trace_encap_not_ready.ndjson

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${SCRIPT_DIR}/.."
ARTIFACT="${ROOT}/artifact/libspdm"
BUILD_DIR="${ROOT}/build"
TRACES_DIR="${ROOT}/traces"
CRYPTO="${1:-mbedtls}"
DEVICE="${2:-sample}"

echo "=== [1/4] Applying instrumentation ==="
bash "${SCRIPT_DIR}/apply.sh"

echo "=== [2/4] CMake configure ==="
mkdir -p "${BUILD_DIR}"
cmake -S "${ARTIFACT}" -B "${BUILD_DIR}" \
    -DARCH=x64 \
    -DTOOLCHAIN=GCC \
    -DTARGET=Debug \
    -DCRYPTO="${CRYPTO}" \
    -DDEVICE="${DEVICE}" \
    -DLIBSPDM_TRACE_ENCAP=1 \
    -DCMAKE_C_FLAGS="-DLIBSPDM_TRACE_ENCAP" \
    -DLIBSPDM_ENABLE_CAPABILITY_MUT_AUTH_CAP=1 \
    -DLIBSPDM_ENABLE_CAPABILITY_ENCAP_CAP=1 \
    -DLIBSPDM_SEND_CHALLENGE_SUPPORT=1

# Append subdirectory to unit_test CMakeLists if not already present
UNIT_TEST_CMAKE="${ARTIFACT}/unit_test/CMakeLists.txt"
if ! grep -q "test_spdm_tla_trace" "${UNIT_TEST_CMAKE}" 2>/dev/null; then
    echo 'add_subdirectory(test_spdm_tla_trace)' >> "${UNIT_TEST_CMAKE}"
    echo "[run] Added test_spdm_tla_trace to ${UNIT_TEST_CMAKE}"
fi

echo "=== [3/4] Build ==="
cmake --build "${BUILD_DIR}" --target tla_encap_test -j"$(nproc)"

# Find the binary
BIN=$(find "${BUILD_DIR}" -name "tla_encap_test" -type f | head -1)
if [[ -z "${BIN}" ]]; then
    echo "ERROR: tla_encap_test binary not found in ${BUILD_DIR}" >&2
    exit 1
fi
echo "[run] Binary: ${BIN}"

echo "=== [4/4] Collecting traces ==="
mkdir -p "${TRACES_DIR}"
# Must run from sample_key/ so that libspdm_read_requester_public_certificate_chain
# can resolve relative paths like "rsa2048/bundle_requester.certchain.der".
SAMPLE_KEY_DIR="${ARTIFACT}/unit_test/sample_key"
(cd "${SAMPLE_KEY_DIR}" && "${BIN}" "${TRACES_DIR}")

echo ""
echo "=== Trace summary ==="
for f in "${TRACES_DIR}"/*.ndjson; do
    count=$(wc -l < "${f}")
    echo "  ${f##*/}: ${count} events"
done
echo ""
echo "Traces written to ${TRACES_DIR}/"
