#!/usr/bin/env bash
# apply.sh — copy instrumented files into the sofa-jraft artifact tree.
#
# Usage:
#   cd <this harness directory>
#   ./apply.sh [ARTIFACT_DIR]
#
# ARTIFACT_DIR defaults to ../artifact/sofa-jraft (relative to the harness dir).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_DIR="${1:-"$SCRIPT_DIR/../artifact/sofa-jraft"}"

if [ ! -d "$ARTIFACT_DIR" ]; then
    echo "ERROR: artifact directory not found: $ARTIFACT_DIR" >&2
    exit 1
fi

SRC="$SCRIPT_DIR/src"
MAIN="$ARTIFACT_DIR/jraft-core/src/main/java/com/alipay/sofa/jraft/core"
TEST="$ARTIFACT_DIR/jraft-core/src/test/java/com/alipay/sofa/jraft/core"

echo "[apply] Copying instrumented files to $ARTIFACT_DIR ..."

# Core sources (instrumented with TlaTrace calls)
cp "$SRC/TlaTrace.java"     "$MAIN/TlaTrace.java"
cp "$SRC/NodeImpl.java"     "$MAIN/NodeImpl.java"
cp "$SRC/FSMCallerImpl.java" "$MAIN/FSMCallerImpl.java"
cp "$SRC/Replicator.java"   "$MAIN/Replicator.java"

# Test scenarios
cp "$SRC/TlaTraceScenario1Test.java" "$TEST/TlaTraceScenario1Test.java"
cp "$SRC/TlaTraceScenario2Test.java" "$TEST/TlaTraceScenario2Test.java"

echo "[apply] Done."
