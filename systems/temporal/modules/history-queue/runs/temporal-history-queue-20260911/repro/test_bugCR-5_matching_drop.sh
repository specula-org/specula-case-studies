#!/usr/bin/env bash
set -euo pipefail

REPO="/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-history-queue-20260911/temporal-history-queue/.specula-output/confirmation/CR-5/worktree"

cd "$REPO"
echo "repo_rev=$(git rev-parse HEAD)"
echo "command=timeout 10m go test ./service/matching -run 'TestMatchingEngine_Classic_Suite/TestPoll(Activity|Workflow)TaskQueues_(InternalError|DataLossError)$' -count=1 -v"
timeout 10m go test ./service/matching -run 'TestMatchingEngine_Classic_Suite/TestPoll(Activity|Workflow)TaskQueues_(InternalError|DataLossError)$' -count=1 -v
