#!/bin/bash
# Phase 2.5: Trace Harness Generation - Run Script
#
# Orchestrates: patch application → compilation → test execution → trace collection

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}/.."
ARTIFACT_DIR="${PROJECT_ROOT}/artifact/libspdm"
TRACES_DIR="${PROJECT_ROOT}/traces"
SRC_DIR="${SCRIPT_DIR}/src"

echo "========================================"
echo "Phase 2.5: Trace Harness Generation"
echo "========================================"
echo "Project: libspdm-mut-auth-encap"
echo "Target:  SPDM Encapsulated Mutual Authentication"
echo ""

# Create traces directory
mkdir -p "${TRACES_DIR}"

echo "[Step 1] Applying instrumentation patches..."
if [ ! -f "${SCRIPT_DIR}/apply.sh" ]; then
    echo "[!] ERROR: apply.sh not found"
    exit 1
fi
bash "${SCRIPT_DIR}/apply.sh"

echo ""
echo "[Step 2] Compiling trace module and test harness..."

# Create a temporary build directory
BUILD_DIR=$(mktemp -d)
trap "rm -rf ${BUILD_DIR}" EXIT

# Compile trace module
echo "  Compiling trace module..."
cd "${BUILD_DIR}"
gcc -c \
    -I"${SRC_DIR}" \
    -lpthread \
    "${SRC_DIR}/libspdm_tla_trace.c" \
    -o libspdm_tla_trace.o

# Compile test scenario
echo "  Compiling test scenario..."
gcc -c \
    -I"${SRC_DIR}" \
    "${SRC_DIR}/test_encap_mutual_auth.c" \
    -o test_encap_mutual_auth.o

# Link everything together
echo "  Linking..."
gcc -o test_harness \
    libspdm_tla_trace.o \
    test_encap_mutual_auth.o \
    -lpthread

echo "[+] Build successful"
echo ""

echo "[Step 3] Running test scenarios..."
echo ""

# Run basic scenario
echo "  [Scenario 1] Successful mutual authentication flow..."
TRACE_FILE="${TRACES_DIR}/test_scenario_basic.ndjson"
timeout 10 "${BUILD_DIR}/test_harness" "${TRACE_FILE}" || true

# Check if trace was generated
if [ -f "${TRACE_FILE}" ]; then
    LINES=$(wc -l < "${TRACE_FILE}")
    echo "    Generated ${LINES} trace events"
else
    echo "    [!] No trace file generated"
fi

echo ""
echo "[Step 4] Verifying trace coverage..."

# Verify all required event types are present
declare -a REQUIRED_EVENTS=(
    "responder_get_encap_request_challenge"
    "requester_get_encap_response_challenge_auth"
    "process_encap_response_challenge_auth"
    "transition_to_authenticated"
)

echo ""
echo "Required event types:"
for event in "${REQUIRED_EVENTS[@]}"; do
    if grep -q "\"event\": \"${event}\"" "${TRACE_FILE}" 2>/dev/null; then
        echo "  [✓] ${event}"
    else
        echo "  [!] ${event} (MISSING)"
    fi
done

echo ""
echo "[Step 5] Trace Summary"
echo "========================================"

if [ -f "${TRACE_FILE}" ]; then
    echo "Trace file: ${TRACE_FILE}"
    TOTAL_LINES=$(wc -l < "${TRACE_FILE}")
    echo "Total events: ${TOTAL_LINES}"

    echo ""
    echo "Event distribution:"
    grep '"event":' "${TRACE_FILE}" | sed 's/.*"event": "\([^"]*\)".*/  \1/' | sort | uniq -c | sort -rn

    echo ""
    echo "Sample trace (first 5 lines):"
    head -5 "${TRACE_FILE}" | sed 's/^/  /'
else
    echo "[!] No trace files generated"
    exit 1
fi

echo ""
echo "[+] Harness generation complete"
echo "    Traces ready in: ${TRACES_DIR}/"
