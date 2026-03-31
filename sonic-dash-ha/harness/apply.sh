#!/bin/bash
# Apply TLA+ trace instrumentation to sonic-dash-ha hamgrd crate.
#
# Steps:
# 1. Copy tla_trace.rs into crates/hamgrd/src/
# 2. Apply instrumentation patch to main.rs and ha_scope.rs
#
# Idempotent: safe to run multiple times.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT_DIR="$(cd "$SCRIPT_DIR/../artifact/sonic-dash-ha" && pwd)"
HAMGRD_SRC="$ARTIFACT_DIR/crates/hamgrd/src"

echo "=== Applying TLA+ trace instrumentation ==="
echo "Artifact: $ARTIFACT_DIR"
echo "Target:   $HAMGRD_SRC"
echo ""

# 1. Copy tla_trace.rs module
echo "[1/2] Copying tla_trace.rs..."
cp "$SCRIPT_DIR/src/tla_trace.rs" "$HAMGRD_SRC/tla_trace.rs"
echo "  Copied to $HAMGRD_SRC/tla_trace.rs"

# 2. Apply instrumentation patch
echo "[2/2] Applying instrumentation patch..."
cd "$ARTIFACT_DIR"
if git diff --quiet crates/hamgrd/src/main.rs crates/hamgrd/src/actors/ha_scope.rs 2>/dev/null; then
    # Files are clean, apply patch
    if git apply --check "$SCRIPT_DIR/patches/instrumentation.patch" 2>/dev/null; then
        git apply "$SCRIPT_DIR/patches/instrumentation.patch"
        echo "  Applied instrumentation patch"
    else
        echo "  Patch cannot apply cleanly. Attempting fuzzy apply..."
        git apply --3way "$SCRIPT_DIR/patches/instrumentation.patch" 2>/dev/null || \
            echo "  WARNING: Patch failed. Manual instrumentation may be needed."
    fi
else
    echo "  Files already modified (patch likely already applied)"
fi

echo ""
echo "=== Instrumentation applied ==="
echo ""
echo "To build: cd $ARTIFACT_DIR && cargo build -p hamgrd"
echo "To run with tracing: HA_TRACE_FILE=trace.ndjson cargo test -p hamgrd ..."
