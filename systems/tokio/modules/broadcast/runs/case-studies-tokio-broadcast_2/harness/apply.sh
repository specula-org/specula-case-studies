#!/usr/bin/env bash
# Apply trace instrumentation to the tokio artifact.
#
# This is idempotent: it first resets broadcast.rs and mod.rs to HEAD, then
# applies the instrumentation patch and copies the trace module + harness
# scenarios into place.

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_DIR="$(realpath "${HARNESS_DIR}/../../artifact/tokio")"

if [ ! -d "${ARTIFACT_DIR}" ]; then
    echo "error: artifact not found at ${ARTIFACT_DIR}" >&2
    exit 1
fi

echo "[apply] resetting broadcast.rs and sync/mod.rs to HEAD..."
git -C "${ARTIFACT_DIR}" checkout -- tokio/src/sync/broadcast.rs tokio/src/sync/mod.rs

echo "[apply] removing previous trace module + harness if present..."
rm -f "${ARTIFACT_DIR}/tokio/src/sync/tla_trace.rs"
rm -f "${ARTIFACT_DIR}/tokio/tests/tla_harness.rs"

echo "[apply] applying instrumentation patch..."
git -C "${ARTIFACT_DIR}" apply "${HARNESS_DIR}/patches/instrumentation.patch"

echo "[apply] copying trace module + harness..."
cp "${HARNESS_DIR}/src/tla_trace.rs" "${ARTIFACT_DIR}/tokio/src/sync/tla_trace.rs"
cp "${HARNESS_DIR}/src/tla_harness.rs" "${ARTIFACT_DIR}/tokio/tests/tla_harness.rs"

echo "[apply] done."
