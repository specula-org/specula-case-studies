#!/usr/bin/env bash
set -euo pipefail

WORKTREE="/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-server-20260803/ratis-server/.specula-output/confirmation/CR-5/worktree"
TEST_CLASS="org.apache.ratis.server.simulation.TestRaftReconfigurationWithSimulatedRpc"
MVN_FLAGS=(-pl ratis-test -am -DfailIfNoTests=false -Dcheckstyle.skip -Drat.skipShade -DskipShade -Dspotbugs.skip -DskipITs)
REPORT="$WORKTREE/ratis-test/target/surefire-reports/${TEST_CLASS}.txt"

run_case() {
  local level="$1"
  local method="$2"
  local note="$3"

  echo "== ${level}: ${method} =="
  echo "${note}"
  echo "command: timeout 15m ./mvnw ${MVN_FLAGS[*]} -Dtest=${TEST_CLASS}#${method} test"
  rm -f "$REPORT"
  if timeout 15m ./mvnw "${MVN_FLAGS[@]}" "-Dtest=${TEST_CLASS}#${method}" test >/tmp/cr5-${method}.mvn.log 2>&1; then
    echo "maven-exit: 0"
  else
    local status=$?
    echo "maven-exit: ${status}"
    echo "--- maven tail ---"
    tail -n 80 "/tmp/cr5-${method}.mvn.log" || true
    return "${status}"
  fi

  echo "--- surefire report ---"
  if [[ -f "$REPORT" ]]; then
    sed -n '1,40p' "$REPORT"
  else
    echo "missing surefire report: $REPORT"
    return 99
  fi
  echo
}

cd "$WORKTREE"
echo "CR-5 reproduction attempt on $(git rev-parse HEAD)"
echo "Worktree: $WORKTREE"
echo

run_case "Level 0 public API" "testLeaderStepDown" \
  "Normal client setConfiguration removes the current leader and waits for the stable new conf."

run_case "Level 1 timing assistance" "testRevertConfigurationChange" \
  "Existing request-blocking hooks widen the stale-old-leader window while a config entry is persisted but not committed."

run_case "Level 2 reachable state injection" "testLeaderElectionWhenChangeFromSingleToHA" \
  "Existing test utility installs a transitional single-to-HA configuration that is reachable through real reconfiguration."

echo "Level 3 source patch: not applied."
echo "Reason: after Levels 0-2, the only way to force a bad old-only leader outcome would be to fabricate an old-only higher-term leader that RequestVote cannot elect under VoteContext.checkConf; that is an unreachable precondition, not a sound CR-5 reproduction."
echo
echo "CR-5 result: no reproduced live harm from reconfiguration catch-up, leader recognition, or RequestVote membership guards."
