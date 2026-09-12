#!/usr/bin/env bash
set -euo pipefail

SOURCE_REPO="${SOURCE_REPO:-/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-activity-20260910/temporal-activity/.specula-output/confirmation/CR-3/worktree}"
FINDING_DIR="${FINDING_DIR:-/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-activity-20260910/temporal-activity/.specula-output/confirmation/CR-3}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
OUT_DIR="${CR3_REPRO_OUT:-$FINDING_DIR/repro-output/test_bugCR-3_commit_response_timeout-$RUN_ID}"

run_subtest() {
  local level="$1"
  local label="$2"
  local subtest="$3"
  local trace_dir="$OUT_DIR/$level"
  local log="$OUT_DIR/$level-go-test.log"

  mkdir -p "$trace_dir"
  echo
  echo "$label"
  echo "command: timeout 10m env SPECULA_TRACE_ROOT=$trace_dir go test -tags=test_dep ./tests -run ^TestSpeculaActivityTrace/$subtest$ -count=1 -v"

  set +e
  (
    cd "$SOURCE_REPO"
    timeout 10m env SPECULA_TRACE_ROOT="$trace_dir" \
      go test -tags=test_dep ./tests -run "^TestSpeculaActivityTrace/$subtest$" -count=1 -v
  ) >"$log" 2>&1
  local status=$?
  set -e

  if [[ $status -ne 0 ]]; then
    echo "go test failed with status=$status"
    tail -n 80 "$log"
    exit "$status"
  fi

  grep -E -- '--- PASS: TestSpeculaActivityTrace|--- PASS: TestSpeculaActivityTrace/' "$log" | tail -n 6 || true
  grep -E -- '^PASS$|^ok[[:space:]]' "$log" | tail -n 2 || true
}

summarize_level1_trace() {
  local raw="$OUT_DIR/level1/raw/write_commit_response_timeout.jsonl"
  local endpoint="$OUT_DIR/level1/write_commit_response_timeout.endpoint.json"

  if [[ ! -s "$raw" ]]; then
    echo "missing trace file: $raw" >&2
    exit 1
  fi
  if [[ ! -s "$endpoint" ]]; then
    echo "missing endpoint summary: $endpoint" >&2
    exit 1
  fi

  echo
  echo "Trace evidence:"
  jq -r '
    def ai_count:
      ((.observation.sqlSnapshot.activityInfos //
        .observation.response.database_mutable_state.activity_infos //
        .observation.finalReadback.database_mutable_state.activity_infos //
        {}) | length);
    def buffered_count:
      ((.observation.sqlSnapshot.bufferedEvents //
        .observation.response.database_mutable_state.buffered_events //
        .observation.finalReadback.database_mutable_state.buffered_events //
        []) | length);
    def task_count:
      ((.observation.sqlSnapshot.tasks // []) | length);
    def terminal_count:
      ((.observation.terminalEventsConsumed // []) | length);
    select(
      (.event == "ApplyWorkflowMutationTx" and buffered_count == 2 and ai_count == 0) or
      .event == "PersistenceResponseTimeout" or
      .event == "LoseShardContext" or
      .event == "ReacquireShard" or
      .event == "RejectActivityRequest" or
      .event == "DeliverActivityResponse" or
      (.event == "ReadWorkflowExecution" and
        ((.observation.label // "") == "after-injected-write" or
         (.observation.label // "") == "terminal-before-WFT-consumption" or
         (.observation.label // "") == "complete-endpoint")) or
      .event == "FinishTrace"
    ) |
    "seq=\(.seq) event=\(.event) label=\(.observation.label // "") kind=\(.observation.kind // "") error=\(.observation.error.type // "") commitConfirmed=\(.observation.commitConfirmed // "") activityInfos=\(ai_count) bufferedEvents=\(buffered_count) tasks=\(task_count) terminalEvents=\(terminal_count) endpointComplete=\(.observation.implementationEndpointComplete // "")"
  ' "$raw"

  echo
  echo "Endpoint summary:"
  jq -c '{scenario,sourceRevision,terminal,endpointComplete}' "$endpoint"
}

mkdir -p "$OUT_DIR"

echo "CR-3 reproduction attempt"
echo "source_rev=$(git -C "$SOURCE_REPO" rev-parse HEAD)"
echo "worktree=$SOURCE_REPO"
echo "output_dir=$OUT_DIR"

run_subtest "level0" "Level 0: public workflow/activity path without injected persistence fault" "healthy_buffered_reload"
run_subtest "level1" "Level 1: public activity completion with system persistence fault ExecuteAndTimeout" "write_commit_response_timeout"
summarize_level1_trace

echo
echo "Level 2: not used; Level 1 reached the committed-write/lost-response precondition through public APIs plus Temporal's persistence-fault hook."
echo "Level 3: not used; adding a source delay/patch would not expose an additional real consumer after Level 1 showed reload, duplicate rejection, and workflow-task delivery."
echo "RESULT: temporary API/persistence disagreement observed; no consumer-visible wrong Activity outcome reproduced."
