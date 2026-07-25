#!/bin/bash
# Apply instrumentation to the Ra artifact for TLA+ trace generation.
# Run from case-studies/ra/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_STUDY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT_DIR="$CASE_STUDY_DIR/artifact/ra"

echo "=== Applying Ra instrumentation ==="

# 1. Reset artifact to clean state
echo "Resetting artifact to clean state..."
git -C "$ARTIFACT_DIR" checkout -- .
git -C "$ARTIFACT_DIR" clean -f src/tla_trace.erl test/tla_trace_SUITE.erl 2>/dev/null || true

# 2. Copy trace module into artifact src/
echo "Copying tla_trace.erl to artifact src/..."
cp "$SCRIPT_DIR/src/tla_trace.erl" "$ARTIFACT_DIR/src/"

# 3. Copy test suite to artifact test/
echo "Copying tla_trace_SUITE.erl to artifact test/..."
cp "$SCRIPT_DIR/src/tla_trace_SUITE.erl" "$ARTIFACT_DIR/test/"

# 4. Apply instrumentation patch
echo "Applying instrumentation patch..."
cd "$ARTIFACT_DIR"
git apply "$SCRIPT_DIR/patches/instrumentation.patch"

echo "=== Instrumentation applied successfully ==="
