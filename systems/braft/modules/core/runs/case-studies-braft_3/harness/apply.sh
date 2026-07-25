#!/usr/bin/env bash
# Apply the braft_3 trace instrumentation to the artifact tree.
#
# Idempotent: clean the working tree first (git checkout / clean), then copy
# trace_logger source + test scenarios, then apply the patch.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_DIR="${HARNESS_DIR}/../../artifact/braft"

if [ ! -d "${ARTIFACT_DIR}" ]; then
    echo "ERROR: artifact not found at ${ARTIFACT_DIR}" >&2
    exit 1
fi

echo ">> Resetting artifact tree"
cd "${ARTIFACT_DIR}"
git checkout -- . >/dev/null 2>&1 || true
# Remove untracked files we previously installed.
rm -f src/braft/trace_logger.h \
      src/braft/trace_logger.cpp \
      test/test_bug_repro.cpp \
      test/test_trace_smoke.cpp

echo ">> Copying trace module + test scenarios"
cp "${HARNESS_DIR}/src/trace_logger.h"      src/braft/trace_logger.h
cp "${HARNESS_DIR}/src/trace_logger.cpp"    src/braft/trace_logger.cpp
cp "${HARNESS_DIR}/src/test_bug_repro.cpp"  test/test_bug_repro.cpp
cp "${HARNESS_DIR}/src/test_trace_smoke.cpp" test/test_trace_smoke.cpp

echo ">> Applying instrumentation.patch"
git apply --whitespace=nowarn "${HARNESS_DIR}/patches/instrumentation.patch"

echo ">> Instrumentation applied to ${ARTIFACT_DIR}"
