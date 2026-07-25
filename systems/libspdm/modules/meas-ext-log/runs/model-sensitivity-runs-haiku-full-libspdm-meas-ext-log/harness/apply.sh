#!/bin/bash
# Apply instrumentation patches to the libspdm source code

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_DIR="${SCRIPT_DIR}/../artifact/libspdm"

if [ ! -d "$ARTIFACT_DIR" ]; then
    echo "Error: artifact directory not found at $ARTIFACT_DIR"
    exit 1
fi

echo "Applying instrumentation patches..."

# Copy trace module files to artifact
cp "$SCRIPT_DIR/src/tla_trace.h" "$ARTIFACT_DIR/harness/src/" 2>/dev/null || mkdir -p "$ARTIFACT_DIR/harness/src" && cp "$SCRIPT_DIR/src/tla_trace.h" "$ARTIFACT_DIR/harness/src/"
cp "$SCRIPT_DIR/src/tla_trace.c" "$ARTIFACT_DIR/harness/src/"

# Apply git patch to instrument the source code
cd "$ARTIFACT_DIR"

# Reset to clean state first (if not already clean)
if git status --porcelain | grep -q .; then
    echo "  Resetting artifact to clean state..."
    git checkout -- .
fi

echo "  Applying instrumentation patch..."
git apply "$SCRIPT_DIR/patches/instrumentation.patch" || {
    echo "Error: Failed to apply patch"
    exit 1
}

echo "Instrumentation applied successfully!"
