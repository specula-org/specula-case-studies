#!/usr/bin/env bash
set -euo pipefail

REPO="/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-server-20260803/ratis-server/.specula-output/confirmation/CR-2/worktree"
OUT="/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-server-20260803/ratis-server/.specula-output/repro/test_bugCR-2_known_ratis1995.out"

mkdir -p "$(dirname "$OUT")"
: > "$OUT"
exec > >(tee "$OUT") 2>&1

cd "$REPO"
export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-} -XX:+PerfDisableSharedMem"

echo "CR-2 known-status regression: RATIS-1995 / apache/ratis#1261"
echo "repo=$(pwd)"
echo "head=$(git rev-parse HEAD)"
echo "test=ratis-test/src/test/java/org/apache/ratis/server/impl/TestLeaderElectionServerInterface.java#testVoterWithEmptyLog"
echo "java_tool_options=$JAVA_TOOL_OPTIONS"
echo "command=timeout 15m ./mvnw -pl ratis-test -am -DargLine=-XX:+PerfDisableSharedMem -Dtest=org.apache.ratis.server.impl.TestLeaderElectionServerInterface#testVoterWithEmptyLog -DfailIfNoTests=false -Dsurefire.failIfNoSpecifiedTests=false test"

timeout 15m ./mvnw -pl ratis-test -am \
  -DargLine=-XX:+PerfDisableSharedMem \
  -Dtest=org.apache.ratis.server.impl.TestLeaderElectionServerInterface#testVoterWithEmptyLog \
  -DfailIfNoTests=false \
  -Dsurefire.failIfNoSpecifiedTests=false \
  test

echo "output=$OUT"
