#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="/home/ubuntu/Specula/runs/slatedb-dist-compaction-20260721-213543/slatedb-dist-compaction/.specula-output/confirmation/MC-1/worktree"

cd "$REPO_ROOT"

cargo test -p slatedb test_conflicting_external_submitted_compaction_reaches_scheduled_and_panics_worker --test bug_mc_1_conflicting_external_submissions -- --nocapture
