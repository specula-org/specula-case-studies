#!/usr/bin/env bash
# Reproduction for Bug 1 / MC-5: Dual-Hash Duplicate-Confirm Panic
#
# Status: KNOWN-HISTORICAL.  Upstream-accepted as deliberate behavior in
# anza-xyz/agave PR #2700 (commit 1444baa426, 2024-08-22).  The PR
# explicitly added the panic with `#[should_panic]` tests, which is the
# developers' acknowledgment that this is the intended halt-on-detected-
# Byzantine-equivocation response.
#
# What this reproduction does:
#   Runs two upstream-authored tests that target the exact assertion at
#   core/src/replay_stage.rs:2226-2230:
#     - test_mark_slots_duplicate_confirmed  (function path)
#     - test_process_duplicate_confirmed_slots::same_batch
#     - test_process_duplicate_confirmed_slots::seperate_batches
#                                              (channel-receiver path)
#
#   Both tests use `#[should_panic(expected = "Additional duplicate
#   confirmed notification for slot 6")]` — the panic firing is success.
#
# This matches the MC-5 counterexample
# (.specula-output/spec/output/MC_hunt_family4_sim3.out):
#   Byz injects DupConf(2, hA), then DupConf(2, hB); validator
#   processes both, hits assert_eq! at replay_stage.rs:2226-2230, panics.
#
# Usage: bash test_bug1_mc5_dup_confirm_panic.sh
set -euo pipefail

AGAVE_DIR="${AGAVE_DIR:-/home/ubuntu/Specula/case-studies/solana/artifact/agave}"
cd "$AGAVE_DIR"

echo "=== Bug 1 / MC-5 reproduction: dual-hash duplicate-confirm panic ==="
echo "Repository: $(pwd)"
echo "Branch: $(git rev-parse --abbrev-ref HEAD), HEAD: $(git rev-parse --short HEAD)"
echo
echo "--- Running upstream #[should_panic] tests ---"
echo "[1/2] test_mark_slots_duplicate_confirmed"
timeout 300 cargo test -p solana-core --lib test_mark_slots_duplicate_confirmed -- --nocapture 2>&1 | tail -10
echo
echo "[2/2] test_process_duplicate_confirmed_slots (both variants)"
timeout 300 cargo test -p solana-core --lib test_process_duplicate_confirmed_slots -- --nocapture 2>&1 | tail -10

echo
echo "--- Source of the assertion (the panic site) ---"
sed -n '2200,2235p' core/src/replay_stage.rs
echo
echo "--- The committing PR (deliberate developer-intent) ---"
git -C "$AGAVE_DIR" log --oneline 1444baa426 -1 -- core/src/replay_stage.rs
echo
echo 'PASS criterion: all three test variants report "should panic ... ok".'
echo "This confirms the implementation deliberately panics on detected dual-hash"
echo "duplicate-confirm; the panic is the documented Byzantine-detection response."
