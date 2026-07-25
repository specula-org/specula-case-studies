#!/bin/bash
set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ARTIFACT_DIR="${SCRIPT_DIR}/../artifact/libspdm"

echo "Applying instrumentation patches..."

# Check if patch exists
if [ ! -f "${SCRIPT_DIR}/patches/instrument.patch" ]; then
    echo "Error: instrumentation patch not found at ${SCRIPT_DIR}/patches/instrument.patch"
    exit 1
fi

# Apply the patch
cd "${ARTIFACT_DIR}"
if git apply --check "${SCRIPT_DIR}/patches/instrument.patch" >/dev/null 2>&1; then
    git apply "${SCRIPT_DIR}/patches/instrument.patch"
    echo "✓ Patches applied successfully"
else
    echo "Warning: Patch check failed, attempting to apply anyway..."
    git apply "${SCRIPT_DIR}/patches/instrument.patch" || true
fi

# Copy harness source files into the artifact
echo "Copying harness files..."
mkdir -p "${ARTIFACT_DIR}/harness/src"
cp "${SCRIPT_DIR}/src/tla_trace.h" "${ARTIFACT_DIR}/harness/src/"
cp "${SCRIPT_DIR}/src/tla_trace.c" "${ARTIFACT_DIR}/harness/src/"
cp "${SCRIPT_DIR}/src/state_capture.h" "${ARTIFACT_DIR}/harness/src/"
cp "${SCRIPT_DIR}/src/state_capture.c" "${ARTIFACT_DIR}/harness/src/"
cp "${SCRIPT_DIR}/src/test_handshake.c" "${ARTIFACT_DIR}/harness/src/"

echo "✓ All files copied"
