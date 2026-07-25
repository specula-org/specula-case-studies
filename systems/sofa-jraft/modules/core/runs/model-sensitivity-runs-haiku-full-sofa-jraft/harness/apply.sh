#!/bin/bash
# Apply instrumentation patches to sofa-jraft source code

set -e

ARTIFACT_DIR="/home/ubuntu/Specula/experiments/model-sensitivity/runs/haiku/full/sofa-jraft/artifact/sofa-jraft"
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Applying TLA+ instrumentation to sofa-jraft..."

# Copy test class to test directory
mkdir -p "$ARTIFACT_DIR/jraft-core/src/test/java/com/alipay/sofa/jraft/test"
cp "$HARNESS_DIR/src/RaftProtocolTest.java" "$ARTIFACT_DIR/jraft-core/src/test/java/com/alipay/sofa/jraft/test/"

# Verify TlaTrace was copied
if [ ! -f "$ARTIFACT_DIR/jraft-core/src/main/java/com/alipay/sofa/jraft/tla/TlaTrace.java" ]; then
    echo "Error: TlaTrace.java not found in artifact"
    exit 1
fi

echo "Instrumentation patches applied successfully"
echo "Note: Source code has been prepared for tracing"
echo "Trace output will be written to traces/*.ndjson"
