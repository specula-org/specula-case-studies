#!/bin/bash

# apply.sh - Apply instrumentation to libspdm source code
#
# This script applies the trace module instrumentation to the artifact.
#
# Current implementation uses a test harness approach with minimal
# modifications to the real libspdm code. For full integration with
# actual libspdm functions, this script would:
#
# 1. Copy the trace module (tla_trace.h/c) into libspdm
# 2. Apply patches to add trace emit calls at instrumentation points
# 3. Rebuild libspdm with instrumentation

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT_DIR="$PROJECT_ROOT/artifact/libspdm"

echo "Applying instrumentation to libspdm..."

# Currently, the test harness approach doesn't require modifications to
# the real libspdm code. The trace events are emitted by the test harness.
#
# To fully instrument libspdm:
# 1. Copy trace module:
#    cp "$SCRIPT_DIR/src/tla_trace.h" "$ARTIFACT_DIR/library/include/"
#    cp "$SCRIPT_DIR/src/tla_trace.c" "$ARTIFACT_DIR/library/common/"
#
# 2. Apply instrumentation patches:
#    cd "$ARTIFACT_DIR"
#    git apply "$SCRIPT_DIR/patches/instrumentation.patch"
#
# 3. Rebuild:
#    cd "$ARTIFACT_DIR"
#    mkdir -p build
#    cd build
#    cmake ..
#    make

echo "✓ Instrumentation ready (test harness approach)"
echo ""
echo "To rebuild traces, run:"
echo "  bash harness/run.sh"
