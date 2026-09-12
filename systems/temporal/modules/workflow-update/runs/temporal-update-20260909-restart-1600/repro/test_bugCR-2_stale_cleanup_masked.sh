#!/usr/bin/env bash
set -euo pipefail

repo="${TEMPORAL_REPO:-/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-update-20260909-restart-1600/temporal-update/.specula-output/confirmation/CR-2/worktree}"
workdir="${CR2_WORKDIR:-/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-update-20260909-restart-1600/temporal-update/.specula-output/confirmation/CR-2}"
logdir="$workdir/repro-output"

mkdir -p "$repo/.gotmp" "$logdir"
cd "$repo"

echo "REPO_HEAD=$(git rev-parse HEAD)"
echo "REPRO_LEVELS=level1-public-api-with-admin-cache-loss;level2-reachable-timer-precondition"
echo "GOTMPDIR=$repo/.gotmp"

export GOTMPDIR="$repo/.gotmp"
export TMPDIR="$repo/.gotmp"

completion_log="$logdir/test_bugCR-2_completion.log"
timer_log="$logdir/test_bugCR-2_timer.log"

echo "RUN completion: timeout 10m go test -tags=test_dep ./tests -run TestWorkflowUpdateSuite/TestAnalysisStaleCompletionReplacementSticky -count=1 -v"
timeout 10m go test -tags=test_dep ./tests -run 'TestWorkflowUpdateSuite/TestAnalysisStaleCompletionReplacementSticky' -count=1 -v >"$completion_log" 2>&1
grep -E 'CONTROL:|OBSERVED:|RECOVERY:|--- PASS: TestWorkflowUpdateSuite/TestAnalysisStaleCompletionReplacementSticky|PASS$|^ok[[:space:]]+go.temporal.io/server/tests' "$completion_log"

echo "RUN timer: timeout 10m go test -tags=test_dep ./service/history -run TestAnalysisTimerReplacement -count=1 -v"
timeout 10m go test -tags=test_dep ./service/history -run 'TestAnalysisTimerReplacement' -count=1 -v >"$timer_log" 2>&1
grep -E 'OLD_EXECUTOR_ENTERED|REPLACEMENT_READY|OLD_EXECUTOR_RESULT|PREMATURE_TIMEOUT_EVENT|AFTER_OLD_TIMER|--- PASS: TestAnalysisTimerReplacement|PASS$|^ok[[:space:]]+go.temporal.io/server/service/history' "$timer_log"

echo "FULL_LOGS=$completion_log $timer_log"
