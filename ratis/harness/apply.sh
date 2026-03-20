#!/usr/bin/env bash
# Apply TLA+ trace instrumentation to the ratis artifact.
# Run from case-studies/ratis/ directory.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT="$CASE_DIR/artifact/ratis"

echo "=== Applying instrumentation to ratis ==="

# 1. Revert any previous instrumentation
echo "  Reverting artifact to clean state..."
cd "$ARTIFACT"
git checkout -- . 2>/dev/null || true

# 2. Copy TlaTrace.java into the source tree
echo "  Copying TlaTrace.java..."
cp "$SCRIPT_DIR/src/TlaTrace.java" \
   "$ARTIFACT/ratis-server/src/main/java/org/apache/ratis/server/TlaTrace.java"

# 3. Copy test scenario
echo "  Copying TlaTraceTest.java..."
cp "$SCRIPT_DIR/src/TlaTraceTest.java" \
   "$ARTIFACT/ratis-server/src/test/java/org/apache/ratis/server/impl/TlaTraceTest.java"

# 4. Apply instrumentation patch
echo "  Applying instrumentation patch..."
cd "$ARTIFACT"
git apply "$SCRIPT_DIR/patches/instrumentation.patch"

echo "=== Instrumentation applied successfully ==="
