#!/bin/bash
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ARTIFACT_DIR="${SCRIPT_DIR}/../artifact/libspdm"
TRACES_DIR="${SCRIPT_DIR}/../traces"
HARNESS_DIR="${SCRIPT_DIR}"

echo "=== SPDM Harness: Apply, Build, Test, Collect Traces ==="
echo

# Create traces directory
mkdir -p "${TRACES_DIR}"

# Step 1: Apply instrumentation
echo "Step 1: Applying instrumentation patches..."
if [ -d "${ARTIFACT_DIR}/.git" ]; then
    cd "${ARTIFACT_DIR}"
    git checkout -- . 2>/dev/null || true
else
    echo "Warning: libspdm is not a git repository. Patches may not apply cleanly."
fi
bash "${HARNESS_DIR}/apply.sh" || exit 1
echo

# Step 2: Compile trace module and test harness
echo "Step 2: Compiling trace harness..."
cd "${TRACES_DIR}"
gcc -c -I"${HARNESS_DIR}/src" -fPIC -pthread \
    "${HARNESS_DIR}/src/tla_trace.c" -o tla_trace.o
gcc -c -I"${HARNESS_DIR}/src" -fPIC \
    "${HARNESS_DIR}/src/state_capture.c" -o state_capture.o
gcc -I"${HARNESS_DIR}/src" -pthread \
    "${HARNESS_DIR}/src/test_handshake.c" tla_trace.o state_capture.o \
    -o test_handshake
echo "✓ Compiled test_handshake"
echo

# Step 3: Run test scenarios
echo "Step 3: Running test scenarios..."
cd "${TRACES_DIR}"
timeout 30 ./test_handshake || {
    echo "Warning: Test execution failed or timed out"
}
echo

# Step 4: Verify traces were generated
echo "Step 4: Verifying trace generation..."
trace_count=0
for trace_file in "${TRACES_DIR}"/*.ndjson; do
    if [ -f "$trace_file" ]; then
        trace_count=$((trace_count + 1))
        line_count=$(wc -l < "$trace_file")
        echo "  ✓ $(basename "$trace_file"): $line_count events"
    fi
done

if [ $trace_count -eq 0 ]; then
    echo "  ✗ No trace files generated!"
    exit 1
else
    echo "  ✓ Generated $trace_count trace file(s)"
fi
echo

echo "=== Harness Complete ==="
echo "Traces saved to: $TRACES_DIR"
echo "Next: Run trace validation with TLC"
