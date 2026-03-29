#!/bin/bash
# Apply crossbeam-skiplist TLA+ trace instrumentation.
# Usage: bash harness/apply.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT_DIR="$(cd "$SCRIPT_DIR/../artifact/crossbeam" && pwd)"
SKIPLIST_DIR="$ARTIFACT_DIR/crossbeam-skiplist"

echo "[apply] Reverting artifact to clean state..."
(cd "$ARTIFACT_DIR" && git checkout -- crossbeam-skiplist/)
rm -f "$SKIPLIST_DIR/src/tla_trace.rs"
rm -f "$SKIPLIST_DIR/tests/trace_tests.rs"

echo "[apply] Copying tla_trace.rs module..."
cp "$SCRIPT_DIR/src/tla_trace.rs" "$SKIPLIST_DIR/src/tla_trace.rs"

echo "[apply] Copying trace_tests.rs..."
cp "$SCRIPT_DIR/src/trace_tests.rs" "$SKIPLIST_DIR/tests/trace_tests.rs"

echo "[apply] Applying instrumentation patch..."
(cd "$ARTIFACT_DIR" && git apply "$SCRIPT_DIR/patches/instrumentation.patch")

echo "[apply] Done. Instrumented files:"
echo "  $SKIPLIST_DIR/src/tla_trace.rs (trace module)"
echo "  $SKIPLIST_DIR/tests/trace_tests.rs (test scenarios)"
echo "  + patch applied to: Cargo.toml, src/lib.rs, src/base.rs, src/map.rs"
