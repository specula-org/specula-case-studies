#!/usr/bin/env bash
set -euo pipefail

WORKTREE="/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-system-20260803/ratis-system/.specula-output/confirmation/CR-3/worktree"
OUTDIR="/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-system-20260803/ratis-system/.specula-output/confirmation/CR-3"
LOG="$OUTDIR/repro_CR-3_snapshot_frontier.log"
SNAPSHOT_HANDLER="$WORKTREE/ratis-server/src/main/java/org/apache/ratis/server/impl/SnapshotInstallationHandler.java"

mkdir -p "$OUTDIR"
: > "$LOG"

run_step() {
  local label="$1"
  shift
  {
    echo "===== $label ====="
    echo "COMMAND: $*"
  } | tee -a "$LOG"
  set +e
  "$@" 2>&1 | tee -a "$LOG"
  local status=${PIPESTATUS[0]}
  set -e
  echo "EXIT_CODE: $status" | tee -a "$LOG"
  if [ "$status" -ne 0 ]; then
    echo "CR3_STEP_FAILED: $label" | tee -a "$LOG"
    exit "$status"
  fi
}

cd "$WORKTREE"

MAVEN=(timeout 30m ./mvnw -q -pl ratis-test -am -DfailIfNoTests=false)

run_step "LEVEL 0 normal chunked snapshot bootstrap" \
  "${MAVEN[@]}" -Dtest='TestRaftSnapshotWithGrpc#testInstallSnapshotDuringBootstrap' test

run_step "LEVEL 1 notification snapshot bootstrap with state-machine delay" \
  "${MAVEN[@]}" -Dtest='TestInstallSnapshotNotificationWithGrpc#testInstallSnapshotDuringBootstrap' test

run_step "LEVEL 2 reachable purge frontier injection for follower nextIndex" \
  "${MAVEN[@]}" -Dtest='TestLogAppenderWithGrpc#testNewAppendEntriesRequestAfterPurgeFollowerAtStartIndex' test

backup="$(mktemp)"
cp "$SNAPSHOT_HANDLER" "$backup"
restore() {
  if [ -f "$backup" ]; then
    cp "$backup" "$SNAPSHOT_HANDLER"
    rm -f "$backup"
  fi
}
trap restore EXIT

perl -0pi -e 's/installedSnapshotTermIndex\.set\(reply\);/try { Thread.sleep(250L); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }\n                installedSnapshotTermIndex.set(reply);/' "$SNAPSHOT_HANDLER"

run_step "LEVEL 3 source-delay widened notification reload window plus purge restart config" \
  "${MAVEN[@]}" -Dtest='TestInstallSnapshotNotificationWithGrpc#testInstallSnapshotInstalledEvent' test

restore
trap - EXIT

{
  echo "CR3_RESULT: all targeted snapshot-frontier tests passed"
  echo "CR3_OBSERVED_BUG: no"
} | tee -a "$LOG"
