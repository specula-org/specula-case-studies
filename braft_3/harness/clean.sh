#!/usr/bin/env bash
# Revert the braft_3 artifact tree to its clean upstream state.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_DIR="${HARNESS_DIR}/../../artifact/braft"

cd "${ARTIFACT_DIR}"
git checkout -- . >/dev/null 2>&1 || true
rm -f src/braft/trace_logger.h \
      src/braft/trace_logger.cpp \
      test/test_bug_repro.cpp \
      test/test_trace_smoke.cpp
rm -rf bld
echo ">> Reverted ${ARTIFACT_DIR}"
