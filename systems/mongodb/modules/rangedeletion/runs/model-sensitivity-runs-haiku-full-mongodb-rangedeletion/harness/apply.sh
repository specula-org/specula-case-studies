#!/bin/bash
# Apply instrumentation patches to the MongoDB range deletion service
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_DIR="${SCRIPT_DIR}/../artifact"

echo "Applying instrumentation patches..."

# Copy trace header to artifact if not already there
if [ ! -f "${ARTIFACT_DIR}/mongo-src/src/mongo/db/s/tla_trace.h" ]; then
    cp "${SCRIPT_DIR}/src/tla_trace.h" "${ARTIFACT_DIR}/mongo-src/src/mongo/db/s/"
    echo "✓ Copied trace header"
fi

# The instrumentation is already applied to the artifact in place
# If we need to revert, use clean.sh

echo "✓ Instrumentation applied successfully"
