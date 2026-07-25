#!/bin/bash

# clean.sh - Clean instrumentation artifacts and traces

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT_DIR="$PROJECT_ROOT/artifact/libspdm"
TRACES_DIR="$PROJECT_ROOT/traces"

echo "Cleaning instrumentation artifacts..."

# Clean build artifacts
echo "  Cleaning harness build..."
cd "$SCRIPT_DIR"
make clean 2>/dev/null || true

# Revert any patches applied to artifact (if using git-patch approach)
# cd "$ARTIFACT_DIR"
# git checkout -- . 2>/dev/null || true

# Clean traces
echo "  Cleaning traces..."
rm -f "$TRACES_DIR"/*.ndjson

echo "✓ Cleanup complete"
