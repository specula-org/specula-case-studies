#!/usr/bin/env bash
# apply.sh — reset artifact to a clean state then apply instrumentation patch
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_DIR="$SCRIPT_DIR/../artifact/libspdm"
PATCH="$SCRIPT_DIR/patches/instrumentation.patch"

echo "[apply] Resetting artifact to clean state..."
cd "$ARTIFACT_DIR"
git checkout -- .
git clean -fd include/tla_trace.h unit_test/test_spdm_psk_trace/ 2>/dev/null || true
rm -f include/tla_trace.h
rm -rf unit_test/test_spdm_psk_trace/

echo "[apply] Applying instrumentation patch..."
git apply --whitespace=nowarn "$PATCH"

echo "[apply] Done. Files changed:"
git diff --name-only
git status --short | grep '?' || true
