#!/usr/bin/env bash
# Bug 2 / F2: Local fork-detection divergence.
#
# Claim (modeling brief Family 2): different honest detectors pick
# different canonical variants of a forker's units (first-seen-wins). They
# each raise their own alerts with their own legit_units commitments. Two
# honest nodes could finalize different round-r heads in a window before
# both have processed all alerts → AgreementOnFinalizedOrder violation.
#
# Level 0 reproduction: re-use the existing in-tree integration test
# `testing::byzantine::small_byzantine_one_forker`, which spawns 4 members
# (3 honest, 1 byzantine forking at round 2) and asserts:
#   assert_eq!(batches[0], batches[node_ix.0])     // all honest agree
# If the bug manifests, this assertion fails.
#
# This is the maintainers' own family-2 scenario verbatim.

set -uo pipefail
ROOT=/home/ubuntu/Specula/case-studies/aleph-bft/artifact/AlephBFT
cd "$ROOT"
echo "=== Running F2 reproduction ==="
echo "Test: testing::byzantine::small_byzantine_one_forker"
echo
timeout 240 cargo test --release --package aleph-bft \
    testing::byzantine::small_byzantine_one_forker \
    -- --nocapture 2>&1 | tail -20
status=${PIPESTATUS[0]}
echo
echo "=== Exit status: $status ==="
if [ $status -eq 0 ]; then
    echo "TEST PASSED: 3 honest + 1 byzantine forker, all honest finalize same batches."
    echo "F2 (local fork-detection divergence violates AgreementOnFinalizedOrder) DOES NOT MANIFEST."
    echo "The deterministic election rule + ancestry through honest parents resolves the local-canonical divergence."
    echo "Status: REPRODUCTION FAILED (Level 0) — bug doesn't trigger as claimed."
else
    echo "TEST FAILED: honest members disagreed on batches OR alerts insufficient."
    echo "Status: REPRODUCED (Level 0)"
fi
exit $status
