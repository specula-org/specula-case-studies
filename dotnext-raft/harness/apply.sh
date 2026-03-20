#!/bin/bash
# Apply instrumentation to dotNext artifact for TLA+ trace generation.
# Usage: bash harness/apply.sh
# Run from: case-studies/dotnext-raft/

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT="$CASE_DIR/artifact/dotNext"
SRC_RAFT="$ARTIFACT/src/cluster/DotNext.Net.Cluster/Net/Cluster/Consensus/Raft"
TEST_DIR="$ARTIFACT/src/DotNext.Tests/Net/Cluster/Consensus/Raft/Http"

echo "=== Applying instrumentation ==="

# 1. Revert any previous instrumentation
echo "  Reverting previous changes..."
git -C "$ARTIFACT" checkout -- . 2>/dev/null || true

# 2. Copy trace module into the project source
echo "  Copying TlaTrace.cs..."
mkdir -p "$SRC_RAFT/Tracing"
cp "$SCRIPT_DIR/src/TlaTrace.cs" "$SRC_RAFT/Tracing/TlaTrace.cs"

# 3. Apply instrumentation patch
echo "  Applying instrumentation patch..."
git -C "$ARTIFACT" apply "$SCRIPT_DIR/patches/instrumentation.patch"

# 4. Copy test scenario
echo "  Copying TlaTraceTests.cs..."
cp "$SCRIPT_DIR/src/TlaTraceTests.cs" "$TEST_DIR/TlaTraceTests.cs"

# 5. Exclude pre-existing broken test files that don't compile
#    (interface accessibility issues in dotNext tests, unrelated to our instrumentation)
echo "  Excluding broken pre-existing test files..."
for BROKEN_FILE in \
    "$ARTIFACT/src/DotNext.Tests/Net/Cluster/Consensus/Raft/TransportServices/TransportTestSuite.cs" \
    "$ARTIFACT/src/DotNext.Tests/Net/Cluster/Consensus/Raft/TransportServices/TcpTransportTests.cs" \
    "$ARTIFACT/src/DotNext.Tests/Net/Cluster/Consensus/Raft/CustomTransport/CustomTransportTests.cs" \
    "$ARTIFACT/src/DotNext.Tests/Net/Cluster/Consensus/Raft/LeaderStateContextTests.cs" \
    "$ARTIFACT/src/DotNext.Tests/Net/Cluster/Consensus/Raft/StateMachine/WriteAheadLogTests.cs" \
    "$ARTIFACT/src/DotNext.Tests/Threading/SingleProducerMultipleConsumersCoordinatorTests.cs" \
    "$ARTIFACT/src/DotNext.Tests/Threading/AsyncAutoResetEventSlimTests.cs"; do
    if [ -f "$BROKEN_FILE" ]; then
        mv "$BROKEN_FILE" "$BROKEN_FILE.bak"
    fi
done

# Exclude all TCP transport tests (multiple accessibility issues)
find "$ARTIFACT/src/DotNext.Tests/Net/Cluster/Consensus/Raft/Tcp" -name "*.cs" -exec sh -c 'mv "$1" "$1.bak"' _ {} \; 2>/dev/null || true

echo "=== Instrumentation applied ==="
echo "  Modified files:"
git -C "$ARTIFACT" status --short
