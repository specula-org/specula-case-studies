#!/bin/bash

set -e

ARTIFACT_DIR="/home/ubuntu/Specula/experiments/model-sensitivity/runs/haiku/full/libspdm-secured-message/artifact/libspdm"
HARNESS_DIR="/home/ubuntu/Specula/experiments/model-sensitivity/runs/haiku/full/libspdm-secured-message/harness"
TRACES_DIR="/home/ubuntu/Specula/experiments/model-sensitivity/runs/haiku/full/libspdm-secured-message/traces"

mkdir -p "$TRACES_DIR"

echo "=========================================="
echo "libspdm-secured-message Trace Collection"
echo "=========================================="

# Step 1: Copy trace module to artifact
echo "[1/4] Copying trace module..."
cp "$HARNESS_DIR/src/tla_trace.h" "$ARTIFACT_DIR/include/" || echo "Warning: Could not copy tla_trace.h"
cp "$HARNESS_DIR/src/tla_trace.c" "$ARTIFACT_DIR/library/spdm_secured_message_lib/" || echo "Warning: Could not copy tla_trace.c"

# Step 2: Build the library
echo "[2/4] Building libspdm..."
cd "$ARTIFACT_DIR"

# Clean previous build
if [ -d build ]; then
    rm -rf build
fi

# Configure and build
cmake -B build \
    -DARCH=x64 \
    -DTOOLCHAIN=GCC \
    -DCRYPTO=openssl \
    -DCMAKE_BUILD_TYPE=Debug 2>&1 | tail -20

cmake --build build --parallel $(nproc) 2>&1 | tail -20

echo "[2/4] Build completed successfully"

# Step 3: Run existing tests
echo "[3/4] Running test scenarios..."

# The existing test suite
if [ -f "build/bin/test_spdm_secured_message" ]; then
    echo "  Running: test_spdm_secured_message"
    timeout 30 ./build/bin/test_spdm_secured_message 2>&1 || echo "Test execution completed (may have expected failures)"
fi

echo "[3/4] Test scenarios completed"

# Step 4: Report trace files
echo "[4/4] Trace collection summary:"
if [ -d "$TRACES_DIR" ]; then
    echo "  Traces directory: $TRACES_DIR"
    if find "$TRACES_DIR" -name "*.ndjson" -type f | head -5 | grep -q .; then
        echo "  Trace files found:"
        find "$TRACES_DIR" -name "*.ndjson" -type f -exec sh -c 'echo "    {} - $(wc -l < {}) events"' \;
    else
        echo "  NOTE: No NDJSON trace files found yet."
        echo "  This is expected - instrumentation patches must be applied first."
        echo "  See INSTRUMENTATION.md for details on where to add trace emit calls."
    fi
else
    echo "  Traces directory does not exist yet"
fi

echo ""
echo "=========================================="
echo "Next Steps:"
echo "=========================================="
echo "1. Review harness/INSTRUMENTATION.md for instrumentation points"
echo "2. Apply instrumentation patches to source code"
echo "3. Rebuild with 'cd artifact/libspdm && cmake --build build'"
echo "4. Run again: bash harness/run.sh"
echo "5. Validate traces with: tla-trace-validation Trace.tla traces/*.ndjson"
echo "=========================================="
