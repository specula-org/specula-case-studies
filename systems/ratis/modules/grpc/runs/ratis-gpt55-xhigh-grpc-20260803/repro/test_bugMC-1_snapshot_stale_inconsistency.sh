#!/usr/bin/env bash
set -euo pipefail

WORKTREE="/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-grpc-20260803/ratis-grpc/.specula-output/confirmation/MC-1/worktree"
OUT="/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-grpc-20260803/ratis-grpc/.specula-output/confirmation/MC-1/test_bugMC-1_snapshot_stale_inconsistency.out"

cd "$WORKTREE"
echo "Running MC-1 stale snapshot/append reply reproduction"
echo "Worktree: $WORKTREE"
echo "Output: $OUT"

timeout 10m ./mvnw -pl ratis-server -am \
  -Dtest=org.apache.ratis.server.leader.TestSpeculaMC1SnapshotStaleInconsistency#staleInconsistencyAfterSnapshotProgressIsMaskedBySnapshotRetry \
  -Dmaven.test.redirectTestOutputToFile=false \
  -DtrimStackTrace=false \
  test | tee "$OUT"

grep -F "LEVEL2: injected reachable stale INCONSISTENCY order" "$OUT"
grep -F "BUG_STATE: stale INCONSISTENCY" "$OUT"
grep -F "MASK_TRIGGER: newAppendEntriesRequest returned null" "$OUT"
grep -F "MASK_RESOLUTION: completing the snapshot retry restores nextIndex=24" "$OUT"
