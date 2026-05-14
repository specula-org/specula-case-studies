#!/bin/bash
# Apply instrumentation to sonic-swss orchagent source files
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Navigate from harness/ -> .specula-output/ -> project root
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARTIFACT_DIR="$PROJECT_ROOT/case-studies/sonic-fdb/artifact/sonic-swss"

if [ ! -d "$ARTIFACT_DIR/orchagent" ]; then
    echo "ERROR: Cannot find artifact at $ARTIFACT_DIR"
    exit 1
fi

echo "=== Applying instrumentation patch ==="
cd "$ARTIFACT_DIR"

# Revert any previous instrumentation
git checkout -- orchagent/fdborch.cpp orchagent/portsorch.cpp orchagent/vxlanorch.cpp 2>/dev/null || true

# Apply the patch
git apply "$SCRIPT_DIR/patches/instrumentation.patch"

# Copy the trace header into the orchagent include path
cp "$SCRIPT_DIR/src/tla_trace.h" "$ARTIFACT_DIR/orchagent/tla_trace.h"

echo "=== Instrumentation applied ==="
echo "  Modified: orchagent/fdborch.cpp"
echo "  Modified: orchagent/portsorch.cpp"
echo "  Modified: orchagent/vxlanorch.cpp"
echo "  Added:    orchagent/tla_trace.h"
echo ""
echo "To build with instrumentation, add -DSONIC_FDB_TRACE to CXXFLAGS."
echo "To revert: cd $ARTIFACT_DIR && git checkout -- orchagent/"
