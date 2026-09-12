#!/usr/bin/env bash
set -euo pipefail

SRC="/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/confirmation/CR-2/worktree"
WORK="/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/confirmation/CR-2"
LOGDIR="$WORK/repro-logs"
GOTMPDIR="$WORK/.gobuildtmp"
GOCACHE="$WORK/.gocache"

mkdir -p "$LOGDIR" "$GOTMPDIR" "$GOCACHE"

cd "$SRC"
echo "source_head=$(git rev-parse HEAD)"

run_go_test() {
  local name="$1"
  local pattern="$2"
  local log="$LOGDIR/${name}.log"

  echo "run=${name}"
  set +e
  timeout 20m env GOTMPDIR="$GOTMPDIR" GOCACHE="$GOCACHE" \
    go test -tags=test_dep ./tests -run "$pattern" -count=1 -parallel 1 -v \
    >"$log" 2>&1
  local status=$?
  set -e

  echo "status=${status} log=${log}"
  rg -n "=== RUN|--- PASS|--- FAIL|checkpoint=|firstResponse=|base-deleted-reset-readable|PASS|FAIL|ok[[:space:]]+go.temporal.io/server/tests" "$log" || true
  return "$status"
}

run_go_test \
  "level0_missing_current_public_reset" \
  "TestResetWorkflowTestSuite/TestResetWorkflowByRunID_CurrentExecutionMissing"

run_go_test \
  "level2_missing_current_create_rejected_then_retry" \
  "TestWorkflowResetTestSuite/TestAnalysisMissingCurrentRecovery"

RECOVERY_LOG="$LOGDIR/level2_missing_current_create_rejected_then_retry.log"
rg -q "scenario=create-rejected checkpoint=base-written" "$RECOVERY_LOG"
rg -q "scenario=create-rejected checkpoint=recovered" "$RECOVERY_LOG"
rg -q "scenario=create-rejected checkpoint=base-deleted-reset-readable" "$RECOVERY_LOG"
rg -q "scenario=competing-start checkpoint=start-committed" "$RECOVERY_LOG"
rg -q "scenario=competing-start checkpoint=recovered" "$RECOVERY_LOG"
rg -q "completedStatus=Completed" "$RECOVERY_LOG"

echo "conclusion=missing_current_split_state_recovered_after_retry"
