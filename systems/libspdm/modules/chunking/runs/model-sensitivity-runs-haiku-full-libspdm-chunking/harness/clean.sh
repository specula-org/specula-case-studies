#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_DIR="${SCRIPT_DIR}/../artifact/libspdm"
BUILD_DIR="${SCRIPT_DIR}/build"

echo "=== Cleaning instrumentation ==="

# Remove trace module files from artifact
echo "Removing trace module files..."
rm -f "${ARTIFACT_DIR}/library/spdm_responder_lib/tla_trace.h"
rm -f "${ARTIFACT_DIR}/library/spdm_responder_lib/tla_trace.c"

# Remove build directory
echo "Removing build directory..."
rm -rf "${BUILD_DIR}"

# Revert changes to instrumented files (if using git)
if [ -d "${ARTIFACT_DIR}/.git" ]; then
    echo "Reverting instrumented source files..."
    cd "${ARTIFACT_DIR}"
    git checkout -- library/spdm_responder_lib/libspdm_rsp_chunk_send_ack.c || true
    git checkout -- library/spdm_responder_lib/libspdm_rsp_receive_send.c || true
    cd - > /dev/null
fi

echo "=== Clean complete ==="
exit 0
