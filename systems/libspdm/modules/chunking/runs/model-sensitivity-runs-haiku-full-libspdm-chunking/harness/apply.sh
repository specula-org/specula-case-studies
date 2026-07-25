#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_DIR="${SCRIPT_DIR}/../artifact/libspdm"
TRACES_DIR="${SCRIPT_DIR}/../traces"
BUILD_DIR="${SCRIPT_DIR}/build"

echo "=== Applying instrumentation patches ==="

# Copy trace module files to artifact
echo "Copying trace module to artifact..."
cp "${SCRIPT_DIR}/src/tla_trace.h" "${ARTIFACT_DIR}/library/spdm_responder_lib/"
cp "${SCRIPT_DIR}/src/tla_trace.c" "${ARTIFACT_DIR}/library/spdm_responder_lib/"

# Create traces directory
mkdir -p "${TRACES_DIR}"

echo "=== Building test harness ==="

# Build test harness
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"
cmake .. || exit 1
make || exit 1
cd - > /dev/null

echo "=== Running test harness ==="

# Run test harness with timeout
timeout 60 "${BUILD_DIR}/test_chunking" "${TRACES_DIR}/trace.ndjson" || {
    STATUS=$?
    if [ $STATUS -eq 124 ]; then
        echo "Error: Test harness timed out"
        exit 1
    fi
    exit $STATUS
}

echo "=== Trace generation complete ==="

# Verify trace file exists and has content
if [ ! -f "${TRACES_DIR}/trace.ndjson" ]; then
    echo "Error: Trace file not created"
    exit 1
fi

LINE_COUNT=$(wc -l < "${TRACES_DIR}/trace.ndjson")
echo "Generated trace with $LINE_COUNT events"

if [ $LINE_COUNT -lt 4 ]; then
    echo "Warning: Trace has fewer than 4 events"
fi

echo "=== Instrumentation and trace collection complete ==="
exit 0
