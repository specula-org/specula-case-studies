#!/usr/bin/env bash
# Bug 4 / F4: Deterministic-election ↔ asynchronous-delivery composition.
#
# Claim (modeling brief Family 4): under asynchrony, two honest nodes see
# the DAG grow in different orders. The deterministic election must produce
# the same head at every honest node given the same observable DAG. If the
# composition breaks, two honest nodes commit different heads at round r.
#
# Level 0 reproduction:
#   1. The maintainers' `small_byzantine_two_forkers` test (n=7, 5 honest,
#      2 byzantine forking simultaneously) — same agreement assertion as F2
#      but with more forkers, so the election must remain deterministic
#      under TWO concurrent forks.
#   2. Plus, the `unreliable` test family: arbitrary message reordering
#      under no Byzantine, asserting all honest agree on order. This is the
#      direct asynchronous-delivery family-4 scenario.

set -uo pipefail
ROOT=/home/ubuntu/Specula/case-studies/aleph-bft/artifact/AlephBFT
cd "$ROOT"
echo "=== Running F4 reproduction (two parallel tests) ==="

echo "--- Test 1: testing::byzantine::small_byzantine_two_forkers ---"
timeout 240 cargo test --release --package aleph-bft \
    testing::byzantine::small_byzantine_two_forkers \
    -- --nocapture 2>&1 | tail -8
s1=${PIPESTATUS[0]}

echo "--- Test 2: testing::unreliable ---"
# Lists all unreliable tests.
timeout 600 cargo test --release --package aleph-bft \
    testing::unreliable \
    -- --nocapture 2>&1 | tail -10
s2=${PIPESTATUS[0]}

if [ "$s1" -eq 0 ] && [ "$s2" -eq 0 ]; then
    status=0
else
    status=1
fi

echo
echo "=== Exit status: byzantine=$s1, unreliable=$s2 ==="
if [ $status -eq 0 ]; then
    echo "TESTS PASSED: deterministic election + async delivery + byzantine forking → all honest agree."
    echo "HeadElectionDeterminism and AgreementOnFinalizedOrder hold across all tested scenarios."
    echo "Status: REPRODUCTION FAILED (Level 0) — bug doesn't trigger."
else
    echo "TEST(S) FAILED."
    echo "Status: REPRODUCED (Level 0)"
fi
exit $status
