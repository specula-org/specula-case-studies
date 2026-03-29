#!/bin/bash
# Apply TLA+ trace instrumentation to the kanal artifact.
# Copies tla_trace.rs module, applies the patch, and copies test scenarios.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT_DIR="$(cd "$SCRIPT_DIR/../artifact/kanal" && pwd)"

echo "[apply] Reverting artifact to clean state..."
(cd "$ARTIFACT_DIR" && git checkout -- .)
rm -f "$ARTIFACT_DIR/src/tla_trace.rs"
rm -f "$ARTIFACT_DIR/tests/trace_tests.rs"

echo "[apply] Copying tla_trace.rs module..."
cp "$SCRIPT_DIR/src/tla_trace.rs" "$ARTIFACT_DIR/src/tla_trace.rs"

echo "[apply] Applying instrumentation patch..."
(cd "$ARTIFACT_DIR" && git apply "$SCRIPT_DIR/patches/instrumentation.patch")

echo "[apply] Copying test scenarios..."
cp "$SCRIPT_DIR/src/trace_tests.rs" "$ARTIFACT_DIR/tests/trace_tests.rs"

echo "[apply] Done."
