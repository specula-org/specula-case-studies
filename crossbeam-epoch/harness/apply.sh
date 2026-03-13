#!/usr/bin/env bash
# Apply crossbeam-epoch TLA+ trace instrumentation.
#
# Usage: cd case-studies/crossbeam-epoch && bash harness/apply.sh
#
# This script:
#   1. Reverts the artifact to a clean state
#   2. Copies the trace emission module into the crate
#   3. Copies the test scenario file as an integration test
#   4. Applies the instrumentation patch to internal.rs and lib.rs

set -euo pipefail

CASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACT_DIR="$CASE_DIR/artifact/crossbeam"
EPOCH_SRC="$ARTIFACT_DIR/crossbeam-epoch/src"
EPOCH_TESTS="$ARTIFACT_DIR/crossbeam-epoch/tests"
HARNESS_DIR="$CASE_DIR/harness"

echo "=== Applying crossbeam-epoch trace instrumentation ==="

# Step 1: Clean the artifact
echo "[1/4] Reverting artifact to clean state..."
(cd "$ARTIFACT_DIR" && git checkout -- .)

# Step 2: Copy trace emission module
echo "[2/4] Copying tla_trace.rs..."
cp "$HARNESS_DIR/src/tla_trace.rs" "$EPOCH_SRC/tla_trace.rs"

# Step 3: Copy test scenarios as an integration test
echo "[3/4] Copying test scenarios..."
cp "$HARNESS_DIR/src/test_scenarios.rs" "$EPOCH_TESTS/tla_trace_scenarios.rs"

# Step 4: Apply instrumentation patch
echo "[4/4] Applying instrumentation patch..."
(cd "$ARTIFACT_DIR" && git apply "$HARNESS_DIR/patches/instrumentation.patch")

echo "=== Instrumentation applied successfully ==="
