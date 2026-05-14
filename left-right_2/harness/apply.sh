#!/usr/bin/env bash
# Apply trace instrumentation to the left-right artifact via direct file copy.
#
# The artifact's .git points to a different worktree, so we cannot reliably
# use git apply / git checkout.  Instead we keep complete copies of every
# modified or new file under harness/src/ and copy them in place.
#
# Layout:
#   harness/src/lib.rs           -> artifact/src/lib.rs           (instrumented)
#   harness/src/read.rs          -> artifact/src/read.rs          (instrumented)
#   harness/src/read/guard.rs    -> artifact/src/read/guard.rs    (instrumented)
#   harness/src/write.rs         -> artifact/src/write.rs         (instrumented)
#   harness/src/tla_trace.rs     -> artifact/src/tla_trace.rs     (new)
#   harness/src/trace_tests.rs   -> artifact/tests/trace_tests.rs (new)
#
# Idempotent: copies always succeed.

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_DIR="${HARNESS_DIR}/../../artifact/left-right"

if [[ ! -d "${ARTIFACT_DIR}" ]]; then
  echo "Error: ARTIFACT_DIR not found at ${ARTIFACT_DIR}" >&2
  exit 1
fi

echo "[apply] Copying instrumented files to artifact..."
cp "${HARNESS_DIR}/src/lib.rs"        "${ARTIFACT_DIR}/src/lib.rs"
cp "${HARNESS_DIR}/src/read.rs"       "${ARTIFACT_DIR}/src/read.rs"
mkdir -p "${ARTIFACT_DIR}/src/read"
cp "${HARNESS_DIR}/src/read/guard.rs" "${ARTIFACT_DIR}/src/read/guard.rs"
cp "${HARNESS_DIR}/src/write.rs"      "${ARTIFACT_DIR}/src/write.rs"
cp "${HARNESS_DIR}/src/tla_trace.rs"  "${ARTIFACT_DIR}/src/tla_trace.rs"
mkdir -p "${ARTIFACT_DIR}/tests"
cp "${HARNESS_DIR}/src/trace_tests.rs" "${ARTIFACT_DIR}/tests/trace_tests.rs"

echo "[apply] Done."
