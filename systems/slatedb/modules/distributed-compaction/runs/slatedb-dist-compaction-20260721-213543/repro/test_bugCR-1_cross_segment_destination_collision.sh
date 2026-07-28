#!/usr/bin/env bash
set -euo pipefail

REPO="/home/ubuntu/Specula/runs/slatedb-dist-compaction-20260721-213543/slatedb-dist-compaction/.specula-output/confirmation/CR-1/worktree"

cd "$REPO"
timeout 12m cargo test -p slatedb \
  test_external_submitted_cross_segment_destination_collision_is_scheduled_then_masked \
  -- --nocapture
