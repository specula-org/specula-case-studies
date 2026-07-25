#!/bin/bash
# apply.sh - Applies instrumentation to CometBFT artifact code
# The instrumentation is already present in the artifact code, so this script
# verifies the instrumentation is in place.

set -e

ARTIFACT_DIR="${ARTIFACT_DIR:-.}/artifact/cometbft"

if [ ! -d "$ARTIFACT_DIR" ]; then
    echo "Error: artifact directory not found at $ARTIFACT_DIR"
    exit 1
fi

echo "Verifying trace infrastructure in $ARTIFACT_DIR..."

# Check that key instrumentation files exist
if [ ! -f "$ARTIFACT_DIR/consensus/trace_emit.go" ]; then
    echo "Error: trace_emit.go not found"
    exit 1
fi

if [ ! -f "$ARTIFACT_DIR/consensus/scenario_trace_test.go" ]; then
    echo "Error: scenario_trace_test.go not found"
    exit 1
fi

# Verify trace instrumentation points exist in state.go
TRACE_POINTS=$(grep -c "cs.traceLogger.Emit" "$ARTIFACT_DIR/consensus/state.go" || true)
if [ "$TRACE_POINTS" -lt 10 ]; then
    echo "Error: Expected at least 10 trace points in state.go, found $TRACE_POINTS"
    exit 1
fi

echo "✓ Trace infrastructure verified:"
echo "  - trace_emit.go: TraceLogger, TraceEvent, TraceStateSnap"
echo "  - scenario_trace_test.go: Test scenarios"
echo "  - state.go: $TRACE_POINTS instrumentation points"

# Create traces directory if it doesn't exist
TRACES_DIR="${TRACES_DIR:-.}/traces"
mkdir -p "$TRACES_DIR"
echo "✓ Traces directory ready: $TRACES_DIR"
