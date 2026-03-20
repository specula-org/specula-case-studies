#!/bin/bash
# apply.sh — Apply instrumentation to the libomp artifact
#
# Usage: cd case-studies/libomp && bash harness/apply.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT="$CASE_DIR/artifact/llvm-project"
SRC="$ARTIFACT/openmp/runtime/src"

echo "=== Applying libomp trace instrumentation ==="

# 1. Reset artifact to clean state
echo "  [1/3] Cleaning artifact..."
git -C "$ARTIFACT" checkout -- openmp/ 2>/dev/null || true

# 2. Copy trace module files
echo "  [2/3] Copying trace module..."
cp "$SCRIPT_DIR/src/omp_trace.h" "$SRC/omp_trace.h"
cp "$SCRIPT_DIR/src/omp_trace.cpp" "$SRC/omp_trace.cpp"

# 3. Apply instrumentation patch
echo "  [3/3] Applying instrumentation patch..."
cd "$ARTIFACT"
git apply "$SCRIPT_DIR/patches/instrumentation.patch"

echo "=== Instrumentation applied successfully ==="
