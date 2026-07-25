#!/usr/bin/env bash
# Apply TLA+ trace instrumentation patches to the MongoDB artifact.
#
# Usage: bash harness/apply.sh
# Must be run from the run root (parent of harness/).
#
# Strategy: copy-and-patch
#   1. Copy tla_trace_session.h into artifact/mongo-src/src/mongo/db/session/
#   2. Apply instrumentation.patch via git apply --3way
#
# To revert: git -C artifact/mongo-src checkout -- .
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_DIR="$(cd "${SCRIPT_DIR}/../artifact/mongo-src" && pwd)"
PATCHES_DIR="${SCRIPT_DIR}/patches"
SESSION_DIR="${ARTIFACT_DIR}/src/mongo/db/session"

echo "=== Applying TLA+ trace instrumentation ==="
echo "  artifact: ${ARTIFACT_DIR}"

# Step 1: Copy trace header into MongoDB session source directory
echo "  [1/2] Copying tla_trace_session.h to ${SESSION_DIR}/"
cp "${PATCHES_DIR}/tla_trace_session.h" "${SESSION_DIR}/tla_trace_session.h"

# Step 2: Apply the instrumentation diff
echo "  [2/2] Applying instrumentation.patch"
cd "${ARTIFACT_DIR}"
# --3way: fall back to 3-way merge if context doesn't match exactly
# --reject: continue with partial apply if some hunks fail
git apply --3way "${PATCHES_DIR}/instrumentation.patch" 2>&1 || {
    echo "  WARNING: git apply returned non-zero. Check for .rej files."
    echo "  Partial application may still be useful. Continuing..."
}

echo "=== Instrumentation applied ==="
echo "  Build MongoDB with: bazel build //src/mongo/db/session/... --//conditions:mongodb_tla_trace=true"
echo "  Or with CMake: cmake -DMONGODB_TLA_TRACE=ON ..."
