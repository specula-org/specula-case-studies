#!/bin/bash
set -e

# Main harness execution script
# This script applies instrumentation, builds, and runs tests to collect traces

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(cd "$(dirname "${SCRIPT_DIR}")" && pwd)"
HARNESS_DIR="${SCRIPT_DIR}"

echo "=========================================="
echo "libspdm-psk-exchange Trace Harness"
echo "=========================================="
echo "Working directory: ${WORK_DIR}"
echo "Harness directory: ${HARNESS_DIR}"

# Create traces directory
mkdir -p "${WORK_DIR}/traces"

# Step 1: Apply instrumentation
echo ""
echo "Step 1: Applying instrumentation patches..."
cd "${WORK_DIR}"
bash "${HARNESS_DIR}/apply.sh"

# Step 2: Build the trace module
echo ""
echo "Step 2: Building trace module..."
cd "${HARNESS_DIR}/src"

# Compile the trace module
gcc -c -fPIC -I. tla_trace.c -o tla_trace.o
echo "  Compiled tla_trace.c"

# Compile test programs
gcc -c test_psk_exchange.c -o test_psk_exchange.o
echo "  Compiled test_psk_exchange.c"

gcc -c test_scenarios.c -o test_scenarios.o
echo "  Compiled test_scenarios.c"

# Link test executables
gcc test_psk_exchange.o tla_trace.o -pthread -o test_psk_exchange
echo "  Linked test_psk_exchange executable"

gcc test_scenarios.o tla_trace.o -pthread -o test_scenarios
echo "  Linked test_scenarios executable"

# Step 3: Run tests with timeout
echo ""
echo "Step 3: Running test scenarios..."
cd "${WORK_DIR}"

# Test 1: Basic trace initialization test
echo "  Test 1: Basic trace initialization..."
timeout 10 "${HARNESS_DIR}/src/test_psk_exchange" "${WORK_DIR}/traces/test_init.ndjson" || true

# Test 2: Happy path scenario
echo "  Test 2: Happy path PSK exchange..."
timeout 10 "${HARNESS_DIR}/src/test_scenarios" happy_path "${WORK_DIR}/traces/scenario_happy_path.ndjson" || true

# Test 3: Opaque bounds validation scenario
echo "  Test 3: Opaque data bounds validation..."
timeout 10 "${HARNESS_DIR}/src/test_scenarios" bounds "${WORK_DIR}/traces/scenario_bounds.ndjson" || true

# Test 4: Session ID tracking scenario
echo "  Test 4: Session ID allocation tracking..."
timeout 10 "${HARNESS_DIR}/src/test_scenarios" session_ids "${WORK_DIR}/traces/scenario_session_ids.ndjson" || true

# Step 4: Verify traces were generated
echo ""
echo "Step 4: Verifying trace collection..."
TOTAL_TRACES=0
for trace_file in "${WORK_DIR}"/traces/*.ndjson; do
    if [ -f "$trace_file" ]; then
        FILENAME=$(basename "$trace_file")
        LINE_COUNT=$(wc -l < "$trace_file")
        echo "  ✓ ${FILENAME}: ${LINE_COUNT} events"
        TOTAL_TRACES=$((TOTAL_TRACES + LINE_COUNT))
    fi
done

if [ $TOTAL_TRACES -gt 0 ]; then
    echo ""
    echo "Summary: Generated ${TOTAL_TRACES} total trace events across all scenarios"
    echo ""
    echo "Sample trace (first event from happy_path scenario):"
    if [ -f "${WORK_DIR}/traces/scenario_happy_path.ndjson" ]; then
        head -1 "${WORK_DIR}/traces/scenario_happy_path.ndjson" | jq . 2>/dev/null | sed 's/^/    /' || head -1 "${WORK_DIR}/traces/scenario_happy_path.ndjson" | sed 's/^/    /'
    fi
else
    echo "  ⚠ No traces generated"
fi

echo ""
echo "=========================================="
echo "Harness execution completed"
echo "=========================================="
