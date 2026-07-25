#!/bin/bash
set -euo pipefail

# MongoDB Session Catalog - Trace Generation Script
# This script builds and runs the trace harness

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$HARNESS_DIR")"
BUILD_DIR="$HARNESS_DIR/build"
TRACES_DIR="$PROJECT_ROOT/traces"
SRC_DIR="$HARNESS_DIR/src"

mkdir -p "$BUILD_DIR"
mkdir -p "$TRACES_DIR"

echo "=== MongoDB Session Catalog - Trace Harness ==="
echo "Project root: $PROJECT_ROOT"
echo "Build directory: $BUILD_DIR"
echo "Traces directory: $TRACES_DIR"
echo ""

# Step 1: Build the test harness
echo "[1/3] Building test harness..."
cd "$BUILD_DIR"

# Check if CMake is available
if ! command -v cmake &> /dev/null; then
    echo "ERROR: cmake not found. Please install cmake."
    exit 1
fi

# Configure and build
cmake "$SRC_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$BUILD_DIR/install"

make -j$(nproc)
echo "Build completed successfully."
echo ""

# Step 2: Run test scenarios
echo "[2/3] Running test scenarios..."

TEST_HARNESS="$BUILD_DIR/test_harness"

# Verify test harness was built
if [ ! -f "$TEST_HARNESS" ]; then
    echo "ERROR: test_harness executable not found at $TEST_HARNESS"
    exit 1
fi

# Clear old traces
rm -f "$TRACES_DIR"/*.ndjson

# Run scenarios
declare -a scenarios=("1" "2" "3" "4" "5")
declare -a scenario_names=(
    "Basic Checkout/Release"
    "Kill Workflow"
    "Parent-Child Reaping"
    "Concurrent Sessions"
    "Complex Interleaving"
)

for i in "${!scenarios[@]}"; do
    scenario="${scenarios[$i]}"
    scenario_name="${scenario_names[$i]}"
    trace_file="$TRACES_DIR/scenario_${scenario}.ndjson"

    echo "  Scenario $scenario: $scenario_name"
    timeout 30 "$TEST_HARNESS" "$trace_file" "$scenario" || {
        echo "ERROR: Scenario $scenario failed or timed out"
        exit 1
    }
    echo "    Generated: $trace_file"
done

echo "Test scenarios completed successfully."
echo ""

# Step 3: Verify traces
echo "[3/3] Verifying traces..."

for trace_file in "$TRACES_DIR"/*.ndjson; do
    if [ ! -f "$trace_file" ]; then
        continue
    fi

    filename=$(basename "$trace_file")
    line_count=$(wc -l < "$trace_file")

    # Verify each line is valid JSON
    valid_json=true
    while IFS= read -r line; do
        if ! echo "$line" | python3 -m json.tool > /dev/null 2>&1; then
            valid_json=false
            break
        fi
    done < "$trace_file"

    if [ "$valid_json" = true ]; then
        echo "  ✓ $filename: $line_count events (valid JSON)"
    else
        echo "  ✗ $filename: Invalid JSON detected"
        exit 1
    fi
done

echo ""
echo "=== Trace Generation Complete ==="
echo "Generated traces are in: $TRACES_DIR/"
echo "Next: Run Phase 3 validation with /validation-workflow skill"
