#!/bin/bash
# Apply TLA+ trace instrumentation to nuraft artifact.
# Usage: cd case-studies/nuraft && bash harness/apply.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT_DIR="$SCRIPT_DIR/../artifact/nuraft"

echo "=== Applying nuraft trace instrumentation ==="

# 1. Reset artifact to clean state
echo "Resetting artifact..."
git -C "$ARTIFACT_DIR" checkout -- .

# 2. Copy trace module header
echo "Copying tla_trace.hxx..."
cp "$SCRIPT_DIR/src/tla_trace.hxx" "$ARTIFACT_DIR/src/tla_trace.hxx"

# 3. Copy test file
echo "Copying test_trace.cxx..."
cp -f "$SCRIPT_DIR/src/tla_trace.hxx" "$ARTIFACT_DIR/src/"
# test_trace.cxx is created by the patch, but we also keep a standalone copy
if [ -f "$SCRIPT_DIR/src/test_basic_consensus.cxx" ]; then
    cp "$SCRIPT_DIR/src/test_basic_consensus.cxx" "$ARTIFACT_DIR/tests/unit/test_trace.cxx"
fi

# 4. Apply instrumentation patch (modifies source files + CMakeLists)
echo "Applying instrumentation patch..."
cd "$ARTIFACT_DIR"
git apply "$SCRIPT_DIR/patches/instrumentation.patch"

# 5. Apply new file patches if test file not already present
if [ ! -f "$ARTIFACT_DIR/tests/unit/test_trace.cxx" ]; then
    echo "Applying test_trace patch..."
    git apply "$SCRIPT_DIR/patches/test_trace.patch" || true
fi

echo "=== Instrumentation applied successfully ==="
echo "Build with: cmake -DNURAFT_TLA_TRACE=ON -DDISABLE_SSL=1"
