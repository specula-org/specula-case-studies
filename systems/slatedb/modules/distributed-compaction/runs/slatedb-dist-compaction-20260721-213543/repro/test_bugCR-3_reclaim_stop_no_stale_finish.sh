#!/usr/bin/env bash
set -euo pipefail

REPO="/home/ubuntu/Specula/runs/slatedb-dist-compaction-20260721-213543/slatedb-dist-compaction/.specula-output/confirmation/CR-3/worktree"

cd "$REPO"

echo "LEVEL 1: real worker/executor reclaim -> stop -> same-worker re-claim harness"
timeout 10m cargo test -q test_reclaim_stop_does_not_allow_stale_finish_after_same_worker_reclaim --lib

echo
echo "LEVEL 1: executor cancellation suppresses stale completion after stop"
timeout 10m cargo test -q should_stop_single_compaction_job_without_stopping_executor --lib

echo
echo "LEVEL 0: no standalone public admin/CLI path in this tree to force this coordinator/worker reclaim race without a harness"
echo "LEVEL 2: not executed; would require injecting WorkerMessage::CompactionJobFinished after stop_compaction_job(), but the only real producer suppresses it once the task is removed"
echo "LEVEL 3: not executed; forcing a post-stop completion would alter core logic and violate the confirmation rules"
echo "FINAL: the real Level 1 runs passed, and no stale finish freed capacity for another claim"
