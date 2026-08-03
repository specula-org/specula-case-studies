#!/usr/bin/env bash
set -euo pipefail

mc1_binary="/users/Pial/Specula/runs/sonic-fdb-vm-codex-gpt56-sol-max-20260801/fdb/.specula-output/confirmation/MC-1/worktree/tests/mock_tests/tests"
mc1_runtime_root="/tmp/fdb-harness-bootstrap-test/root/usr"
mc1_gcov_dir="$(mktemp -d /tmp/bugMC1-relearn-gcov.XXXXXX)"

trap 'rm -r -- "${mc1_gcov_dir}"' EXIT

export LD_LIBRARY_PATH="${mc1_runtime_root}/lib/x86_64-linux-gnu:${mc1_runtime_root}/lib:/usr/local/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export FDB_SWSS_SHARE_DIR="${mc1_runtime_root}/share/swss"
export GCOV_PREFIX="${mc1_gcov_dir}"
export GCOV_PREFIX_STRIP=0

if [[ ! -x "${mc1_binary}" ]]; then
    echo "MC1_ERROR missing executable: ${mc1_binary}" >&2
    exit 1
fi

cd "$(dirname "${mc1_binary}")"

echo "MC1_REPRO level=0 interface=normal_notification_consumers timing=none"
timeout 120s "${mc1_binary}" \
    --gtest_color=no \
    --gtest_filter=FdbOrchTest.BugMc1PostFlushRelearnDelayedAck
