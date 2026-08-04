#!/usr/bin/env bash
set -euo pipefail

WORKTREE="/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-system-20260803/ratis-system/.specula-output/confirmation/MC-1/worktree"
FINDING_DIR="/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-system-20260803/ratis-system/.specula-output/confirmation/MC-1"
TEST_SRC="$WORKTREE/ratis-test/src/test/java/org/apache/ratis/server/impl/TestBugMC1StaleAppendSuccessWithGrpc.java"
LOG_FILE="$FINDING_DIR/repro-MC-1.log"

if ! command -v rg >/dev/null 2>&1; then
  echo "ERROR: rg is required by this reproduction script" >&2
  exit 2
fi

if ! rg -q "APPEND_ENTRIES_BEFORE_APPEND_LOG" "$WORKTREE/ratis-server/src/main/java/org/apache/ratis/server/impl/RaftServerImpl.java"; then
  echo "ERROR: missing MC-1 test timing hook APPEND_ENTRIES_BEFORE_APPEND_LOG" >&2
  exit 2
fi

if ! rg -q "REQUEST_VOTE_AFTER_GRANT" "$WORKTREE/ratis-server/src/main/java/org/apache/ratis/server/impl/RaftServerImpl.java"; then
  echo "ERROR: missing MC-1 test timing hook REQUEST_VOTE_AFTER_GRANT" >&2
  exit 2
fi

mkdir -p "$(dirname "$TEST_SRC")"

cat > "$TEST_SRC" <<'JAVA'
/*
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package org.apache.ratis.server.impl;

import org.apache.ratis.BaseTest;
import org.apache.ratis.RaftTestUtil;
import org.apache.ratis.client.RaftClient;
import org.apache.ratis.conf.RaftProperties;
import org.apache.ratis.grpc.GrpcConfigKeys;
import org.apache.ratis.grpc.MiniRaftClusterWithGrpc;
import org.apache.ratis.proto.RaftProtos.LogEntryProto;
import org.apache.ratis.protocol.RaftClientReply;
import org.apache.ratis.protocol.RaftPeerId;
import org.apache.ratis.retry.RetryPolicies;
import org.apache.ratis.server.RaftServer;
import org.apache.ratis.server.RaftServerConfigKeys;
import org.apache.ratis.server.protocol.TermIndex;
import org.apache.ratis.server.raftlog.RaftLog;
import org.apache.ratis.statemachine.StateMachine;
import org.apache.ratis.statemachine.impl.SimpleStateMachine4Testing;
import org.apache.ratis.thirdparty.com.google.protobuf.ByteString;
import org.apache.ratis.util.CodeInjectionForTesting;
import org.apache.ratis.util.JavaUtils;
import org.apache.ratis.util.TimeDuration;
import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.Timeout;

import java.util.List;
import java.util.Objects;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

import static org.apache.ratis.RaftTestUtil.waitForLeader;

public class TestBugMC1StaleAppendSuccessWithGrpc extends BaseTest
    implements MiniRaftClusterWithGrpc.FactoryGet {
  {
    final RaftProperties properties = getProperties();
    properties.setClass(MiniRaftCluster.STATEMACHINE_CLASS_KEY,
        SimpleStateMachine4Testing.class, StateMachine.class);
    GrpcConfigKeys.Server.setHeartbeatChannel(properties, false);
    RaftServerConfigKeys.Rpc.setTimeoutMin(properties, TimeDuration.valueOf(150, TimeUnit.MILLISECONDS));
    RaftServerConfigKeys.Rpc.setTimeoutMax(properties, TimeDuration.valueOf(300, TimeUnit.MILLISECONDS));
    RaftServerConfigKeys.Rpc.setRequestTimeout(properties, TimeDuration.valueOf(10, TimeUnit.SECONDS));
    RaftServerConfigKeys.LeaderElection.setLeaderStepDownWaitTime(properties, TimeDuration.valueOf(60, TimeUnit.SECONDS));
  }

  @Test
  @Timeout(90)
  public void staleAppendSuccessCanCommitAfterHigherTermVote() throws Exception {
    runWithNewCluster(3, this::runStaleAppendSuccessCanCommitAfterHigherTermVote);
  }

  private void runStaleAppendSuccessCanCommitAfterHigherTermVote(MiniRaftClusterWithGrpc cluster) throws Exception {
    BlockRequestHandlingInjection.getInstance().unblockAll();
    final RaftServer.Division oldLeader = waitForLeader(cluster);
    final RaftPeerId oldLeaderId = oldLeader.getId();
    final long oldTerm = oldLeader.getInfo().getCurrentTerm();
    final List<RaftServer.Division> followers = cluster.getFollowers();
    Assertions.assertEquals(2, followers.size(), "expected two followers in a 3-node cluster");

    final RaftServer.Division candidate = followers.get(0);
    final RaftPeerId candidateId = candidate.getId();
    final RaftServer.Division target = followers.get(1);
    final RaftPeerId targetId = target.getId();

    final RaftTestUtil.SimpleMessage message = new RaftTestUtil.SimpleMessage(
        "MC1-stale-success-" + oldTerm + "-" + System.nanoTime());
    final BeforeAppendBlocker appendBlocker = new BeforeAppendBlocker(targetId, oldLeaderId, message.getContent());
    final AfterGrantBlocker voteBlocker = new AfterGrantBlocker(targetId, candidateId);

    CodeInjectionForTesting.put(RaftServerImpl.APPEND_ENTRIES_BEFORE_APPEND_LOG, appendBlocker);
    CodeInjectionForTesting.put(RaftServerImpl.REQUEST_VOTE_AFTER_GRANT, voteBlocker);

    try (RaftClient oldLeaderClient = cluster.createClient(oldLeaderId, RetryPolicies.noRetry())) {
      BlockRequestHandlingInjection.getInstance().blockReplier(candidateId.toString());

      final CompletableFuture<RaftClientReply> replyFuture = oldLeaderClient.async().send(message);
      Assertions.assertTrue(appendBlocker.awaitBlocked(30, TimeUnit.SECONDS),
          "target follower did not reach the accepted-before-RaftLog-append window");
      final TermIndex blockedEntry = Objects.requireNonNull(appendBlocker.getBlockedEntry(),
          "blocked append did not expose a term/index");

      JavaUtils.attempt(() -> Assertions.assertTrue(containsMessage(oldLeader, message),
          "old leader has not locally appended the client entry yet"),
          30, HUNDRED_MILLIS, "old leader contains client entry", LOG);
      Assertions.assertFalse(containsMessage(candidate, message),
          "candidate unexpectedly received the old leader's client entry");
      Assertions.assertFalse(containsMessage(target, message),
          "target should not contain the entry before the blocked append is released");

      BlockRequestHandlingInjection.getInstance().blockRequestor(targetId.toString());
      BlockRequestHandlingInjection.getInstance().blockRequestor(oldLeaderId.toString());
      BlockRequestHandlingInjection.getInstance().blockReplier(oldLeaderId.toString());

      Assertions.assertTrue(voteBlocker.awaitGranted(30, TimeUnit.SECONDS),
          "target follower did not grant a higher-term vote to the candidate");
      Assertions.assertEquals(candidateId, ((RaftServerImpl) target).getState().getVotedFor(),
          "target did not persist its vote for the candidate");
      Assertions.assertTrue(target.getInfo().getCurrentTerm() > oldTerm,
          "target did not move to a higher term before completing the old append");

      appendBlocker.release();
      JavaUtils.attempt(() -> Assertions.assertTrue(containsMessage(target, message),
          "target did not append the old leader entry after release"),
          30, HUNDRED_MILLIS, "target contains old leader entry", LOG);
      final boolean targetContainsEntryBeforeNewLeader = containsMessage(target, message);

      voteBlocker.release();
      JavaUtils.attempt(() -> Assertions.assertTrue(candidate.getInfo().isLeader(),
          "candidate has not become leader; role=" + candidate.getInfo().getCurrentRole()
              + ", term=" + candidate.getInfo().getCurrentTerm()),
          150, HUNDRED_MILLIS, "candidate becomes new leader", LOG);

      final RaftClientReply reply = replyFuture.get(30, TimeUnit.SECONDS);
      Assertions.assertTrue(reply.isSuccess(), "old leader client write was not reported as success: " + reply);
      JavaUtils.attempt(() -> Assertions.assertTrue(
          oldLeader.getRaftLog().getLastCommittedIndex() >= blockedEntry.getIndex(),
          "old leader did not advance commit index to the stale-success entry"),
          30, HUNDRED_MILLIS, "old leader commits stale-success entry", LOG);
      Assertions.assertFalse(containsMessage(candidate, message),
          "new leader unexpectedly contains the old leader's committed entry");

      System.out.println("MC-1 trigger reached");
      System.out.println("oldLeader=" + oldLeaderId + " oldTerm=" + oldTerm);
      System.out.println("candidateNewLeader=" + candidateId + " term=" + candidate.getInfo().getCurrentTerm());
      System.out.println("targetVotedFor=" + ((RaftServerImpl) target).getState().getVotedFor()
          + " targetTerm=" + target.getInfo().getCurrentTerm());
      System.out.println("blockedEntry=" + blockedEntry);
      System.out.println("oldLeaderReplySuccess=" + reply.isSuccess()
          + " replyLogIndex=" + reply.getLogIndex() + " replier=" + reply.getReplierId());
      System.out.println("oldLeaderCommittedIndex=" + oldLeader.getRaftLog().getLastCommittedIndex());
      System.out.println("newLeaderContainsEntry=" + containsMessage(candidate, message));
      System.out.println("targetContainsEntryBeforeNewLeader=" + targetContainsEntryBeforeNewLeader);
      System.out.println("targetContainsEntryAfterNewLeaderSync=" + containsMessage(target, message));
    } finally {
      appendBlocker.release();
      voteBlocker.release();
      CodeInjectionForTesting.remove(RaftServerImpl.APPEND_ENTRIES_BEFORE_APPEND_LOG);
      CodeInjectionForTesting.remove(RaftServerImpl.REQUEST_VOTE_AFTER_GRANT);
      BlockRequestHandlingInjection.getInstance().unblockAll();
    }
  }

  private static boolean containsMessage(RaftServer.Division server, RaftTestUtil.SimpleMessage message)
      throws Exception {
    final RaftLog log = server.getRaftLog();
    final TermIndex last = log.getLastEntryTermIndex();
    if (last == null) {
      return false;
    }
    final long start = Math.max(RaftLog.LEAST_VALID_LOG_INDEX, log.getStartIndex());
    for (long index = start; index <= last.getIndex(); index++) {
      final LogEntryProto entry = log.get(index);
      if (entry != null && entry.hasStateMachineLogEntry()
          && message.getContent().equals(entry.getStateMachineLogEntry().getLogData())) {
        return true;
      }
    }
    return false;
  }

  private static final class BeforeAppendBlocker implements CodeInjectionForTesting.Code {
    private final RaftPeerId targetId;
    private final RaftPeerId oldLeaderId;
    private final ByteString payload;
    private final AtomicBoolean blockedOnce = new AtomicBoolean();
    private final CountDownLatch blocked = new CountDownLatch(1);
    private final CountDownLatch release = new CountDownLatch(1);
    private final AtomicReference<TermIndex> blockedEntry = new AtomicReference<>();

    private BeforeAppendBlocker(RaftPeerId targetId, RaftPeerId oldLeaderId, ByteString payload) {
      this.targetId = targetId;
      this.oldLeaderId = oldLeaderId;
      this.payload = payload;
    }

    @Override
    public boolean execute(Object localId, Object remoteId, Object... args) {
      if (!targetId.toString().equals(String.valueOf(localId))
          || !oldLeaderId.toString().equals(String.valueOf(remoteId))
          || !blockedOnce.compareAndSet(false, true)) {
        return false;
      }
      if (args.length < 2 || !(args[1] instanceof List)) {
        blockedOnce.set(false);
        return false;
      }
      @SuppressWarnings("unchecked")
      final List<LogEntryProto> entries = (List<LogEntryProto>) args[1];
      final LogEntryProto targetEntry = entries.stream()
          .filter(e -> e.hasStateMachineLogEntry()
              && payload.equals(e.getStateMachineLogEntry().getLogData()))
          .findFirst()
          .orElse(null);
      if (targetEntry == null) {
        blockedOnce.set(false);
        return false;
      }

      blockedEntry.set(TermIndex.valueOf(targetEntry));
      blocked.countDown();
      try {
        if (!release.await(30, TimeUnit.SECONDS)) {
          throw new AssertionError("timed out waiting to release old-leader append");
        }
      } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
        throw new AssertionError("interrupted while blocking old-leader append", e);
      }
      return true;
    }

    boolean awaitBlocked(long timeout, TimeUnit unit) throws InterruptedException {
      return blocked.await(timeout, unit);
    }

    TermIndex getBlockedEntry() {
      return blockedEntry.get();
    }

    void release() {
      release.countDown();
    }
  }

  private static final class AfterGrantBlocker implements CodeInjectionForTesting.Code {
    private final RaftPeerId targetId;
    private final RaftPeerId candidateId;
    private final AtomicBoolean blockedOnce = new AtomicBoolean();
    private final CountDownLatch granted = new CountDownLatch(1);
    private final CountDownLatch release = new CountDownLatch(1);

    private AfterGrantBlocker(RaftPeerId targetId, RaftPeerId candidateId) {
      this.targetId = targetId;
      this.candidateId = candidateId;
    }

    @Override
    public boolean execute(Object localId, Object remoteId, Object... args) {
      if (!targetId.toString().equals(String.valueOf(localId))
          || !candidateId.toString().equals(String.valueOf(remoteId))
          || !blockedOnce.compareAndSet(false, true)) {
        return false;
      }

      granted.countDown();
      try {
        if (!release.await(30, TimeUnit.SECONDS)) {
          throw new AssertionError("timed out waiting to release higher-term vote reply");
        }
      } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
        throw new AssertionError("interrupted while blocking higher-term vote reply", e);
      }
      return true;
    }

    boolean awaitGranted(long timeout, TimeUnit unit) throws InterruptedException {
      return granted.await(timeout, unit);
    }

    void release() {
      release.countDown();
    }
  }
}
JAVA

cd "$WORKTREE"
MVN="./mvnw"
if [ ! -x "$MVN" ]; then
  MVN="mvn"
fi

echo "Running MC-1 reproduction at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
set +e
timeout 30m "$MVN" -pl ratis-test -am \
  -Dtest=org.apache.ratis.server.impl.TestBugMC1StaleAppendSuccessWithGrpc#staleAppendSuccessCanCommitAfterHigherTermVote \
  -DfailIfNoTests=false \
  -Dcheckstyle.skip=true \
  -Drat.skip=true \
  test 2>&1 | tee "$LOG_FILE"
STATUS=${PIPESTATUS[0]}
set -e

echo "MC-1 reproduction exit_status=$STATUS"
echo "MC-1 reproduction log=$LOG_FILE"
exit "$STATUS"
