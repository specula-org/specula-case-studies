#!/usr/bin/env bash
set -euo pipefail

test_binary="/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-1/worktree/tests/mock_tests/tests"
runtime_root="/tmp/fdb-harness-bootstrap-test/root/usr"
gcov_dir="$(mktemp -d /tmp/bugMC1-gcov.XXXXXX)"

trap 'rm -rf -- "${gcov_dir}"' EXIT

export LD_LIBRARY_PATH="${runtime_root}/lib/x86_64-linux-gnu:${runtime_root}/lib:/usr/local/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export FDB_SWSS_SHARE_DIR="${runtime_root}/share/swss"
export GCOV_PREFIX="${gcov_dir}"
export GCOV_PREFIX_STRIP=10

if [[ ! -x "${test_binary}" ]]; then
    echo "MC1_ERROR missing executable: ${test_binary}" >&2
    exit 1
fi

cd "$(dirname "${test_binary}")"

echo "MC1_REPRO level=0 public_api_two_flushes timing=none"
env BUGMC1_LEVEL=0 timeout 120s "${test_binary}" \
    --gtest_color=no \
    --gtest_filter=FdbOrchTest.BugMc1OverlappingFlushPublicSequence

echo "MC1_REPRO level=1 public_api_two_flushes timing=delayed_callback"
env BUGMC1_LEVEL=1 timeout 120s "${test_binary}" \
    --gtest_color=no \
    --gtest_filter=FdbOrchTest.BugMc1OverlappingFlushPublicSequence

echo "MC1_REPRO level=2 injection=counterexample_state_11"
env BUGMC1_LEVEL=2 timeout 120s "${test_binary}" \
    --gtest_color=no \
    --gtest_filter=FdbOrchTest.BugMc1State11Injection

echo "MC1_REPRO level=3 public_api_two_flushes source_change=timing_only"
env BUGMC1_LEVEL=3 BUGMC1_LEVEL3_DELAY_US=20000 timeout 120s "${test_binary}" \
    --gtest_color=no \
    --gtest_filter=FdbOrchTest.BugMc1OverlappingFlushPublicSequence

echo "MC1_ESCALATION_COMPLETE invariant_mismatch=1 live_harm=0 real_consumer_wrong_outcome=none"
