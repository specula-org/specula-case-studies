#!/bin/bash
# apply.sh — Ensure the instrumented libspdm sources are in place.
#
# The artifact/libspdm git repo was committed with the instrumentation
# already applied (Phase 2.5 standard workflow).  This script resets the
# working tree to the committed (instrumented) state, undoing any accidental
# edits made since commit time.
#
# Usage: bash harness/apply.sh  (from the experiment root directory)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT_DIR="$(cd "$SCRIPT_DIR/../artifact/libspdm" && pwd)"

echo "[apply] Resetting artifact/libspdm to instrumented baseline commit..."
git -C "$ARTIFACT_DIR" checkout -- .
echo "[apply] Done — instrumented sources are in place."
