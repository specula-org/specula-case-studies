#!/bin/bash
# Apply instrumentation to async-raft artifact.
# Run from case-studies/async-raft/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT_DIR="$SCRIPT_DIR/../artifact/async-raft"
SRC_DIR="$ARTIFACT_DIR/async-raft/src"
TEST_DIR="$ARTIFACT_DIR/async-raft/tests"

echo "=== Applying async-raft instrumentation ==="

# Step 1: Revert artifact to clean state
echo "--- Reverting artifact to clean state..."
(cd "$ARTIFACT_DIR" && git checkout -- .)

# Step 2: Copy trace emission module
echo "--- Copying tla_trace.rs..."
cp "$SCRIPT_DIR/src/tla_trace.rs" "$SRC_DIR/tla_trace.rs"

# Step 3: Copy test scenario
echo "--- Copying test scenario..."
cp "$SCRIPT_DIR/src/tla_trace_scenario.rs" "$TEST_DIR/tla_trace_scenario.rs"

# Step 4: Apply source instrumentation patch
echo "--- Applying instrumentation patch..."
(cd "$ARTIFACT_DIR" && git apply "$SCRIPT_DIR/patches/instrumentation.patch")

echo "=== Instrumentation applied successfully ==="
