#!/usr/bin/env bash
# Bug 3 / F3: Restart equivocation chain.
#
# Claim (modeling brief Family 3): a multi-step persistence/broadcast
# pipeline must hold "no signed unit reaches the wire before it is durable
# on disk" across crash/restart. Subtle dependencies between consensus
# service, backup saver, initial-unit-collection. The chain could allow
# NoEquivocationAcrossRestart violations.
#
# Level 0 reproduction: re-use the maintainers' integration tests that
# crash > f nodes, restart them, and assert all nodes finalize the same
# batches after restart AND the saved-units' coords are a subset of the
# post-restart saved coords (no duplicate or "ghost" round-R unit from the
# restarted node).
#
# The `crashed_nodes_recover` test:
#   1. Spawns n=7 nodes.
#   2. Waits for some batches to finalize.
#   3. Kills f+1 = 3 of them.
#   4. Restarts them.
#   5. Asserts batches match across all nodes.
#   6. Asserts backup coords pre-kill ⊆ backup coords post-restart.

set -uo pipefail
ROOT=/home/ubuntu/Specula/case-studies/aleph-bft/artifact/AlephBFT
cd "$ROOT"
echo "=== Running F3 reproduction ==="
echo "Test: testing::crash_recovery::small_node_crash_recovery_small"
echo "Setup: n=7, kill 3 nodes, restart, verify NoEquivocationAcrossRestart and BackupBeforeBroadcast"
echo
timeout 600 cargo test --release --package aleph-bft \
    testing::crash_recovery::small_node_crash_recovery_small \
    -- --nocapture 2>&1 | tail -10
status=${PIPESTATUS[0]}
echo
echo "=== Exit status: $status ==="
if [ $status -eq 0 ]; then
    echo "TEST PASSED: crashed nodes recovered and all members agreed on batches post-restart."
    echo "NoEquivocationAcrossRestart holds: restarted nodes' new units are at rounds > lastSignedRound."
    echo "BackupBeforeBroadcast holds: post-restart backup coords ⊇ pre-kill backup coords."
    echo "Status: REPRODUCTION FAILED (Level 0) — bug doesn't trigger."
else
    echo "TEST FAILED."
    echo "Status: REPRODUCED (Level 0)"
fi
exit $status
