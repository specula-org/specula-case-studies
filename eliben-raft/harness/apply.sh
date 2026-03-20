#!/usr/bin/env bash
# Apply trace instrumentation to the eliben/raft artifact.
# Run from: case-studies/eliben-raft/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT="$CASE_DIR/artifact/raft"
RAFT_PKG="$ARTIFACT/part3/raft"

echo "=== Applying trace instrumentation ==="

# 1. Clean artifact to known state
echo "  Resetting artifact..."
git -C "$ARTIFACT" checkout -- .

# 2. Copy trace module and test scenarios into the raft package
echo "  Copying trace module..."
cp "$SCRIPT_DIR/src/tla_trace.go" "$RAFT_PKG/"
cp "$SCRIPT_DIR/src/tla_trace_test.go" "$RAFT_PKG/"

# 3. Apply instrumentation patch
echo "  Applying instrumentation patch..."
git -C "$ARTIFACT" apply "$SCRIPT_DIR/patches/instrumentation.patch"

echo "=== Instrumentation applied ==="
