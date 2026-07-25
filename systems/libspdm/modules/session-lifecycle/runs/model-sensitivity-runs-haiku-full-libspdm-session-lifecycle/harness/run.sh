#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ARTIFACT_DIR="$PROJECT_ROOT/artifact/libspdm"
BUILD_DIR="$SCRIPT_DIR/build"
TRACES_DIR="$PROJECT_ROOT/traces"

echo "=========================================="
echo "Phase 2.5: Trace Harness Generation"
echo "=========================================="
echo "Script directory: $SCRIPT_DIR"
echo "Project root: $PROJECT_ROOT"
echo "Artifact directory: $ARTIFACT_DIR"
echo "Build directory: $BUILD_DIR"
echo "Traces directory: $TRACES_DIR"

mkdir -p "$BUILD_DIR"
mkdir -p "$TRACES_DIR"

echo ""
echo "Step 1: Applying instrumentation patches..."
timeout 60 bash "$SCRIPT_DIR/apply.sh" "$ARTIFACT_DIR" || true

echo ""
echo "Step 2: Building harness..."
cd "$BUILD_DIR"
timeout 300 cmake "$SCRIPT_DIR" || {
    echo "CMake configuration failed"
    exit 1
}
timeout 300 make -j4 || {
    echo "Build failed"
    exit 1
}

echo ""
echo "Step 3: Running test scenarios..."
cd "$PROJECT_ROOT"

timeout 60 "$BUILD_DIR/test_session_lifecycle" || {
    echo "Test execution failed"
    exit 1
}

echo ""
echo "Step 4: Verifying traces..."
TRACE_FILE="$TRACES_DIR/session-lifecycle.ndjson"
if [ -f "$TRACE_FILE" ]; then
    LINE_COUNT=$(wc -l < "$TRACE_FILE")
    echo "✓ Trace file created: $TRACE_FILE"
    echo "✓ Events captured: $LINE_COUNT"

    if [ "$LINE_COUNT" -lt 20 ]; then
        echo "⚠ Warning: Expected at least 20 events, got $LINE_COUNT"
    fi
else
    echo "✗ Trace file not found: $TRACE_FILE"
    exit 1
fi

echo ""
echo "=========================================="
echo "Harness generation complete!"
echo "=========================================="
echo "Traces are ready for validation in:"
echo "  $TRACES_DIR/"
echo ""
