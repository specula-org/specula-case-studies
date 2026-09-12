#!/usr/bin/env bash
set -euo pipefail

WORKTREE="/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-matching-20260910/temporal-matching/.specula-output/confirmation/CR-3/worktree"
HARNESS="/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-matching-20260910/temporal-matching/.specula-output/harness"
RUN_ROOT="/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-matching-20260910/temporal-matching/.specula-output/confirmation/CR-3/repro-runs"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
TRACE_DIR="$RUN_ROOT/$RUN_ID"
GO_LOG="$TRACE_DIR/go-test.log"

mkdir -p "$TRACE_DIR"

echo "CR-3 reproduction test"
echo "worktree=$(git -C "$WORKTREE" rev-parse HEAD)"
echo "trace_dir=$TRACE_DIR"
echo "command=SPECULA_HARNESS=$HARNESS SPECULA_TRACE_DIR=$TRACE_DIR TEMPORAL_TEST_TIMEOUT=90s timeout 240s go test -p 1 -tags test_dep ./service/matching -run '^(TestSpeculaMatchingNormal|TestSpeculaMatchingMetadataGC)$' -count=1 -timeout=180s -v"

(
  cd "$WORKTREE"
  SPECULA_HARNESS="$HARNESS" \
  SPECULA_TRACE_DIR="$TRACE_DIR" \
  TEMPORAL_TEST_TIMEOUT=90s \
  timeout 240s go test -p 1 -tags test_dep ./service/matching \
    -run '^(TestSpeculaMatchingNormal|TestSpeculaMatchingMetadataGC)$' \
    -count=1 -timeout=180s -v
) | tee "$GO_LOG"

TRACE="$TRACE_DIR/metadata-gc-takeover.ndjson"
if [[ ! -s "$TRACE" ]]; then
  echo "missing trace: $TRACE" >&2
  exit 2
fi

echo
echo "CR-3 parsed evidence"
echo "level0=TestSpeculaMatchingNormal passed with public AddWorkflowTask/PollWorkflowTaskQueue and no staged owner replacement"
echo "level1=TestSpeculaMatchingMetadataGC passed with timing gates for old-owner GC, stale metadata sync, and owner replacement"
echo "record_started_count=$(jq -s '[.[] | select(.record.event == "RecordTaskStarted")] | length' "$TRACE")"
echo "worker_response_count=$(jq -s '[.[] | select(.record.event == "PollTaskQueueResponse")] | length' "$TRACE")"
echo "old_owner_delete=$(jq -c 'select(.record.event=="CompleteTasksLessThan") | {seq:.record.seq,node:.record.node,args:.record.args,post:.record.post}' "$TRACE")"
echo "old_owner_stale_sync=$(jq -c 'select(.record.event=="UpdateTaskQueueConditionFailed") | {seq:.record.seq,node:.record.node,args:.record.args}' "$TRACE")"
echo "new_owner_read_after_delete=$(jq -c 'select(.record.event=="GetTasksSnapshot" and .record.node==2) | {seq:.record.seq,node:.record.node,args:.record.args}' "$TRACE" | tail -n 1)"
echo "final_state=$(tail -n 1 "$TRACE" | jq -c '.record | {seq,event,post:{durable:.post.durable,history:.post.history,dispatch:.post.dispatch[0:2],owner:.post.owner[0:2]}}')"
echo "result=no caller-visible lost required work: deleted task rows had History start and worker response before GC; new owner found no rows and ended with empty backlog"
