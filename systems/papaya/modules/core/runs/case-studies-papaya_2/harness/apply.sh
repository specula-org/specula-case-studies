#!/usr/bin/env bash
# Apply the round-2 trace harness to artifact/papaya.
#
# This is a copy-and-patch step: we replace `src/tla_trace.rs` and
# `tests/trace_tests.rs` with the round-2 versions, and apply a small diff
# to `src/raw/mod.rs` that adds the new round-2 instrumentation points.
#
# Idempotent: re-running this overwrites the previous instrumented copy.

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${HARNESS_DIR}/../.." && pwd)"
ARTIFACT="${ROOT_DIR}/artifact/papaya"

if [[ ! -d "${ARTIFACT}" ]]; then
    echo "error: artifact dir not found at ${ARTIFACT}" >&2
    exit 1
fi

echo "[apply] resetting artifact to clean round-1 baseline"
cd "${ARTIFACT}"
git checkout -- src/tla_trace.rs src/raw/mod.rs tests/trace_tests.rs 2>/dev/null || true

echo "[apply] copying round-2 trace module"
cp "${HARNESS_DIR}/src/tla_trace.rs" "${ARTIFACT}/src/tla_trace.rs"

echo "[apply] copying round-2 trace tests"
cp "${HARNESS_DIR}/src/trace_tests.rs" "${ARTIFACT}/tests/trace_tests.rs"

echo "[apply] applying round-2 instrumentation patch to src/raw/mod.rs"
cd "${ARTIFACT}"
git apply --reject "${HARNESS_DIR}/patches/round2_mod_rs.patch"

echo "[apply] verifying compilation"
cargo check --tests --lib 2>&1 | tail -3

echo "[apply] OK"
