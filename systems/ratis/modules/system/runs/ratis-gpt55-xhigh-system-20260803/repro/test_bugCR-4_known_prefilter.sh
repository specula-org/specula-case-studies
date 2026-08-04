#!/usr/bin/env bash
set -euo pipefail

WORKTREE="/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-system-20260803/ratis-system/.specula-output/confirmation/CR-4/worktree"

echo "CR-4 known-status prefilter evidence"
echo "worktree=$(git -C "$WORKTREE" rev-parse HEAD)"

echo "upstream PR #1246 commit:"
git -C "$WORKTREE" show --no-patch --format="%H %s" c1301b082c3f9359dc510e6f5c26ff0d7a8a7e21

echo "upstream PR #1331 commit:"
git -C "$WORKTREE" show --no-patch --format="%H %s" d7370f897f43aa31d44beb3bf61933430bfb8355

echo "current checkProgress latest-config guard:"
rg -n "follower\\.getMatchIndex\\(\\) >= server\\.getRaftConf\\(\\)\\.getLogEntryIndex\\(\\)" \
  "$WORKTREE/ratis-server/src/main/java/org/apache/ratis/server/impl/LeaderStateImpl.java"

echo "current listener promotion on configuration application:"
rg -n "changeToFollowerAndPersistMetadata\\(getCurrentTerm\\(\\), true, \"setRaftConf\"\\)" \
  "$WORKTREE/ratis-server/src/main/java/org/apache/ratis/server/impl/ServerState.java"

echo "current snapshot-carried configuration uses updateConfiguration:"
rg -n "state\\.updateConfiguration\\(Collections\\.singletonList\\(proto\\)\\)" \
  "$WORKTREE/ratis-server/src/main/java/org/apache/ratis/server/impl/SnapshotInstallationHandler.java"

echo "RESULT: KNOWN fixed upstream; code-review prefilter applies; no live reproduction attempted."
