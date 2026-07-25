#!/bin/bash
# Apply instrumentation to the redisraft artifact.
# Run from: case-studies/redisraft/

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT_DIR="$HARNESS_DIR/../artifact/redisraft"
RAFT_DIR="$ARTIFACT_DIR/deps/raft"

echo "=== Applying instrumentation ==="

# 1. Reset artifact to clean state
echo "  Resetting artifact..."
(cd "$ARTIFACT_DIR" && git checkout -- .)

# 2. Copy trace module into raft library source
echo "  Copying trace module..."
cp "$HARNESS_DIR/src/tla_trace.h" "$RAFT_DIR/include/"
cp "$HARNESS_DIR/src/tla_trace.c" "$RAFT_DIR/src/"

# 3. Apply instrumentation patch
echo "  Applying instrumentation patch..."
(cd "$ARTIFACT_DIR" && git apply "$HARNESS_DIR/patches/instrumentation.patch")

# 4. Copy test scenario into test directory
echo "  Copying test scenario..."
cp "$HARNESS_DIR/src/test_trace.c" "$RAFT_DIR/tests/"

echo "=== Instrumentation applied ==="
