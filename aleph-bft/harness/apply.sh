#!/usr/bin/env bash
# Apply trace instrumentation to the AlephBFT artifact.
#
# Idempotent: running this on a clean checkout is fine; running it on an
# already-instrumented tree first reverts via `git checkout` and then
# re-applies the patch.

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_DIR="${HARNESS_DIR}/../../artifact/AlephBFT"
CONSENSUS_SRC="${ARTIFACT_DIR}/consensus/src"
TESTING_SRC="${CONSENSUS_SRC}/testing"

if [[ ! -d "${ARTIFACT_DIR}" ]]; then
  echo "error: artifact directory not found at ${ARTIFACT_DIR}" >&2
  exit 1
fi

echo "[apply] reverting any prior instrumentation in artifact"
(cd "${ARTIFACT_DIR}" && git checkout -- consensus/src 2>/dev/null || true)
(cd "${ARTIFACT_DIR}" && rm -f consensus/src/tla_trace.rs consensus/src/testing/trace_scenario.rs)

echo "[apply] copying trace module + scenario into artifact"
mkdir -p "${TESTING_SRC}"
cp "${HARNESS_DIR}/src/tla_trace.rs" "${CONSENSUS_SRC}/tla_trace.rs"
cp "${HARNESS_DIR}/src/trace_scenario.rs" "${TESTING_SRC}/trace_scenario.rs"

echo "[apply] applying instrumentation patch"
(cd "${ARTIFACT_DIR}" && git apply --whitespace=nowarn "${HARNESS_DIR}/patches/instrumentation.patch")

echo "[apply] done"
