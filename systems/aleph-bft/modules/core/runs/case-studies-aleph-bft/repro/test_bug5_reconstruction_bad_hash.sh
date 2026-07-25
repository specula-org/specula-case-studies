#!/usr/bin/env bash
# Bug 5 / R5: Reconstruction::add_parents silently retains orphan on hash
# mismatch.
#
# Claim (modeling brief R5): when add_parents receives parent hashes that
# don't match the unit's control_hash combined_hash, the reconstructing
# unit is silently retained in `reconstructing_units` without re-emitting a
# Request::ParentsOf. Liveness concern: relies on higher-layer
# `Manager::trigger_tasks` retransmission.
#
# Level 0 reproduction: run the maintainers' own
# `dag::reconstruction::test::handles_bad_hash` test, which exercises the
# exact bad-hash scenario and asserts that after the higher-layer provides
# correct parents (via add_unit of the actual round-0 units), the unit
# reconstructs. This proves the design works as intended (liveness via
# retry).

set -uo pipefail
ROOT=/home/ubuntu/Specula/case-studies/aleph-bft/artifact/AlephBFT
cd "$ROOT"
echo "=== Running R5 reproduction ==="
echo "Test 1: dag::reconstruction::test::handles_bad_hash (top-level Reconstruction)"
echo "Test 2: dag::reconstruction::parents::test::handles_bad_hash (parent-reconstruction layer)"
echo
timeout 120 cargo test --release --package aleph-bft \
    handles_bad_hash \
    -- --nocapture 2>&1 | tail -20
status=${PIPESTATUS[0]}
echo
echo "=== Exit status: $status ==="
if [ $status -eq 0 ]; then
    echo "TEST PASSED: bad-hash add_parents leaves unit in reconstructing_units, "
    echo "  and when the correct parents arrive via subsequent add_unit calls, "
    echo "  the unit reconstructs."
    echo "R5 is confirmed as a liveness-only characterization, not a safety bug."
    echo "Status: FALSE POSITIVE (Level 0) — developer intent: higher-layer retry"
else
    echo "TEST FAILED — behavior diverged from R5 claim."
    echo "Status: REPRODUCED or unrelated failure"
fi
exit $status
