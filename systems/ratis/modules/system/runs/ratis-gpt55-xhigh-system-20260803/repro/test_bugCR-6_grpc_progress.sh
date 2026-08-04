#!/usr/bin/env bash
set -euo pipefail

WORKTREE="/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-system-20260803/ratis-system/.specula-output/confirmation/CR-6/worktree"

cd "$WORKTREE"

echo "CR6_REPRO_START worktree=$WORKTREE"
echo "CR6_LEVEL0 public client writes plus follower restart/reconnect"
echo "CR6_LEVEL1 public client writes plus test-hook timing: one follower AppendEntries handler is delayed past appender timeout"

timeout 10m ./mvnw -pl ratis-test -am -Dtest=org.apache.ratis.grpc.TestSpeculaCR6GrpcProgress \
  -DfailIfNoTests=false -DfailIfNoSpecifiedTests=false \
  -DskipShade -DskipCheckstyle -DskipRat -DskipSpotbugs test

echo "CR6_LEVEL2_NOT_USED Level 1 already creates the reachable delayed old-reply precondition via a real gRPC cluster; direct state injection would call private handler state."
echo "CR6_LEVEL3_NOT_USED No source patch was needed; patching GrpcLogAppender would create the symptom rather than exercise production logic."
echo "CR6_REPRO_DONE status=PASS_NO_BUG"
