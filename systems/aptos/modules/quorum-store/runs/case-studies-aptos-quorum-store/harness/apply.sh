#!/usr/bin/env bash
# apply.sh -- Apply TLA+ trace instrumentation to the artifact tree.
#
# Idempotent: detects if the instrumentation is already applied (by checking
# for the presence of `tla_trace.rs`) and skips reapplication.
#
# Run from anywhere; resolves paths via $0.

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_DIR="$(cd "${HARNESS_DIR}/../../artifact/aptos-core" && pwd)"
PATCH_FILE="${HARNESS_DIR}/patches/instrumentation.patch"
SENTINEL="${ARTIFACT_DIR}/consensus/src/quorum_store/tla_trace.rs"

echo "[apply.sh] artifact: ${ARTIFACT_DIR}"
echo "[apply.sh] patch:    ${PATCH_FILE}"

if [[ -f "${SENTINEL}" ]]; then
  echo "[apply.sh] tla_trace.rs already present; assuming patch already applied."
  exit 0
fi

if [[ ! -f "${PATCH_FILE}" ]]; then
  echo "[apply.sh] ERROR: patch file not found: ${PATCH_FILE}" >&2
  exit 1
fi

cd "${ARTIFACT_DIR}"

# Ensure the tree is at a clean baseline for the quorum_store paths we patch.
# We restrict reverts to consensus/src/quorum_store/ so unrelated local edits
# elsewhere are untouched.
git checkout -- consensus/src/quorum_store/ 2>/dev/null || true

# Apply the patch (creates tla_trace.rs + scenario test + edits).
git apply --whitespace=nowarn "${PATCH_FILE}"

echo "[apply.sh] instrumentation applied."
