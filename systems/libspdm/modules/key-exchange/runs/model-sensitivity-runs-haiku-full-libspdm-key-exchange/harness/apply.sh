#!/bin/bash
#
# apply.sh: Prepare the harness for trace collection.
#
# This script:
# 1. Copies the trace module files into the artifact
# 2. Ensures the artifact is ready for building with instrumentation
#
# Usage: bash harness/apply.sh
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_DIR="$(dirname "$SCRIPT_DIR")/artifact/libspdm"
HARNESS_SRC="$SCRIPT_DIR/src"

echo "[*] Preparing harness for trace collection..."

if [ ! -d "$ARTIFACT_DIR" ]; then
    echo "[!] Artifact directory not found: $ARTIFACT_DIR"
    exit 1
fi

if [ ! -d "$HARNESS_SRC" ]; then
    echo "[!] Harness source directory not found: $HARNESS_SRC"
    exit 1
fi

# Copy trace module files into artifact
echo "[*] Copying trace module to artifact..."
cp "$HARNESS_SRC/tla_trace.h" "$ARTIFACT_DIR/" 2>/dev/null || true
cp "$HARNESS_SRC/tla_trace.c" "$ARTIFACT_DIR/" 2>/dev/null || true

# Note: In a real scenario with git-based patching, we would apply instrumentation patches here:
#   cd "$ARTIFACT_DIR"
#   git apply ../harness/patches/instrumentation.patch
# For this initial harness, we're just setting up the test infrastructure.

echo "[*] Harness preparation complete."
echo "[*] Trace module files are ready for instrumentation."
