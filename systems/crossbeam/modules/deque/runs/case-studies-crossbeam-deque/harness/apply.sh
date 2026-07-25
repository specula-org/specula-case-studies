#!/bin/bash
# Apply instrumentation to the crossbeam-deque artifact.
# Copies tla_trace.rs module, trace test file, and applies the patch.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT_DIR="$(cd "$SCRIPT_DIR/../artifact/crossbeam/crossbeam-deque" && pwd)"

echo "[apply] Reverting artifact to clean state..."
(cd "$ARTIFACT_DIR" && git checkout -- .)
rm -f "$ARTIFACT_DIR/src/tla_trace.rs" "$ARTIFACT_DIR/tests/trace_tests.rs"

echo "[apply] Copying tla_trace.rs..."
cp "$SCRIPT_DIR/src/tla_trace.rs" "$ARTIFACT_DIR/src/tla_trace.rs"

echo "[apply] Copying trace_tests.rs..."
cp "$SCRIPT_DIR/src/trace_tests.rs" "$ARTIFACT_DIR/tests/trace_tests.rs"

echo "[apply] Applying instrumentation patch..."
(cd "$ARTIFACT_DIR/.." && git apply "$SCRIPT_DIR/patches/instrumentation.patch")

echo "[apply] Done."
