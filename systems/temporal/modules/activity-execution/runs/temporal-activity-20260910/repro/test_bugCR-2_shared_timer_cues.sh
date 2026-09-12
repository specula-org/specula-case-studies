#!/usr/bin/env bash
set -euo pipefail

WORKTREE="${1:-/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-activity-20260910/temporal-activity/.specula-output/confirmation/CR-2/worktree}"

cd "$WORKTREE"

echo "CR-2 shared timer cues reproduction/known-status check"
echo "worktree: $WORKTREE"
echo "source sha: $(git rev-parse HEAD)"
echo "dirty files relevant to CR-2:"
git status --short -- service/history/workflow/timer_sequence.go service/history/timer_queue_active_task_executor.go service/history/workflow/activity.go service/history/workflow/mutable_state_impl.go

echo
echo "Level 0 prefilter: upstream merged PR #11565 already reports this timer-status/deadline mechanism at the same site."
echo "Running focused in-tree tests that encode the intended behavior and guard against uncovered current deadlines."

cmd1=(
  go test ./service/history/workflow
  -run '^TestMutableStateSuite$'
  -testify.m '^TestNextActivityTimerTaskMask_(Retry_KeepsOnlyScheduleToClose|Retry_LegacyAnchor_ClearsScheduleToClose|AttemptChangedWithoutDeadlineMove_KeepsMask|ClearsOnlyMovedDeadlines|HeartbeatProgressKeepsPendingWakeup|UnrelatedOptionChanged_KeepsMask|TimerDisappears)$'
  -count=1
  -v
)
printf '+'
printf ' %q' "${cmd1[@]}"
printf '\n'
timeout 10m "${cmd1[@]}"

echo
cmd2=(
  go test ./service/history
  -run '^TestTimerQueueActiveTaskExecutorSuite$'
  -testify.m '^TestProcessActivityTimeout_Heartbeat_DedupUnderSkip$'
  -count=1
  -v
)
printf '+'
printf ' %q' "${cmd2[@]}"
printf '\n'
timeout 10m "${cmd2[@]}"

echo
echo "CR-2 result: targeted tests passed; no live uncovered timeout/retry obligation was reproduced."
