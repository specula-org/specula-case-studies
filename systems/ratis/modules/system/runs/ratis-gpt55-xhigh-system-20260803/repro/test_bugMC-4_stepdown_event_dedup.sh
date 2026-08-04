#!/usr/bin/env bash
set -euo pipefail

WORKTREE="/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-system-20260803/ratis-system/.specula-output/confirmation/MC-4/worktree"

cd "$WORKTREE"

echo "repro: MC-4 higher-term STEP_DOWN dropped by type-only EventQueue dedup"
echo "command: timeout 20m ./mvnw -pl ratis-test -am -DskipShade -Drat.skip=true -Dcheckstyle.skip=true -Dspotbugs.skip=true -Djacoco.skip=true -DfailIfNoTests=false -Dtest=TestLeaderStepDownEventQueueDedup#testHigherTermStepDownDroppedByTypeOnlyDedup test"

timeout 20m ./mvnw -pl ratis-test -am \
  -DskipShade \
  -Drat.skip=true \
  -Dcheckstyle.skip=true \
  -Dspotbugs.skip=true \
  -Djacoco.skip=true \
  -DfailIfNoTests=false \
  -Dtest=TestLeaderStepDownEventQueueDedup#testHigherTermStepDownDroppedByTypeOnlyDedup \
  test
