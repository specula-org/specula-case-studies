#!/bin/bash
# Build and run sofa-jraft tests to collect TLA+ traces

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/../artifact/sofa-jraft" && pwd)"
TRACES_DIR="${SCRIPT_DIR}/../traces"

echo "========== SOFAJraft Trace Collection =========="
echo "Project: $PROJECT_DIR"
echo "Traces: $TRACES_DIR"

# Create traces directory
mkdir -p "$TRACES_DIR"

# Step 1: Apply instrumentation
echo ""
echo "[1/4] Applying instrumentation patches..."
bash "$SCRIPT_DIR/apply.sh"

# Step 2: Build the project
echo ""
echo "[2/4] Building sofa-jraft..."
cd "$PROJECT_DIR"

# Clean previous build if any
timeout 60 mvn clean -q -DskipTests=true 2>/dev/null || true

# Build with tests
timeout 300 mvn install -q -DskipTests=true \
  -Dmaven.javadoc.skip=true \
  -Dmaven.source.skip=true \
  2>&1 | tee /tmp/mvn-build.log || {
    tail -50 /tmp/mvn-build.log
    echo "Build failed - check logs above"
    exit 1
}

echo "Build successful"

# Step 3: Run test scenarios
echo ""
echo "[3/4] Running test scenarios..."

# Set trace output directory for tests
export TRACE_DIR="$TRACES_DIR"

# Run tests (with a timeout to prevent hangs)
timeout 180 mvn test -q \
  -Dtest=RaftProtocolTest \
  -Dtrace.dir="$TRACES_DIR" \
  -DfailIfNoTests=false \
  -Dmaven.javadoc.skip=true \
  2>&1 | tee /tmp/mvn-test.log || {
    echo "Warning: Some tests may have failed or timed out"
    tail -30 /tmp/mvn-test.log
}

# Step 4: Verify traces
echo ""
echo "[4/4] Verifying trace output..."

TRACE_COUNT=$(find "$TRACES_DIR" -name "*.ndjson" -type f | wc -l)
if [ $TRACE_COUNT -gt 0 ]; then
    echo "✓ Generated $TRACE_COUNT trace file(s)"

    # Show line counts for each trace
    echo ""
    echo "Trace statistics:"
    for trace in "$TRACES_DIR"/*.ndjson; do
        if [ -f "$trace" ]; then
            lines=$(wc -l < "$trace")
            size=$(du -h "$trace" | cut -f1)
            echo "  $(basename "$trace"): $lines events, $size"
        fi
    done
else
    echo "⚠ Warning: No trace files generated"
    echo "This may indicate that tests did not run or trace instrumentation was not successful"
fi

echo ""
echo "========== Trace Collection Complete =========="
echo "Traces are available in: $TRACES_DIR"
echo ""
echo "Next step: Run trace validation with:"
echo "  cd spec && tlc -config Trace.cfg"
