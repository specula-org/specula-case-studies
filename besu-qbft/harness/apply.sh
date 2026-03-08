#!/bin/bash
# Apply instrumentation patches to the Besu QBFT source tree.
# Usage: ./apply.sh [besu_root]
#   besu_root: path to besu checkout (default: ../../artifact/besu)
set -e
cd "$(dirname "$0")"

BESU_ROOT="${1:-../artifact/besu}"
PATCHES="$(pwd)/patches"

echo "Applying instrumentation patches to $BESU_ROOT ..."
cd "$BESU_ROOT"

# 1. Instrumentation: TlaTracer.java (new) + modifications to 3 existing files
git apply "$PATCHES/instrumentation.patch"

# 2. Integration test: TlaTraceTest.java
git apply "$PATCHES/test.patch"

echo "Done. Patches applied successfully."
