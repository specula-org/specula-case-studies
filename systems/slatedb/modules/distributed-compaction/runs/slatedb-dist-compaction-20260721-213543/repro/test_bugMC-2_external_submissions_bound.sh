#!/usr/bin/env bash
set -euo pipefail

cd /home/ubuntu/Specula/runs/slatedb-dist-compaction-20260721-213543/slatedb-dist-compaction/.specula-output/confirmation/MC-2/worktree
RUST_LOG=error timeout 10m cargo test -p slatedb compactor::tests::test_external_submissions_can_exceed_global_max_concurrent_bound --lib -- --exact --nocapture
