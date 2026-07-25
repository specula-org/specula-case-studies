#!/bin/bash
# Apply trace instrumentation to Aeron source code.
# Run from case-studies/aeron/ directory.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT_DIR="$SCRIPT_DIR/../artifact/aeron"
CLUSTER_SRC="$ARTIFACT_DIR/aeron-cluster/src/main/java/io/aeron/cluster"
CLUSTER_TEST="$ARTIFACT_DIR/aeron-cluster/src/test/java/io/aeron/cluster"

echo "=== Applying Aeron TLA+ trace instrumentation ==="

# 1. Reset any previous instrumentation
cd "$ARTIFACT_DIR"
git checkout -- aeron-cluster/src/main/java/io/aeron/cluster/Election.java
git checkout -- aeron-cluster/src/main/java/io/aeron/cluster/ConsensusModuleAgent.java
# Remove previous TlaTrace files if present
rm -f "$CLUSTER_SRC/TlaTrace.java"
rm -f "$CLUSTER_TEST/TlaTraceElectionTest.java"

# 2. Copy trace module into main source
cp "$SCRIPT_DIR/src/TlaTrace.java" "$CLUSTER_SRC/TlaTrace.java"
echo "  Copied TlaTrace.java → $CLUSTER_SRC/"

# 3. Copy test scenario into test source
cp "$SCRIPT_DIR/src/TlaTraceElectionTest.java" "$CLUSTER_TEST/TlaTraceElectionTest.java"
echo "  Copied TlaTraceElectionTest.java → $CLUSTER_TEST/"

# 4. Apply instrumentation patch
cd "$ARTIFACT_DIR"
git apply "$SCRIPT_DIR/patches/instrumentation.patch"
echo "  Applied instrumentation.patch"

echo "=== Instrumentation applied successfully ==="
