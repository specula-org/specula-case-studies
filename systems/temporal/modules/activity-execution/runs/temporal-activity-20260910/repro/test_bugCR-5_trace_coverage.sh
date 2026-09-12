#!/usr/bin/env bash
set -euo pipefail

WORKTREE="/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-activity-20260910/temporal-activity/.specula-output/confirmation/CR-5/worktree"
BASE_OUT="/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-activity-20260910/temporal-activity/.specula-output/confirmation/CR-5/repro-output"
RUN_ID="${CR5_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
OUT="$BASE_OUT/current-$RUN_ID"
LOGS="$OUT/logs"

mkdir -p "$OUT/level0" "$OUT/level1" "$LOGS"
cd "$WORKTREE"

summarize_go_test() {
  local log="$1"
  grep -E '^(--- PASS:|--- FAIL:|PASS|FAIL|ok[[:space:]]|panic:)' "$log" || true
}

run_go_test() {
  local label="$1"
  local log="$2"
  shift 2
  set +e
  "$@" >"$log" 2>&1
  local status=$?
  set -e
  summarize_go_test "$log"
  if [[ $status -ne 0 ]]; then
    echo "${label}=FAIL status=${status} log=${log}"
    exit "$status"
  fi
  echo "${label}=PASS log=${log}"
}

echo "CR5 repro start"
echo "source_head=$(git rev-parse HEAD)"
echo "dirty_entries=$(git status --short | wc -l | tr -d ' ')"

run_go_test \
  "LEVEL0_go_test" \
  "$LOGS/level0.healthy.go-test.log" \
  env SPECULA_TRACE_ROOT="$OUT/level0" timeout 5m go test -tags test_dep ./tests \
    -run '^TestSpeculaActivityTrace$/^healthy_buffered_reload$' -count=1 -v

echo "LEVEL0_finish=$(jq -c 'select(.event=="FinishTrace") | {seq,event,complete:.evidence.complete,modelTraceComplete:.observation.modelTraceComplete,endpoint:.observation.implementationEndpointComplete,terminalCount:(.observation.terminalEventsConsumed|length),finalAI:(.observation.finalMutableState.activity_infos|length),buffered:(.observation.finalMutableState.buffered_events|length)}' "$OUT/level0/raw/healthy_buffered_reload.jsonl" | tail -1)"
echo "LEVEL0_result=healthy public activity execution completed; no committed-timeout fault occurred"

run_go_test \
  "LEVEL1_projection_unit_go_test" \
  "$LOGS/level1.projection-unit.go-test.log" \
  timeout 5m go test ./service/history/workflow \
    -run 'TestActivitySuite/TestGetPendingActivityInfoNextAttemptScheduleTimeAndCurrentRetryInterval' \
    -count=1 -v

run_go_test \
  "LEVEL1_projection_public_go_test" \
  "$LOGS/level1.projection-public.go-test.log" \
  timeout 10m go test -tags test_dep ./tests \
    -run '^TestActivityParityTestSuite$/^TestCurrentRetryIntervalAndNextAttemptScheduleTime$' \
    -count=1 -v

run_go_test \
  "LEVEL1_commit_timeout_go_test" \
  "$LOGS/level1.commit-timeout.go-test.log" \
  env SPECULA_TRACE_ROOT="$OUT/level1" timeout 5m go test -tags test_dep ./tests \
    -run '^TestSpeculaActivityTrace$/^write_commit_response_timeout$' -count=1 -v

TRACE="$OUT/level1/raw/write_commit_response_timeout.jsonl"
echo "LEVEL1_persistence_timeout=$(jq -c 'select(.event=="PersistenceResponseTimeout") | {seq,event,kind:.observation.kind,delegateExecuted:.observation.delegateExecuted,error:.observation.error,dbRecordVersion:.observation.dbRecordVersion,complete:.evidence.complete}' "$TRACE" | tail -1)"
echo "LEVEL1_activity_responses=$(jq -c 'select(.event=="DeliverActivityResponse") | {seq,event,kind:.observation.kind,error:.observation.error,complete:.evidence.complete}' "$TRACE" | paste -sd ';' -)"
echo "LEVEL1_after_fault_readback=$(jq -c 'select(.event=="ReadWorkflowExecution" and .seq > 69) | {seq,event,activityInfos:(.observation.response.mutable_state.activity_infos|length),dbActivityInfos:(.observation.response.database_mutable_state.activity_infos|length),buffered:(.observation.response.mutable_state.buffered_events|length),complete:.evidence.complete}' "$TRACE" | head -1)"
echo "LEVEL1_finish=$(jq -c 'select(.event=="FinishTrace") | {seq,event,complete:.evidence.complete,modelTraceComplete:.observation.modelTraceComplete,endpoint:.observation.implementationEndpointComplete,terminalCount:(.observation.terminalEventsConsumed|length),finalAI:(.observation.finalMutableState.activity_infos|length),buffered:(.observation.finalMutableState.buffered_events|length)}' "$TRACE" | tail -1)"
echo "LEVEL1_evidence_complete_values=$(jq -sc '[.[].evidence.complete] | unique' "$TRACE")"

TMP_TEST="$(mktemp "$WORKTREE/tests/testcore/cr5_history_task_recorder_XXXXXX_test.go")"
cleanup() {
  rm -f "$TMP_TEST"
}
trap cleanup EXIT
cat >"$TMP_TEST" <<'GOEOF'
package testcore

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	persistencespb "go.temporal.io/server/api/persistence/v1"
	"go.temporal.io/server/common/definition"
	"go.temporal.io/server/common/log"
	"go.temporal.io/server/common/persistence"
	"go.temporal.io/server/service/history/tasks"
)

type cr5ExecutionManager struct {
	persistence.ExecutionManager
	err error
}

func (m *cr5ExecutionManager) UpdateWorkflowExecution(
	context.Context,
	*persistence.UpdateWorkflowExecutionRequest,
) (*persistence.UpdateWorkflowExecutionResponse, error) {
	return &persistence.UpdateWorkflowExecutionResponse{}, m.err
}

func TestBugCR5HistoryTaskRecorderDropsCommittedTimeoutTasks(t *testing.T) {
	timeoutErr := &persistence.TimeoutError{Msg: "ExecuteAndTimeout committed but returned timeout"}
	recorder := NewHistoryTaskRecorder(&cr5ExecutionManager{err: timeoutErr}, log.NewNoopLogger())

	workflowKey := definition.NewWorkflowKey("cr5-namespace", "cr5-workflow", "cr5-run")
	req := &persistence.UpdateWorkflowExecutionRequest{
		ShardID: 1,
		RangeID: 2,
		UpdateWorkflowMutation: persistence.WorkflowMutation{
			ExecutionInfo: &persistencespb.WorkflowExecutionInfo{
				NamespaceId: workflowKey.NamespaceID,
				WorkflowId:  workflowKey.WorkflowID,
			},
			Tasks: map[tasks.Category][]tasks.Task{
				tasks.CategoryTransfer: {
					tasks.NewFakeTask(workflowKey, tasks.CategoryTransfer, time.Now()),
				},
			},
		},
	}

	_, err := recorder.UpdateWorkflowExecution(context.Background(), req)
	require.ErrorAs(t, err, &timeoutErr)

	recorded := recorder.GetAllRecordedTasks()[tasks.CategoryTransfer]
	require.Empty(t, recorded)
	t.Logf("CR5_RECORDER_GAP reachable_precondition=ExecuteAndTimeout request_transfer_tasks=%d delegate_error=%T recorder_transfer_tasks=%d",
		len(req.UpdateWorkflowMutation.Tasks[tasks.CategoryTransfer]), err, len(recorded))
}
GOEOF

run_go_test \
  "LEVEL2_recorder_go_test" \
  "$LOGS/level2.recorder.go-test.log" \
  timeout 5m go test ./tests/testcore \
    -run '^TestBugCR5HistoryTaskRecorderDropsCommittedTimeoutTasks$' -count=1 -v

grep 'CR5_RECORDER_GAP' "$LOGS/level2.recorder.go-test.log"
echo "LEVEL3_result=not_attempted; source patch would manufacture a symptom because Level1 reached the fault path and Level2 isolated the recorder-only observation gap"
echo "CR5_mask=Specula activity trace emits independent SQL/admin/public readbacks and every trace event carries evidence.complete=false; FinishTrace.modelTraceComplete=false, so the lossy recorder view is not accepted as a complete proof"
echo "CR5 repro end"
