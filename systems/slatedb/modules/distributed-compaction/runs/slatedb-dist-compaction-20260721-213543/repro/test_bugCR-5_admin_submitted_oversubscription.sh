#!/usr/bin/env bash
set -euo pipefail

REPO="/home/ubuntu/Specula/runs/slatedb-dist-compaction-20260721-213543/slatedb-dist-compaction/.specula-output/confirmation/CR-5/worktree"

cd "$REPO"
export CARGO_TERM_COLOR=never
timeout 20m cargo test -p slatedb test_admin_submitted_jobs_can_exceed_global_max_concurrent_bound -- --nocapture
