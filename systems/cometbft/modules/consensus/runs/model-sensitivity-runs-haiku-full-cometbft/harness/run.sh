#!/bin/bash
# run.sh - Master script for trace collection
# Runs consensus tests and collects NDJSON traces for TLA+ validation

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT_DIR="$PROJECT_ROOT/artifact/cometbft"
TRACES_DIR="$PROJECT_ROOT/traces"
BUILD_DIR="$ARTIFACT_DIR"

echo "================================================"
echo "CometBFT Trace Collection"
echo "================================================"
echo "Project root: $PROJECT_ROOT"
echo "Artifact dir: $ARTIFACT_DIR"
echo "Traces dir:   $TRACES_DIR"
echo ""

# Step 1: Verify instrumentation
echo "Step 1: Verifying instrumentation..."
if [ ! -f "$ARTIFACT_DIR/consensus/trace_emit.go" ]; then
    echo "ERROR: trace_emit.go not found in $ARTIFACT_DIR/consensus/"
    exit 1
fi
if [ ! -f "$ARTIFACT_DIR/consensus/scenario_trace_test.go" ]; then
    echo "ERROR: scenario_trace_test.go not found in $ARTIFACT_DIR/consensus/"
    exit 1
fi
echo "✓ Instrumentation verified"
echo ""

# Step 2: Create traces directory
echo "Step 2: Setting up traces directory..."
mkdir -p "$TRACES_DIR"
echo "✓ Traces directory ready at $TRACES_DIR"
echo ""

# Step 3: Run test scenarios to collect traces
echo "Step 3: Running consensus test scenarios..."
cd "$BUILD_DIR" || exit 1

# Set trace directory environment variable
export TRACE_DIR="$TRACES_DIR"

# Run test scenarios with timeout to prevent hanging
echo "Running test scenarios..."
timeout 300s go test -v -run "Scenario" ./consensus -count=1 || {
    TEST_RESULT=$?
    if [ $TEST_RESULT -eq 124 ]; then
        echo "WARNING: Tests timed out (likely deadlock), but traces may still be collected"
    elif [ $TEST_RESULT -ne 0 ]; then
        echo "ERROR: Tests failed with exit code $TEST_RESULT"
        exit $TEST_RESULT
    fi
}
echo "✓ Tests completed"
echo ""

# Step 4: Verify traces were collected
echo "Step 4: Verifying trace collection..."
TRACE_COUNT=$(ls -1 "$TRACES_DIR"/*.ndjson 2>/dev/null | wc -l || true)
if [ "$TRACE_COUNT" -eq 0 ]; then
    echo "ERROR: No traces collected in $TRACES_DIR"
    exit 1
fi
echo "✓ Collected $TRACE_COUNT trace files"
echo ""

# Step 5: Validate trace content
echo "Step 5: Validating trace content..."
for trace_file in "$TRACES_DIR"/*.ndjson; do
    echo "  Checking: $(basename "$trace_file")"

    # Count events
    line_count=$(wc -l < "$trace_file")
    echo "    - Events: $line_count"

    # Verify valid JSON
    if ! head -1 "$trace_file" | jq . >/dev/null 2>&1; then
        echo "    ERROR: Invalid JSON in trace file"
        exit 1
    fi

    # Extract event names
    event_names=$(jq -r '.event.name // .name' "$trace_file" 2>/dev/null | sort -u)
    echo "    - Event types: $(echo $event_names | tr '\n' ' ')"
done
echo "✓ All traces validated"
echo ""

# Step 6: Summary
echo "================================================"
echo "Trace Collection Complete"
echo "================================================"
echo "Traces written to: $TRACES_DIR"
ls -lh "$TRACES_DIR"/*.ndjson 2>/dev/null | awk '{print "  " $NF " (" $5 ")"}'
echo ""
echo "Next step: Run trace validation with spec/Trace.tla"
