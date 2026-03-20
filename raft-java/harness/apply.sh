#!/usr/bin/env bash
# Apply instrumentation to raft-java artifact.
# Run from: case-studies/raft-java/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT="$CASE_DIR/artifact/raft-java"
CORE_SRC="$ARTIFACT/raft-java-core/src/main/java/com/github/wenweihu86/raft"
CORE_TEST="$ARTIFACT/raft-java-core/src/test/java/com/github/wenweihu86/raft"

echo "=== Applying raft-java instrumentation ==="

# 1. Revert any previous instrumentation
echo "[1/3] Reverting artifact to clean state..."
git -C "$ARTIFACT" checkout -- .

# 2. Copy harness source files into artifact
echo "[2/3] Copying TlaTrace.java and RaftTraceTest.java..."
cp "$SCRIPT_DIR/src/TlaTrace.java" "$CORE_SRC/TlaTrace.java"
mkdir -p "$CORE_TEST"
cp "$SCRIPT_DIR/src/RaftTraceTest.java" "$CORE_TEST/RaftTraceTest.java"

# 3. Apply instrumentation patch
echo "[3/3] Applying instrumentation patch..."
git -C "$ARTIFACT" apply "$SCRIPT_DIR/patches/instrumentation.patch"

echo "=== Instrumentation applied successfully ==="
