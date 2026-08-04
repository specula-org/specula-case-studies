#!/usr/bin/env bash
set -euo pipefail

REPO="/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-server-20260803/ratis-server/.specula-output/confirmation/CR-3/worktree"
cd "$REPO"

echo "CR-3 known-fixed verification"
echo "HEAD: $(git rev-parse HEAD)"
echo
echo "Known upstream reports/fixes covering this mechanism:"
git log --oneline --decorate --all \
  --grep='RATIS-2511' --grep='RATIS-2430' --grep='RATIS-1481' \
  --grep='RATIS-1402' --grep='RATIS-2148'
echo
echo "Current guard sites:"
rg -n "getReadException|waitToAdvance\\(|getInProgressInstallSnapshotIndex\\(|appendSnapshot\\(|finalizeSnapshot\\(|checkInconsistentAppendEntries|state\\.reloadStateMachine\\(latestInstalledSnapshotTermIndex|syncWithSnapshot" \
  ratis-server/src/main/java/org/apache/ratis/server/impl/RaftServerImpl.java \
  ratis-server/src/main/java/org/apache/ratis/server/impl/SnapshotInstallationHandler.java \
  ratis-server/src/main/java/org/apache/ratis/server/impl/ServerState.java \
  ratis-server/src/main/java/org/apache/ratis/server/raftlog/segmented/SegmentedRaftLogWorker.java
echo
echo "Running upstream regression for follower ReadIndex during snapshot installation:"
export MAVEN_OPTS="${MAVEN_OPTS:-} -XX:+PerfDisableSharedMem"
export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-} -XX:+PerfDisableSharedMem"
timeout 15m ./mvnw -pl ratis-test -am \
  -Dtest=TestLinearizableReadWithGrpc#testFollowerLinearizableReadFailsWhenInstallingSnapshot \
  -DfailIfNoTests=false test
