#!/usr/bin/env bash
set -euo pipefail

WORKTREE="/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-system-20260803/ratis-system/.specula-output/confirmation/MC-2/worktree"
TEST_REL="ratis-server/src/test/java/org/apache/ratis/server/impl/TestBugMC2AppendComposeMismatch.java"
TEST_PATH="$WORKTREE/$TEST_REL"
CONSUMER_TEST_REL="ratis-server/src/test/java/org/apache/ratis/server/leader/TestBugMC2AppendReplyConsumer.java"
CONSUMER_TEST_PATH="$WORKTREE/$CONSUMER_TEST_REL"

cleanup() {
  rm -f "$TEST_PATH"
  rm -f "$CONSUMER_TEST_PATH"
}
trap cleanup EXIT

cd "$WORKTREE"

if rg -q "NavigableIndices\\(RaftServer\\.Division owner\\)" ratis-server/src/main/java/org/apache/ratis/server/impl/ServerImplUtils.java; then
  CONSTRUCTOR="new ServerImplUtils.NavigableIndices(null)"
else
  CONSTRUCTOR="new ServerImplUtils.NavigableIndices()"
fi

mkdir -p "$(dirname "$TEST_PATH")"
cat > "$TEST_PATH" <<JAVA
package org.apache.ratis.server.impl;

import org.apache.ratis.proto.RaftProtos.LogEntryProto;
import org.apache.ratis.proto.RaftProtos.StateMachineLogEntryProto;
import org.apache.ratis.protocol.ClientId;
import org.apache.ratis.server.protocol.TermIndex;
import org.apache.ratis.server.raftlog.LogProtoUtils;
import org.apache.ratis.thirdparty.com.google.protobuf.ByteString;
import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

import java.util.Collections;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.BooleanSupplier;

public class TestBugMC2AppendComposeMismatch {
  @Test
  public void testSameStartIndexDifferentTermReusesPreviousFuture() throws Exception {
    final ServerImplUtils.NavigableIndices indices = $CONSTRUCTOR;
    final AtomicInteger appendCalls = new AtomicInteger();
    final AtomicReference<List<LogEntryProto>> physicallyAppended = new AtomicReference<>();
    final CompletableFuture<Void> firstPhysicalAppend = new CompletableFuture<>();

    final LogEntryProto oldLeaderEntry = entry(1L, 1L, "v1");
    final LogEntryProto newLeaderEntry = entry(2L, 1L, "v2");

    final CompletableFuture<Void> firstFuture = indices.append(
        Collections.singletonList(oldLeaderEntry),
        entries -> {
          appendCalls.incrementAndGet();
          physicallyAppended.set(entries);
          return firstPhysicalAppend;
        });
    waitFor(() -> appendCalls.get() == 1);

    Assertions.assertTrue(indices.contains(TermIndex.valueOf(1L, 1L)),
        "precondition: old term-1 append is tracked in-flight at index 1");
    Assertions.assertFalse(indices.contains(TermIndex.valueOf(2L, 1L)),
        "precondition: term-2/index-1 is not the tracked in-flight entry");

    final CompletableFuture<Void> secondFuture = indices.append(
        Collections.singletonList(newLeaderEntry),
        entries -> {
          appendCalls.incrementAndGet();
          throw new AssertionError("second appendLog must not be invoked when startIndex collides");
        });

    Assertions.assertEquals(1, appendCalls.get(),
        "only the old term-1 entry was submitted to appendLog");
    Assertions.assertFalse(secondFuture.isDone(),
        "the second append is waiting on the old term-1 append future");
    Assertions.assertEquals(1L, physicallyAppended.get().get(0).getTerm());
    Assertions.assertEquals("v1", physicallyAppended.get().get(0)
        .getStateMachineLogEntry().getLogData().toStringUtf8());

    firstPhysicalAppend.complete(null);
    firstFuture.get(5, TimeUnit.SECONDS);
    secondFuture.get(5, TimeUnit.SECONDS);

    System.out.println("MC-2_LEVEL2_REPRO: second request startIndex=1 term=2 value=v2 completed via reused future");
    System.out.println("MC-2_LEVEL2_REPRO: appendLog calls=" + appendCalls.get()
        + ", physical entry term=" + physicallyAppended.get().get(0).getTerm()
        + ", physical entry value=" + physicallyAppended.get().get(0)
            .getStateMachineLogEntry().getLogData().toStringUtf8());
  }

  private static LogEntryProto entry(long term, long index, String value) {
    final StateMachineLogEntryProto sm = LogProtoUtils.toStateMachineLogEntryProto(
        ClientId.randomId(), term * 1000 + index, StateMachineLogEntryProto.Type.WRITE,
        ByteString.copyFromUtf8(value), null);
    return LogProtoUtils.toLogEntryProto(sm, term, index);
  }

  private static void waitFor(BooleanSupplier condition) throws Exception {
    final long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
    while (!condition.getAsBoolean()) {
      if (System.nanoTime() > deadline) {
        throw new TimeoutException("condition did not become true");
      }
      Thread.sleep(10);
    }
  }
}
JAVA

mkdir -p "$(dirname "$CONSUMER_TEST_PATH")"
cat > "$CONSUMER_TEST_PATH" <<'JAVA'
package org.apache.ratis.server.leader;

import org.apache.ratis.conf.RaftProperties;
import org.apache.ratis.proto.RaftProtos.AppendEntriesReplyProto;
import org.apache.ratis.protocol.RaftPeer;
import org.apache.ratis.protocol.RaftPeerId;
import org.apache.ratis.server.RaftServer;
import org.apache.ratis.util.Timestamp;
import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.LongUnaryOperator;

import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoMoreInteractions;
import static org.mockito.Mockito.when;

class TestBugMC2AppendReplyConsumer {
  private static final RaftPeerId FOLLOWER_ID = RaftPeerId.valueOf("follower");

  @Test
  void appendSuccessAdvancesFollowerProgress() {
    final LeaderState leaderState = mock(LeaderState.class);
    final TestFollowerInfo follower = new TestFollowerInfo(1, 0);
    final LogAppenderDefault appender = newLogAppender(leaderState, follower);
    final AppendEntriesReplyProto reply = AppendEntriesReplyProto.newBuilder()
        .setResult(AppendEntriesReplyProto.AppendResult.SUCCESS)
        .setNextIndex(2)
        .setMatchIndex(1)
        .build();

    appender.handleReply(reply, 1, 0, false);

    Assertions.assertEquals(1, follower.getMatchIndex());
    Assertions.assertEquals(2, follower.getNextIndex());
    Assertions.assertEquals(1, follower.successfulMatchIndexUpdates.get());
    Assertions.assertEquals(1, follower.nextIndexIncreases.get());
    verify(leaderState).onFollowerSuccessAppendEntries(follower);
    verify(leaderState).onAppendEntriesReply(appender, reply);
    verifyNoMoreInteractions(leaderState);

    System.out.println("MC-2_CONSUMER_REPRO: LogAppenderDefault.handleReply advanced matchIndex=1 nextIndex=2 from SUCCESS");
  }

  private static LogAppenderDefault newLogAppender(LeaderState leaderState, FollowerInfo follower) {
    final RaftServer.Division division = mock(RaftServer.Division.class);
    final RaftServer raftServer = mock(RaftServer.class);
    when(division.getRaftServer()).thenReturn(raftServer);
    when(division.getThreadGroup()).thenReturn(Thread.currentThread().getThreadGroup());
    when(raftServer.getProperties()).thenReturn(new RaftProperties());
    return new LogAppenderDefault(division, leaderState, follower);
  }

  private static final class TestFollowerInfo implements FollowerInfo {
    private final RaftPeer peer = RaftPeer.newBuilder().setId(FOLLOWER_ID).build();
    private final AtomicInteger successfulMatchIndexUpdates = new AtomicInteger();
    private final AtomicInteger nextIndexIncreases = new AtomicInteger();
    private long matchIndex;
    private long nextIndex;

    private TestFollowerInfo(long nextIndex, long matchIndex) {
      this.nextIndex = nextIndex;
      this.matchIndex = matchIndex;
    }

    @Override
    public String getName() {
      return FOLLOWER_ID.toString();
    }

    @Override
    public RaftPeerId getId() {
      return FOLLOWER_ID;
    }

    @Override
    public RaftPeer getPeer() {
      return peer;
    }

    @Override
    public long getMatchIndex() {
      return matchIndex;
    }

    @Override
    public boolean updateMatchIndex(long newMatchIndex) {
      if (newMatchIndex > matchIndex) {
        matchIndex = newMatchIndex;
        successfulMatchIndexUpdates.incrementAndGet();
        return true;
      }
      return false;
    }

    @Override
    public long getCommitIndex() {
      return 0;
    }

    @Override
    public boolean updateCommitIndex(long newCommitIndex) {
      return false;
    }

    @Override
    public long getSnapshotIndex() {
      return 0;
    }

    @Override
    public void setSnapshotIndex(long newSnapshotIndex) {
    }

    @Override
    public void setAttemptedToInstallSnapshot() {
    }

    @Override
    public boolean hasAttemptedToInstallSnapshot() {
      return false;
    }

    @Override
    public long getNextIndex() {
      return nextIndex;
    }

    @Override
    public void increaseNextIndex(long newNextIndex) {
      if (newNextIndex > nextIndex) {
        nextIndex = newNextIndex;
        nextIndexIncreases.incrementAndGet();
      }
    }

    @Override
    public void decreaseNextIndex(long newNextIndex) {
      nextIndex = Math.min(nextIndex, newNextIndex);
    }

    @Override
    public void setNextIndex(long newNextIndex) {
      nextIndex = newNextIndex;
    }

    @Override
    public void updateNextIndex(long newNextIndex) {
      nextIndex = newNextIndex;
    }

    @Override
    public void computeNextIndex(LongUnaryOperator op) {
      nextIndex = op.applyAsLong(nextIndex);
    }

    @Override
    public Timestamp getLastRpcResponseTime() {
      return Timestamp.currentTime();
    }

    @Override
    public Timestamp getLastRpcSendTime() {
      return Timestamp.currentTime();
    }

    @Override
    public void updateLastRpcResponseTime() {
    }

    @Override
    public void updateLastRpcSendTime(boolean isHeartbeat) {
    }

    @Override
    public Timestamp getLastRpcTime() {
      return Timestamp.currentTime();
    }

    @Override
    public Timestamp getLastHeartbeatSendTime() {
      return Timestamp.currentTime();
    }

    @Override
    public Timestamp getLastRespondedAppendEntriesSendTime() {
      return Timestamp.currentTime();
    }

    @Override
    public void updateLastRespondedAppendEntriesSendTime(Timestamp sendTime) {
    }

    @Override
    public ErrorState getErrorState() {
      return null;
    }
  }
}
JAVA

echo "MC-2 repro: Level 0 pure black-box was not encoded in this component repro script."
echo "MC-2 repro: Level 1 timing-assisted cluster run needs a pre-append visibility hook not present in the stock harness."
echo "MC-2 repro: executing Level 2 admissible-state test from counterexample step 24."
timeout 20m ./mvnw -pl ratis-server -am \
  -Dtest=TestBugMC2AppendComposeMismatch,TestBugMC2AppendReplyConsumer \
  -DfailIfNoTests=false \
  -Dsurefire.failIfNoSpecifiedTests=false \
  -Dcheckstyle.skip=true \
  -Drat.skip=true \
  -Dspotbugs.skip=true \
  test
