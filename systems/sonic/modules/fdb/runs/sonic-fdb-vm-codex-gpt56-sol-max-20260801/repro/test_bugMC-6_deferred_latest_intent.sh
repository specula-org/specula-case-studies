#!/usr/bin/env bash
set -euo pipefail

repo="${MC6_REPO:-/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-6/worktree-2}"
jobs="${MC6_JOBS:-8}"
build_log="${TMPDIR:-/tmp}/test_bugMC-6_build.$$.log"

show_build_failure()
{
    status=$?
    if [[ $status -ne 0 ]]; then
        echo "build_failed status=$status log=$build_log"
        tail -n 200 "$build_log" || true
    fi
    exit "$status"
}

trap show_build_failure EXIT

if [[ ! -f "$repo/tests/mock_tests/Makefile" ]]; then
    (cd "$repo" && ./autogen.sh) >"$build_log" 2>&1
    (cd "$repo" && ./configure) >>"$build_log" 2>&1
fi

make -C "$repo/tests/mock_tests" -j"$jobs" tests >>"$build_log" 2>&1
trap - EXIT
echo "build_ok"
cd "$repo/tests/mock_tests"
exec ./tests \
    --gtest_color=no \
    --gtest_filter='VxlanFdbOrchP2mpTest.DeferredLatestIntentProgramsObsoleteEndpoint'
