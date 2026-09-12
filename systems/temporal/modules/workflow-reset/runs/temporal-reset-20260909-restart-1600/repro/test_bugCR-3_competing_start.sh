#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset"
WORKTREE="$ROOT/.specula-output/confirmation/CR-3/worktree"
BINARY="$ROOT/.specula-output/harness/build/reset-trace.test"
OUT_DIR="$ROOT/.specula-output/confirmation/CR-3/repro-logs"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
RAW_DIR="$OUT_DIR/raw-$RUN_ID"
LOG="$OUT_DIR/test_bugCR-3_competing_start-$RUN_ID.log"
RAW="$RAW_DIR/competing-start.jsonl"

mkdir -p "$RAW_DIR"
cd "$WORKTREE"

echo "CR-3 competing-start reset reproduction"
echo "worktree=$WORKTREE"
echo "git_head=$(git rev-parse HEAD)"
echo "git_dirty_count=$(git status --short | wc -l | tr -d ' ')"
echo "binary=$BINARY"
go version -m "$BINARY" | sed -n '1,8p'

set +e
RESET_TRACE_SCENARIO=competing-start RESET_TRACE_RAW_DIR="$RAW_DIR" \
  timeout 5m "$BINARY" \
  -test.run '^TestWorkflowResetTestSuite/TestTraceReset$' \
  -test.v -test.count=1 -test.timeout=4m \
  >"$LOG" 2>&1
rc=$?
set -e

echo "underlying_test_rc=$rc"
echo "underlying_log=$LOG"
echo "raw_trace=$RAW"

if [[ ! -s "$RAW" ]]; then
  echo "missing raw trace output" >&2
  tail -n 80 "$LOG" >&2 || true
  exit 1
fi

if [[ "$rc" -ne 0 ]] && ! rg -q 'unable to open database file|finalStatus=Completed' "$LOG"; then
  echo "underlying test failed before producing the CR-3 evidence" >&2
  tail -n 120 "$LOG" >&2 || true
  exit "$rc"
fi

jq -s -e '
  (any(.[]; .name == "InterleaveGate")) and
  (([.[] | select(.name == "ReceiveResetResponse" and .data.kind == "start")] | length) >= 2) and
  (any(.[]; .name == "ReceiveResetResponse" and .data.kind == "reset" and (.data.run | type == "string") and (.data.run | length > 0))) and
  (any(.[]; .name == "Checkpoint" and .data.name == "competing-start-ordered-replacement" and .data.competitor.State.execution_state.status == 5 and .data.result.State.execution_state.status == 1)) and
  (any(.[]; .name == "Checkpoint" and .data.name == "healthy-worker-completion" and .data.faults == 1 and .data.result.State.execution_state.status == 2))
' "$RAW" >/dev/null

echo "key go-test lines:"
rg -n 'InterleaveGate|ReceiveResetResponse|competing-start-ordered-replacement|healthy-worker-completion|scenario=competing-start|finalStatus=Completed|Error Trace|unable to open database file|FAIL|PASS' "$LOG" | sed -n '1,80p'

echo "trace summary:"
jq -s -r '
  "start_response_runs=" + ([.[] | select(.name == "ReceiveResetResponse" and .data.kind == "start") | .data.run] | join(",")),
  "reset_response_runs=" + ([.[] | select(.name == "ReceiveResetResponse" and .data.kind == "reset") | .data.run] | join(",")),
  (.[] | select(.name == "Checkpoint" and .data.name == "competing-start-ordered-replacement")
    | "ordered_replacement competitor_run=" + .data.competitor.State.execution_state.run_id
      + " competitor_status=TERMINATED(5)"
      + " reset_run=" + .data.result.State.execution_state.run_id
      + " reset_status=RUNNING(1)"),
  (.[] | select(.name == "Checkpoint" and .data.name == "healthy-worker-completion")
    | "healthy_completion reset_run=" + .data.result.State.execution_state.run_id
      + " final_status=COMPLETED(2)"
      + " faults=" + (.data.faults | tostring)
      + " history_events=" + (.data.history.history.events | length | tostring))
' "$RAW"

echo "CR3_REPRO_OBSERVED: competing Start committed during missing-current Reset gap; Reset returned success; competing run was terminated; reset run completed."
