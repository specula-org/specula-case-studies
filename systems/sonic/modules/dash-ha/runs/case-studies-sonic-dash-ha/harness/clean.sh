#!/bin/bash
# Remove TLA+ trace instrumentation from sonic-dash-ha artifact.
# Reverts all modifications via git checkout.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT_DIR="$(cd "$SCRIPT_DIR/../artifact/sonic-dash-ha" && pwd)"
HAMGRD_SRC="$ARTIFACT_DIR/crates/hamgrd/src"

echo "=== Cleaning TLA+ trace instrumentation ==="

# Remove copied trace module
if [ -f "$HAMGRD_SRC/tla_trace.rs" ]; then
    rm "$HAMGRD_SRC/tla_trace.rs"
    echo "  Removed tla_trace.rs"
fi

# Revert patched files
cd "$ARTIFACT_DIR"
git checkout -- crates/hamgrd/src/main.rs crates/hamgrd/src/actors/ha_scope.rs 2>/dev/null || true
echo "  Reverted main.rs and ha_scope.rs"

echo ""
echo "=== Instrumentation removed ==="
