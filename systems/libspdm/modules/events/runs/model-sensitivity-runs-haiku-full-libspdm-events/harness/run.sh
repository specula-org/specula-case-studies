#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_DIR="${SCRIPT_DIR}/../artifact/libspdm"
TRACES_DIR="${SCRIPT_DIR}/../traces"
HARNESS_DIR="${SCRIPT_DIR}"

# Ensure traces directory exists
mkdir -p "${TRACES_DIR}"

# Step 1: Apply instrumentation
echo "=== Step 1: Applying instrumentation ==="
bash "${SCRIPT_DIR}/apply.sh"

# Step 2: Copy trace header to the locations where it's included
echo "=== Step 2: Preparing trace headers ==="
cp "${SCRIPT_DIR}/src/tla_trace.h" "${ARTIFACT_DIR}/library/spdm_responder_lib/"
cp "${SCRIPT_DIR}/src/tla_trace.h" "${ARTIFACT_DIR}/library/spdm_requester_lib/"
mkdir -p "${ARTIFACT_DIR}/include"
cp "${SCRIPT_DIR}/src/tla_trace.h" "${ARTIFACT_DIR}/include/"

# Step 3: Compile the simple test scenario
echo "=== Step 3: Compiling test scenario ==="
cd "${TRACES_DIR}"
gcc -I"${SCRIPT_DIR}/src" -pthread "${SCRIPT_DIR}/src/test_events.c" -o test_events

# Step 4: Run test scenario - simple baseline trace
echo "=== Step 4: Running test scenarios ==="
timeout 30 ./test_events "${TRACES_DIR}/trace_baseline.ndjson" || true

# Step 5: Verify traces were generated
echo "=== Step 5: Verifying traces ==="
if [ -f "${TRACES_DIR}/trace_baseline.ndjson" ]; then
    echo "✓ Trace file generated"
    TRACE_LINES=$(wc -l < "${TRACES_DIR}/trace_baseline.ndjson")
    echo "  Lines in trace: ${TRACE_LINES}"
    echo "  First few events:"
    head -3 "${TRACES_DIR}/trace_baseline.ndjson" | sed 's/^/    /'
else
    echo "✗ No trace file generated!"
    exit 1
fi

echo ""
echo "=== Harness execution completed ==="
echo "Traces are available in: ${TRACES_DIR}"
