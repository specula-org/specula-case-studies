#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-server-20260803/ratis-server/.specula-output/confirmation/MC-2/worktree"
OUT_DIR="/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-server-20260803/ratis-server/.specula-output/repro"
TEST_SRC="$ROOT/ratis-server/src/test/java/org/apache/ratis/TestBugMC2OldLeaderLeaseRead.java"
OLD_TEST_SRC="$ROOT/ratis-test/src/test/java/org/apache/ratis/TestBugMC2OldLeaderLeaseRead.java"
SOURCE="$ROOT/ratis-server/src/main/java/org/apache/ratis/server/leader/LogAppenderDefault.java"
BACKUP="$OUT_DIR/test_bugMC-2_LogAppenderDefault.java.bak"
OUT="$OUT_DIR/test_bugMC-2_old_leader_lease_read.out"

export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-} -XX:-UsePerfData"

cleanup() {
  rm -f "$TEST_SRC"
  rm -f "$OLD_TEST_SRC"
  rm -f "$ROOT"/ratis-server/target/test-classes/org/apache/ratis/TestBugMC2OldLeaderLeaseRead*.class
  rm -f "$ROOT"/ratis-test/target/test-classes/org/apache/ratis/TestBugMC2OldLeaderLeaseRead*.class
  if [[ -f "$BACKUP" ]]; then
    cp "$BACKUP" "$SOURCE"
    rm -f "$BACKUP"
  fi
}
trap cleanup EXIT

cleanup

cat > "$TEST_SRC" <<'JAVA'
package org.apache.ratis;

import org.apache.ratis.client.RaftClient;
import org.apache.ratis.client.RaftClientConfigKeys;
import org.apache.ratis.conf.RaftProperties;
import org.apache.ratis.protocol.ClientId;
import org.apache.ratis.protocol.RaftClientReply;
import org.apache.ratis.protocol.RaftClientRequest;
import org.apache.ratis.protocol.RaftPeerId;
import org.apache.ratis.retry.RetryPolicies;
import org.apache.ratis.rpc.CallId;
import org.apache.ratis.server.RaftServer;
import org.apache.ratis.server.RaftServerConfigKeys;
import org.apache.ratis.server.impl.BlockRequestHandlingInjection;
import org.apache.ratis.server.impl.RaftServerTestUtil;
import org.apache.ratis.server.leader.LogAppender;
import org.apache.ratis.server.simulation.MiniRaftClusterWithSimulatedRpc;
import org.apache.ratis.util.JavaUtils;
import org.apache.ratis.util.TimeDuration;
import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.Timeout;

import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

public class TestBugMC2OldLeaderLeaseRead extends BaseTest {
  private enum Level {
    LEVEL0,
    LEVEL1,
    LEVEL3
  }

  private static final long DELAY_MS = Long.getLong("mc2.delay.notleader.ms", 6000L);

  @Test
  @Timeout(180)
  public void testOldLeaderLeaseReadRace() throws Exception {
    final Level level = Level.valueOf(System.getProperty("mc2.level", "LEVEL1"));
    if (level == Level.LEVEL0) {
      runLevel0();
      return;
    }

    AttemptResult last = null;
    final int attempts = level == Level.LEVEL3 ? 6 : 4;
    for (int i = 1; i <= attempts; i++) {
      last = runPartitionAttempt(level, i);
      System.out.println(last);
      if (last.staleReadObserved) {
        break;
      }
    }

    Assertions.assertNotNull(last, "test did not run");
    System.out.println("MC2_FINAL level=" + level + " last=\"" + last + "\"");
  }

  private void runLevel0() throws Exception {
    final RaftProperties properties = newProperties();
    try (MiniRaftClusterWithSimulatedRpc cluster = MiniRaftClusterWithSimulatedRpc.FACTORY.newCluster(3, properties)) {
      cluster.start();
      final RaftServer.Division leader = RaftTestUtil.waitForLeader(cluster);
      final RaftPeerId leaderId = leader.getId();
      try (RaftClient client = cluster.createClient(leaderId, RetryPolicies.noRetry())) {
        ReadOnlyRequestTests.assertReplyExact(1, client.io().send(ReadOnlyRequestTests.INCREMENT));
        assertDirectReadExact(cluster, leaderId, 1);
        final RaftClientReply transfer = client.admin().transferLeadership(null, 200);
        System.out.println("MC2_LEVEL0 transferSuccess=" + transfer.isSuccess());
      }

      String outcome = "NO_STALE";
      try {
        final RaftClientReply reply = submitDirectRead(cluster, leaderId);
        outcome = reply.isSuccess() ? "UNEXPECTED_SUCCESS value=" + ReadOnlyRequestTests.retrieve(reply)
            : "FAILED_REPLY exception=" + reply.getException();
      } catch (Throwable t) {
        outcome = "EXCEPTION " + t.getClass().getSimpleName() + ": " + t.getMessage();
      }
      System.out.println("MC2_LEVEL0 result=NO_STALE oldLeaderReadOutcome=" + outcome);
    } finally {
      BlockRequestHandlingInjection.getInstance().unblockAll();
    }
  }

  private AttemptResult runPartitionAttempt(Level level, int attempt) throws Exception {
    final RaftProperties properties = newProperties();
    try (MiniRaftClusterWithSimulatedRpc cluster = MiniRaftClusterWithSimulatedRpc.FACTORY.newCluster(3, properties)) {
      cluster.start();
      final RaftServer.Division oldLeader = RaftTestUtil.waitForLeader(cluster);
      final RaftPeerId oldLeaderId = oldLeader.getId();
      try (RaftClient oldLeaderClient = cluster.createClient(oldLeaderId, RetryPolicies.noRetry())) {
        ReadOnlyRequestTests.assertReplyExact(1, oldLeaderClient.io().send(ReadOnlyRequestTests.INCREMENT));
        assertDirectReadExact(cluster, oldLeaderId, 1);
      }
      JavaUtils.attempt(() -> RaftServerTestUtil.assertLeaderLease(oldLeader, true),
          20, HUNDRED_MILLIS, "old leader lease is initially valid", LOG);

      isolateServerRpc(cluster, oldLeaderId, true);
      final boolean leaseExpired = waitForLeaderLease(oldLeader, false, 2500L);
      final RaftServer.Division newLeader = waitForOtherLeader(cluster, oldLeaderId, 8000L);
      if (newLeader == null) {
        return new AttemptResult(level, attempt, false, false, leaseExpired, oldLeader.getInfo().getCurrentRole().name(),
            null, false, -1, -1, "no replacement leader before old leader stepdown window");
      }
      final RaftPeerId newLeaderId = newLeader.getId();
      try (RaftClient newLeaderClient = cluster.createClient(newLeaderId, RetryPolicies.noRetry())) {
        ReadOnlyRequestTests.assertReplyExact(2, newLeaderClient.io().send(ReadOnlyRequestTests.INCREMENT));
        assertDirectReadExact(cluster, newLeaderId, 2);
      }

      if (!oldLeader.getInfo().isLeader()) {
        return new AttemptResult(level, attempt, false, true, leaseExpired, oldLeader.getInfo().getCurrentRole().name(),
            newLeaderId.toString(), false, -1, -1, "old leader stepped down before NOT_LEADER reply race");
      }

      final Path marker = markerPath(level);
      if (marker != null) {
        Files.deleteIfExists(marker);
      }
      allowOutgoingToReceiveNotLeaderReply(cluster, oldLeaderId);
      RaftServerTestUtil.getLogAppenders(oldLeader).forEach(LogAppender::triggerHeartbeat);

      final boolean markerObserved = marker != null && waitForMarker(marker, 5000L);
      final ReadAttempt read = readOldLeaderUntilStale(cluster, oldLeaderId,
          level == Level.LEVEL3 ? DELAY_MS - 500L : 1500L);
      Thread.sleep(level == Level.LEVEL3 ? DELAY_MS + 500L : 500L);
      final String finalRole = oldLeader.getInfo().getCurrentRole().name();
      return new AttemptResult(level, attempt, read.stale, true, leaseExpired, finalRole, newLeaderId.toString(),
          markerObserved, read.attempts, read.value, read.detail);
    } finally {
      isolateServerRpc(clusterOrNull(), null, false);
      BlockRequestHandlingInjection.getInstance().unblockAll();
    }
  }

  private static MiniRaftClusterWithSimulatedRpc clusterOrNull() {
    return null;
  }

  private static RaftClientReply submitDirectRead(MiniRaftClusterWithSimulatedRpc cluster, RaftPeerId serverId)
      throws Exception {
    final RaftClientRequest request = RaftClientRequest.newBuilder()
        .setClientId(ClientId.randomId())
        .setServerId(serverId)
        .setGroupId(cluster.getGroupId())
        .setCallId(CallId.getAndIncrement())
        .setMessage(ReadOnlyRequestTests.QUERY)
        .setType(RaftClientRequest.readRequestType())
        .build();
    final RaftServer server = cluster.getServer(serverId);
    return server.submitClientRequestAsync(request).get(3, TimeUnit.SECONDS);
  }

  private static void assertDirectReadExact(MiniRaftClusterWithSimulatedRpc cluster, RaftPeerId serverId, int expected)
      throws Exception {
    ReadOnlyRequestTests.assertReplyExact(expected, submitDirectRead(cluster, serverId));
  }

  private ReadAttempt readOldLeaderUntilStale(MiniRaftClusterWithSimulatedRpc cluster, RaftPeerId oldLeaderId,
      long windowMs) throws Exception {
    final long deadline = System.currentTimeMillis() + Math.max(100L, windowMs);
    int attempts = 0;
    String first = null;
    String last = "not attempted";
    while (System.currentTimeMillis() < deadline) {
      attempts++;
      try {
        final RaftClientReply reply = submitDirectRead(cluster, oldLeaderId);
        if (reply.isSuccess()) {
          final int value = ReadOnlyRequestTests.retrieve(reply);
          last = "SUCCESS value=" + value;
          if (first == null) {
            first = last;
          }
          if (value == 1) {
            return new ReadAttempt(true, attempts, value, "first=" + first + "; last=" + last);
          }
        } else {
          last = "FAILED_REPLY exception=" + reply.getException();
          if (first == null) {
            first = last;
          }
        }
      } catch (Throwable t) {
        last = "EXCEPTION " + t.getClass().getSimpleName() + ": " + t.getMessage();
        if (first == null) {
          first = last;
        }
      }
      Thread.sleep(25L);
    }
    return new ReadAttempt(false, attempts, -1, "first=" + first + "; last=" + last);
  }

  private static Path markerPath(Level level) {
    final String file = System.getProperty("mc2.marker.file");
    return level == Level.LEVEL3 && file != null ? Paths.get(file) : null;
  }

  private static boolean waitForMarker(Path marker, long timeoutMs) throws InterruptedException {
    final long deadline = System.currentTimeMillis() + timeoutMs;
    while (System.currentTimeMillis() < deadline) {
      if (Files.exists(marker)) {
        return true;
      }
      Thread.sleep(25L);
    }
    return false;
  }

  private static boolean waitForLeaderLease(RaftServer.Division leader, boolean expected, long timeoutMs)
      throws InterruptedException {
    final long deadline = System.currentTimeMillis() + timeoutMs;
    while (System.currentTimeMillis() < deadline) {
      try {
        RaftServerTestUtil.assertLeaderLease(leader, expected);
        return true;
      } catch (AssertionError ignored) {
        Thread.sleep(25L);
      }
    }
    return false;
  }

  private static RaftServer.Division waitForOtherLeader(MiniRaftClusterWithSimulatedRpc cluster, RaftPeerId oldLeader,
      long timeoutMs) throws InterruptedException {
    final long deadline = System.currentTimeMillis() + timeoutMs;
    while (System.currentTimeMillis() < deadline) {
      for (RaftServer.Division server : cluster.iterateDivisions()) {
        if (!server.getId().equals(oldLeader) && server.getInfo().isLeaderReady()) {
          return server;
        }
      }
      Thread.sleep(50L);
    }
    return null;
  }

  private static void isolateServerRpc(MiniRaftClusterWithSimulatedRpc cluster, RaftPeerId id, boolean isolate) {
    if (id == null) {
      return;
    }
    if (isolate) {
      BlockRequestHandlingInjection.getInstance().blockReplier(id.toString());
      setBlockSendRequestTo(cluster, id, true);
      cluster.setBlockRequestsFrom(id.toString(), true);
    } else {
      BlockRequestHandlingInjection.getInstance().unblockReplier(id.toString());
      if (cluster != null) {
        setBlockSendRequestTo(cluster, id, false);
        cluster.setBlockRequestsFrom(id.toString(), false);
      }
    }
  }

  private static void allowOutgoingToReceiveNotLeaderReply(MiniRaftClusterWithSimulatedRpc cluster, RaftPeerId id) {
    BlockRequestHandlingInjection.getInstance().unblockRequestor(id.toString());
    cluster.setBlockRequestsFrom(id.toString(), false);
    BlockRequestHandlingInjection.getInstance().blockReplier(id.toString());
    setBlockSendRequestTo(cluster, id, true);
  }

  private static void setBlockSendRequestTo(MiniRaftClusterWithSimulatedRpc cluster, RaftPeerId id, boolean block) {
    if (cluster == null || id == null) {
      return;
    }
    try {
      final Field requestReplyField = MiniRaftClusterWithSimulatedRpc.class.getDeclaredField("serverRequestReply");
      requestReplyField.setAccessible(true);
      final Object requestReply = requestReplyField.get(cluster);
      final Method getQueue = requestReply.getClass().getDeclaredMethod("getQueue", String.class);
      getQueue.setAccessible(true);
      final Object queue = getQueue.invoke(requestReply, id.toString());
      final Field blockSendRequestToField = queue.getClass().getDeclaredField("blockSendRequestTo");
      blockSendRequestToField.setAccessible(true);
      ((AtomicBoolean) blockSendRequestToField.get(queue)).set(block);
    } catch (ReflectiveOperationException e) {
      throw new IllegalStateException("Failed to set simulated blockSendRequestTo for " + id, e);
    }
  }

  private static RaftProperties newProperties() {
    final RaftProperties properties = new RaftProperties();
    ReadOnlyRequestTests.CounterStateMachine.setProperties(properties);
    RaftServerConfigKeys.Read.setOption(properties, RaftServerConfigKeys.Read.Option.LINEARIZABLE);
    RaftServerConfigKeys.Read.setLeaderLeaseEnabled(properties, true);
    RaftServerConfigKeys.Read.ReadIndex.setType(properties, RaftServerConfigKeys.Read.ReadIndex.Type.COMMIT_INDEX);
    RaftServerConfigKeys.Rpc.setTimeoutMin(properties, TimeDuration.valueOf(300, TimeUnit.MILLISECONDS));
    RaftServerConfigKeys.Rpc.setTimeoutMax(properties, TimeDuration.valueOf(900, TimeUnit.MILLISECONDS));
    RaftServerConfigKeys.Rpc.setRequestTimeout(properties, TimeDuration.valueOf(2, TimeUnit.SECONDS));
    RaftClientConfigKeys.Rpc.setRequestTimeout(properties, TimeDuration.valueOf(2, TimeUnit.SECONDS));
    properties.setInt("org.apache.ratis.server.simulation.SimulatedRequestReply.simulateLatencyMs", 0);
    return properties;
  }

  private static final class ReadAttempt {
    private final boolean stale;
    private final int attempts;
    private final int value;
    private final String detail;

    private ReadAttempt(boolean stale, int attempts, int value, String detail) {
      this.stale = stale;
      this.attempts = attempts;
      this.value = value;
      this.detail = detail;
    }
  }

  private static final class AttemptResult {
    private final Level level;
    private final int attempt;
    private final boolean staleReadObserved;
    private final boolean replacementLeaderObserved;
    private final boolean oldLeaseExpiredBeforeReplacement;
    private final String oldLeaderFinalRole;
    private final String newLeaderId;
    private final boolean notLeaderTimestampObserved;
    private final int readAttempts;
    private final int staleValue;
    private final String detail;

    private AttemptResult(Level level, int attempt, boolean staleReadObserved, boolean replacementLeaderObserved,
        boolean oldLeaseExpiredBeforeReplacement, String oldLeaderFinalRole, String newLeaderId,
        boolean notLeaderTimestampObserved, int readAttempts, int staleValue, String detail) {
      this.level = level;
      this.attempt = attempt;
      this.staleReadObserved = staleReadObserved;
      this.replacementLeaderObserved = replacementLeaderObserved;
      this.oldLeaseExpiredBeforeReplacement = oldLeaseExpiredBeforeReplacement;
      this.oldLeaderFinalRole = oldLeaderFinalRole;
      this.newLeaderId = newLeaderId;
      this.notLeaderTimestampObserved = notLeaderTimestampObserved;
      this.readAttempts = readAttempts;
      this.staleValue = staleValue;
      this.detail = detail;
    }

    @Override
    public String toString() {
      return "MC2_RESULT level=" + level
          + " attempt=" + attempt
          + " staleReadObserved=" + staleReadObserved
          + " replacementLeaderObserved=" + replacementLeaderObserved
          + " oldLeaseExpiredBeforeReplacement=" + oldLeaseExpiredBeforeReplacement
          + " oldLeaderFinalRole=" + oldLeaderFinalRole
          + " newLeaderId=" + newLeaderId
          + " notLeaderTimestampObserved=" + notLeaderTimestampObserved
          + " readAttempts=" + readAttempts
          + " staleValue=" + staleValue
          + " detail=\"" + detail + "\"";
    }
  }
}
JAVA

run_mvn() {
  local level="$1"
  shift || true
  echo "===== RUN $level ====="
  (
    cd "$ROOT"
    timeout 10m ./mvnw -pl ratis-server -am -DskipRat -DskipCheckstyle -DskipSpotbugs \
      -Dsurefire.failIfNoSpecifiedTests=false -DfailIfNoTests=false \
      -Dtest=org.apache.ratis.TestBugMC2OldLeaderLeaseRead#testOldLeaderLeaseReadRace \
      -Dmc2.level="$level" "$@" test
  )
}

{
  echo "MC2_REPRO_START $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "ROOT=$ROOT"
  echo "HEAD=$(git -C "$ROOT" rev-parse HEAD)"

  if run_mvn LEVEL0; then
    echo "LEVEL0_COMMAND_STATUS=0"
  else
    echo "LEVEL0_COMMAND_STATUS=$?"
  fi

  if run_mvn LEVEL1; then
    echo "LEVEL1_COMMAND_STATUS=0"
  else
    echo "LEVEL1_COMMAND_STATUS=$?"
  fi

  cp "$SOURCE" "$BACKUP"
  if ! grep -q 'MC2_PATCH_DELAY_AFTER_NOT_LEADER_TIMESTAMP' "$SOURCE"; then
    perl -0pi -e 's/(getFollower\(\)\.updateLastRespondedAppendEntriesSendTime\(sendTime\);\n)/$1        if (reply.getResult() == AppendEntriesReplyProto.AppendResult.NOT_LEADER) {\n          final long delayMs = Long.getLong("mc2.delay.notleader.ms", 0L);\n          if (delayMs > 0L) {\n            final String markerFile = System.getProperty("mc2.marker.file");\n            if (markerFile != null) {\n              java.nio.file.Files.write(java.nio.file.Paths.get(markerFile),\n                  ("NOT_LEADER peer=" + getFollowerId()).getBytes(java.nio.charset.StandardCharsets.UTF_8));\n            }\n            System.out.println("MC2_PATCH_DELAY_AFTER_NOT_LEADER_TIMESTAMP delayMs=" + delayMs + " peer=" + getFollowerId());\n            System.out.flush();\n            Thread.sleep(delayMs);\n          }\n        }\n/s' "$SOURCE"
  fi
  echo "LEVEL3_PATCH=delay_after_updateLastRespondedAppendEntriesSendTime_for_NOT_LEADER"

  rm -f "$OUT_DIR/test_bugMC-2_notleader_marker"
  if run_mvn LEVEL3 -Dmc2.delay.notleader.ms=6000 -Dmc2.marker.file="$OUT_DIR/test_bugMC-2_notleader_marker"; then
    echo "LEVEL3_COMMAND_STATUS=0"
  else
    echo "LEVEL3_COMMAND_STATUS=$?"
  fi
  echo "MC2_REPRO_END $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} | tee "$OUT"

echo "MC2_REPRO_OUTPUT=$OUT"
