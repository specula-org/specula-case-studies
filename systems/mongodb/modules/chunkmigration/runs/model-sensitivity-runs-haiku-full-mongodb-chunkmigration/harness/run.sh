#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS_DIR="$BASE_DIR/harness"
TRACES_DIR="$BASE_DIR/traces"

echo "=== MongoDB Chunk Migration Trace Collection ==="
echo "Base directory: $BASE_DIR"
echo "Harness directory: $HARNESS_DIR"
echo "Traces directory: $TRACES_DIR"

# Create traces directory if it doesn't exist
mkdir -p "$TRACES_DIR"

# Build the test harness
echo ""
echo "=== Compiling trace harness ==="
g++ -std=c++17 -O2 -Wall \
    "$HARNESS_DIR/src/tla_trace.cpp" \
    "$HARNESS_DIR/src/migration_test.cpp" \
    -o "$HARNESS_DIR/migration_test"

if [ ! -f "$HARNESS_DIR/migration_test" ]; then
    echo "ERROR: Failed to compile migration_test"
    exit 1
fi

echo "Compilation successful"

# Run the test scenarios
echo ""
echo "=== Running test scenarios ==="
cd "$BASE_DIR"
timeout 30 "$HARNESS_DIR/migration_test" "$TRACES_DIR/migration.ndjson" || {
    EXIT_CODE=$?
    if [ $EXIT_CODE -eq 124 ]; then
        echo "ERROR: Test harness timed out (hung)"
        exit 1
    fi
    exit $EXIT_CODE
}

# Verify traces were generated
echo ""
echo "=== Verifying trace output ==="
if [ ! -f "$TRACES_DIR/migration.ndjson" ]; then
    echo "ERROR: No trace file generated"
    exit 1
fi

TRACE_LINES=$(wc -l < "$TRACES_DIR/migration.ndjson")
echo "Trace file generated with $TRACE_LINES events"

if [ "$TRACE_LINES" -lt 20 ]; then
    echo "WARNING: Trace has fewer than 20 events (got $TRACE_LINES)"
fi

# Validate trace format
echo ""
echo "=== Validating trace format ==="
VALID=true
while IFS= read -r line; do
    if ! echo "$line" | jq . > /dev/null 2>&1; then
        echo "ERROR: Invalid JSON: $line"
        VALID=false
        break
    fi
    if ! echo "$line" | jq -e '.tag == "trace"' > /dev/null 2>&1; then
        echo "ERROR: Missing tag field: $line"
        VALID=false
        break
    fi
    if ! echo "$line" | jq -e '.type' > /dev/null 2>&1; then
        echo "ERROR: Missing type field: $line"
        VALID=false
        break
    fi
done < "$TRACES_DIR/migration.ndjson"

if [ "$VALID" = true ]; then
    echo "All trace events are valid JSON with correct structure"
else
    exit 1
fi

# List unique event types
echo ""
echo "=== Event types in trace ==="
jq -r '.type' "$TRACES_DIR/migration.ndjson" | sort | uniq -c | sort -rn

echo ""
echo "=== Trace collection complete ==="
exit 0
