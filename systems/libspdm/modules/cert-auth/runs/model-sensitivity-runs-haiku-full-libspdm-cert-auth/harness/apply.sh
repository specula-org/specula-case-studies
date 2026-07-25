#!/bin/bash
set -e

# Apply instrumentation patch to libspdm artifact
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT_DIR="$(dirname "$SCRIPT_DIR")/artifact/libspdm"

cd "$ARTIFACT_DIR"
git checkout -- . 2>/dev/null || true
git apply "$SCRIPT_DIR/patches/instrumentation.patch"
echo "Instrumentation patches applied successfully"
