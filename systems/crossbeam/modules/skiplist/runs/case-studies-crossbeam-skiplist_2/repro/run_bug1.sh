#!/usr/bin/env bash
# Runner for Bug 1: Iterator Rewind After Exhaustion.
#
# Copies the test into the crossbeam-skiplist test directory, runs it, then
# removes it. Each test asserts FusedIterator semantics — it FAILS if the
# rewind bug is present (which it is, on this revision).

set -uo pipefail

REPRO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_DIR="$(cd "${REPRO_DIR}/../../artifact/crossbeam/crossbeam-skiplist" && pwd)"

TEST_FILE_SRC="${REPRO_DIR}/test_bug1_iter_rewind.rs"
TEST_FILE_DST="${ARTIFACT_DIR}/tests/test_bug1_iter_rewind.rs"
OUT="${REPRO_DIR}/test_bug1_iter_rewind.out"

cp "${TEST_FILE_SRC}" "${TEST_FILE_DST}"

(
    cd "${ARTIFACT_DIR}"
    timeout 120s cargo test --test test_bug1_iter_rewind > "${OUT}" 2>&1
    echo "exit=$?" >> "${OUT}"
)

rm -f "${TEST_FILE_DST}"

echo "Wrote ${OUT}"
tail -50 "${OUT}"
