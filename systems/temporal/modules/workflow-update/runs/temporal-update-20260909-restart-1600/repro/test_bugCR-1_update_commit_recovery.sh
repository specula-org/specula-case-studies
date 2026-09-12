#!/usr/bin/env bash
set -euo pipefail

WORKTREE="/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-update-20260909-restart-1600/temporal-update/.specula-output/confirmation/CR-1/worktree"
REPRO_DIR="/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-update-20260909-restart-1600/temporal-update/.specula-output/repro"
cd "$WORKTREE"
mkdir -p "$WORKTREE/.tmp-cr1"
export TMPDIR="$WORKTREE/.tmp-cr1"

run_and_filter() {
  local name="$1"
  shift
  local log="$REPRO_DIR/${name}.log"
  local status=0
  "$@" >"$log" 2>&1 || status=$?
  echo "FULL_LOG=$log"
  grep -E '^(=== RUN|--- PASS|--- FAIL|PASS|FAIL|ok[[:space:]])|^[[:space:]]+.*(STALE_CACHE_RESULT|STATE_INJECTION_NOTE|CALLER_RECEIPT_LOST|RECOVERY_AFTER_LOST_RECEIPT|NONCOMMITTING_STORE_FAULT|FIRST_CALLER_CANCELLED|FIRST_COMPLETION_ROLLED_BACK|READBACK_AFTER_ROLLBACK|SECOND_UPDATE_COMMITTED|SAME_HOST_RECOVERY_MASK)' "$log" || true
  return "$status"
}

run_and_filter cr1_state_cache \
  go test -tags test_dep ./service/history/workflow -run TestBugCR1GetUpdateOutcomeAcceptsCachedEventForDifferentUpdateID -count=1 -v
run_and_filter cr1_public_controls \
  go test -tags test_dep ./cr1repro -run 'TestBugCR1(CommittedUpdateSurvivesLostCallerReceipt|OneHostNoncommittedCompletionDoesNotLeakToNextUpdate)$' -count=1 -v
