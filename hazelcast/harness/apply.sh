#!/usr/bin/env bash
# Apply TLA+ trace instrumentation to the Hazelcast artifact.
# Usage: cd case-studies/hazelcast && bash harness/apply.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT_DIR="$CASE_DIR/artifact/hazelcast"
RAFT_PKG="hazelcast/src/main/java/com/hazelcast/cp/internal/raft"
RAFT_MAIN="$ARTIFACT_DIR/$RAFT_PKG/impl"
RAFT_TEST="$ARTIFACT_DIR/hazelcast/src/test/java/com/hazelcast/cp/internal/raft/impl"
PARENT_COMMIT=f2fa6ae8420fd3198fda96d16d87ec3470e89d34

echo "=== Applying TLA+ trace instrumentation ==="

cd "$ARTIFACT_DIR"

# Step 1: Reset instrumented files to clean state
echo "[1/5] Resetting instrumented files..."
git checkout -- \
  $RAFT_PKG/impl/RaftNodeImpl.java \
  $RAFT_PKG/impl/handler/AppendFailureResponseHandlerTask.java \
  $RAFT_PKG/impl/handler/AppendRequestHandlerTask.java \
  $RAFT_PKG/impl/handler/AppendSuccessResponseHandlerTask.java \
  $RAFT_PKG/impl/handler/PreVoteRequestHandlerTask.java \
  $RAFT_PKG/impl/handler/PreVoteResponseHandlerTask.java \
  $RAFT_PKG/impl/handler/VoteRequestHandlerTask.java \
  $RAFT_PKG/impl/handler/VoteResponseHandlerTask.java \
  $RAFT_PKG/impl/task/PreVoteTask.java \
  $RAFT_PKG/impl/task/QueryTask.java \
  $RAFT_PKG/impl/task/ReplicateTask.java \
  2>/dev/null || true

# Step 2: Restore missing raft parent package files (moved to enterprise repo)
echo "[2/5] Restoring raft parent package files..."
for f in MembershipChangeMode.java QueryPolicy.java SnapshotAwareService.java package-info.java; do
    git show $PARENT_COMMIT:$RAFT_PKG/$f > "$ARTIFACT_DIR/$RAFT_PKG/$f" 2>/dev/null || true
done
mkdir -p "$ARTIFACT_DIR/$RAFT_PKG/command" "$ARTIFACT_DIR/$RAFT_PKG/exception"
for f in DestroyRaftGroupCmd.java RaftGroupCmd.java package-info.java; do
    git show $PARENT_COMMIT:$RAFT_PKG/command/$f > "$ARTIFACT_DIR/$RAFT_PKG/command/$f" 2>/dev/null || true
done
for f in LogValidationException.java MemberAlreadyExistsException.java MemberDoesNotExistException.java MismatchingGroupMembersCommitIndexException.java package-info.java; do
    git show $PARENT_COMMIT:$RAFT_PKG/exception/$f > "$ARTIFACT_DIR/$RAFT_PKG/exception/$f" 2>/dev/null || true
done

# Step 3: Fix compilation issues (SuppressFBWarnings, missing interface methods)
echo "[3/5] Fixing compilation issues..."
# Remove FindBugs annotations that aren't on classpath
for f in $RAFT_PKG/impl/dto/AppendRequest.java $RAFT_PKG/impl/persistence/RestoredRaftState.java; do
    sed -i '/edu.umd.cs.findbugs.annotations/d' "$f"
    sed -i '/@SuppressFBWarnings/d' "$f"
done
# Remove incomplete stub files
rm -f \
  hazelcast/src/main/java/com/hazelcast/cp/internal/MetadataRaftGroupManager.java \
  hazelcast/src/main/java/com/hazelcast/cp/internal/NodeEngineRaftIntegration.java \
  hazelcast/src/main/java/com/hazelcast/cp/internal/RaftGroupMembershipManager.java \
  hazelcast/src/main/java/com/hazelcast/cp/internal/RaftInvocationManager.java \
  hazelcast/src/main/java/com/hazelcast/cp/internal/RaftService.java

# Add missing interface methods to NopRaftStateStore
if ! grep -q "isChunkingSupportedVersion" $RAFT_PKG/impl/persistence/NopRaftStateStore.java; then
    sed -i '/^}$/i\
\    @Override\
\    public boolean isChunkingSupportedVersion() { return false; }\
\
\    @Override\
\    public void persistSnapshotChunk(Object snapshotChunk) { }\
\
\    @Override\
\    public void deleteSnapshotChunks(long snapshotIndex) { }' \
        $RAFT_PKG/impl/persistence/NopRaftStateStore.java
fi

# Add missing interface methods to InMemoryRaftStateStore
INMEMORY_STORE="hazelcast/src/test/java/com/hazelcast/cp/internal/raft/impl/testing/InMemoryRaftStateStore.java"
if ! grep -q "isChunkingSupportedVersion" "$INMEMORY_STORE"; then
    sed -i '/^}$/i\
\    @Override\
\    public boolean isChunkingSupportedVersion() { return false; }\
\
\    @Override\
\    public void persistSnapshotChunk(Object snapshotChunk) { }\
\
\    @Override\
\    public void deleteSnapshotChunks(long snapshotIndex) { }' \
        "$INMEMORY_STORE"
fi

# Step 4: Copy trace module and test into artifact
echo "[4/5] Copying trace module and test scenario..."
cp "$SCRIPT_DIR/src/TlaTraceLogger.java" "$RAFT_MAIN/TlaTraceLogger.java"
cp "$SCRIPT_DIR/src/TlaTraceTest.java" "$RAFT_TEST/TlaTraceTest.java"

# Step 5: Apply instrumentation patch
echo "[5/5] Applying instrumentation patch..."
git apply --check "$SCRIPT_DIR/patches/instrumentation.patch" 2>/dev/null && \
    git apply "$SCRIPT_DIR/patches/instrumentation.patch" || \
    echo "  Patch already applied or partially applied (continuing)"

echo "=== Instrumentation applied successfully ==="
