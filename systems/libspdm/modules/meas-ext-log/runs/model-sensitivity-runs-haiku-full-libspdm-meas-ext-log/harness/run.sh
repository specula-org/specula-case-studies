#!/bin/bash
# Harness Generation: Apply instrumentation, build, and collect traces

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRACES_DIR="${SCRIPT_DIR}/../traces"
BUILD_DIR="${SCRIPT_DIR}/../.build_traces"

echo "=== MEL Protocol Trace Collection ==="
echo ""

# Step 1: Create output directory
mkdir -p "$TRACES_DIR"

# Step 2: Build the trace module and test scenarios
echo "Step 1: Building trace infrastructure..."
mkdir -p "$BUILD_DIR"

# Compile trace module
gcc -c -o "$BUILD_DIR/tla_trace.o" "$SCRIPT_DIR/src/tla_trace.c" -pthread -Wall
echo "  ✓ Compiled tla_trace.c"

# Compile test scenarios
gcc -c -o "$BUILD_DIR/test_scenarios.o" "$SCRIPT_DIR/src/test_mel_scenarios.c" -Wall
echo "  ✓ Compiled test_mel_scenarios.c"

# Link to create test executable
gcc -o "$BUILD_DIR/test_mel_scenarios" "$BUILD_DIR/tla_trace.o" "$BUILD_DIR/test_scenarios.o" -pthread -lm
echo "  ✓ Built test_mel_scenarios executable"

# Step 3: Run trace generation
echo ""
echo "Step 2: Generating traces..."
cd "$SCRIPT_DIR/.."
TRACES_DIR="$(cd "$TRACES_DIR" && pwd)" timeout 30 "$BUILD_DIR/test_mel_scenarios" 2>&1 | tee trace_generation.log
echo "  ✓ Traces generated"

# Step 4: Verify traces were created
echo ""
echo "Step 3: Verifying trace output..."
TRACE_COUNT=$(find "$TRACES_DIR" -name "*.ndjson" -type f | wc -l)

if [ "$TRACE_COUNT" -eq 0 ]; then
    echo "  ✗ Error: No trace files generated"
    exit 1
fi

echo "  ✓ Generated $TRACE_COUNT trace files"
echo ""

# Step 5: Report trace statistics
echo "Step 4: Trace Statistics"
echo "  ───────────────────────────"
for trace_file in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$trace_file" ]; then
        filename=$(basename "$trace_file")
        linecount=$(wc -l < "$trace_file")
        echo "  $filename: $linecount events"
    fi
done
echo ""

# Step 6: Verify trace format
echo "Step 5: Verifying trace format..."
INVALID_COUNT=0
for trace_file in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$trace_file" ]; then
        # Check if each line is valid JSON and contains "tag": "trace"
        while IFS= read -r line; do
            if ! echo "$line" | grep -q '"tag":"trace"'; then
                echo "  Warning: Line missing 'tag' in $trace_file"
                ((INVALID_COUNT++))
            fi
        done < "$trace_file"
    fi
done

if [ "$INVALID_COUNT" -eq 0 ]; then
    echo "  ✓ All traces have correct format"
else
    echo "  ⚠ Found $INVALID_COUNT format issues"
fi

echo ""
echo "=== Trace Collection Complete ==="
echo "Output: $TRACES_DIR/"
