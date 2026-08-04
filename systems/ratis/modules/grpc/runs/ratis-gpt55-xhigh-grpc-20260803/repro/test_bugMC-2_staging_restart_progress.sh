#!/usr/bin/env bash
set -euo pipefail

WORKTREE="/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-grpc-20260803/ratis-grpc/.specula-output/confirmation/MC-2/worktree"
REPRO_DIR="/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-grpc-20260803/ratis-grpc/.specula-output/repro"
TRACE_DIR="${REPRO_DIR}/MC-2-traces"
TEST_SRC="${WORKTREE}/ratis-test/src/test/java/org/apache/ratis/grpc/TestSpeculaMC2StagingRestartProgress.java"
TMP_DIR="/home/ubuntu/specula-ratis-issue123-20260803/tmp/grpc"

mkdir -p "${TRACE_DIR}" "${TMP_DIR}"
rm -f "${TRACE_DIR}"/mc2-*.ndjson

cleanup() {
  rm -f "${TEST_SRC}"
}
trap cleanup EXIT

cat > "${TEST_SRC}" <<'JAVA'
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
package org.apache.ratis.grpc;

import org.apache.ratis.BaseTest;
import org.apache.ratis.RaftTestUtil;
import org.apache.ratis.client.RaftClient;
import org.apache.ratis.client.RaftClientConfigKeys;
import org.apache.ratis.conf.RaftProperties;
import org.apache.ratis.protocol.RaftClientReply;
import org.apache.ratis.protocol.RaftGroupId;
import org.apache.ratis.protocol.RaftPeerId;
import org.apache.ratis.server.RaftServer;
import org.apache.ratis.server.RaftServerConfigKeys;
import org.apache.ratis.server.impl.MiniRaftCluster;
import org.apache.ratis.server.impl.PeerChanges;
import org.apache.ratis.server.impl.RaftServerTestUtil;
import org.apache.ratis.server.leader.LogAppender;
import org.apache.ratis.server.protocol.TermIndex;
import org.apache.ratis.server.raftlog.RaftLog;
import org.apache.ratis.server.storage.FileInfo;
import org.apache.ratis.server.storage.RaftStorage;
import org.apache.ratis.specula.RatisGrpcTrace;
import org.apache.ratis.statemachine.SnapshotInfo;
import org.apache.ratis.statemachine.StateMachine;
import org.apache.ratis.statemachine.impl.FileListSnapshotInfo;
import org.apache.ratis.statemachine.impl.SimpleStateMachine4Testing;
import org.apache.ratis.util.FileUtils;
import org.apache.ratis.util.LifeCycle;
import org.apache.ratis.util.SizeInBytes;
import org.apache.ratis.util.TimeDuration;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.MethodOrderer;
import org.junit.jupiter.api.Order;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestMethodOrder;
import org.junit.jupiter.api.Timeout;

import java.io.File;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionException;
import java.util.concurrent.TimeUnit;
import java.util.function.BooleanSupplier;
import java.util.function.Consumer;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Collectors;

import static org.apache.ratis.RaftTestUtil.waitForLeader;

@TestMethodOrder(MethodOrderer.OrderAnnotation.class)
public class TestSpeculaMC2StagingRestartProgress extends BaseTest
    implements MiniRaftClusterWithGrpc.FactoryGet {
  private static final int SNAPSHOT_TRIGGER_THRESHOLD = 8;
  private static final int SNAPSHOT_PURGE_GAP = 1;
  private static final Pattern FOLLOWER_PATTERN = Pattern.compile("\\\"follower\\\":\\\"([^\\\"]+)\\\"");
  private static final Pattern EVENT_PATTERN = Pattern.compile("\\\"event\\\":\\\"([^\\\"]+)\\\"");

  @AfterEach
  public void closeTrace() {
    RatisGrpcTrace.close();
  }

  @Test
  @Order(1)
  @Timeout(240)
  public void level0SnapshotStagingWithoutAppenderRestartCompletes() throws Exception {
    MiniRaftClusterWithGrpc cluster = null;
    try {
      cluster = newSnapshotCluster();
      cluster.start();
      final RaftServer.Division leader = startTrace(cluster, "mc2-level0-no-restart");
      final RaftPeerId leaderId = leader.getId();

      createLeaderSnapshot(cluster, leaderId);
      final PeerChanges change = cluster.addNewPeers(2, true);
      cluster.setConfiguration(change.getPeersInNewConf());
      RaftServerTestUtil.waitAndCheckNewConf(cluster, change.getPeersInNewConf(), 2, 0, null);

      waitForTrace(() -> RatisGrpcTrace.getEventCount("ApplyStagingConfiguration") > 0,
          "level0 ApplyStagingConfiguration", 30_000);
      Assertions.assertEquals(0, RatisGrpcTrace.getEventCount("RestartAppender"));
      System.out.println("MC2_LEVEL0: public setConfiguration + snapshot catch-up completed without restart.");
    } finally {
      shutdown(cluster);
    }
  }

  @Test
  @Order(2)
  @Timeout(300)
  public void level1StagingRestartCannotReachModelReplacementStep() throws Exception {
    MiniRaftClusterWithGrpc cluster = null;
    CompletableFuture<RaftClientReply> setConf = null;
    try {
      cluster = newSnapshotCluster();
      cluster.start();
      RaftServer.Division leader = startTrace(cluster, "mc2-level1-restart-after-progress");
      final RaftPeerId leaderId = leader.getId();

      createLeaderSnapshot(cluster, leaderId);
      leader = waitForLeader(cluster);
      final PeerChanges change = cluster.addNewPeers(2, true);
      setConf = setConfigurationAsync(cluster, leaderId, change);

      waitForTrace(() -> RatisGrpcTrace.getEventCount("SnapshotAttemptForStagingPeer") > 0
              && (RatisGrpcTrace.getEventCount("SnapshotInstalled") > 0
              || RatisGrpcTrace.getEventCount("SnapshotAlreadyInstalled") > 0),
          "snapshot progress for staging peer", 60_000);

      final List<String> beforeRestart = appenderFollowers(leader);
      Assertions.assertFalse(beforeRestart.isEmpty(),
          () -> "Expected staging log appenders before restart; counts=" + RatisGrpcTrace.eventCounts());
      RaftServerTestUtil.restartLogAppenders(leader);
      Thread.sleep(250);
      RatisGrpcTrace.close();

      final List<String> afterRestart = appenderFollowers(leader);
      Assertions.assertEquals(0, RatisGrpcTrace.getEventCount("RestartAppender"),
          () -> "Model replacement step unexpectedly occurred; before=" + beforeRestart
              + ", after=" + afterRestart);
      Assertions.assertFalse(afterRestart.containsAll(beforeRestart),
          () -> "Expected staging appenders not to be recreated from current raft conf; before="
              + beforeRestart + ", after=" + afterRestart);

      System.out.println("MC2_LEVEL1_ATTEMPT: snapshot progress observed before restart; appenders before restart="
          + beforeRestart);
      System.out.println("MC2_LEVEL1_ARTIFACT: restart stopped staging appenders but did not create replacement "
          + "FollowerInfo; appenders after restart=" + afterRestart
          + ", RestartAppender events=" + RatisGrpcTrace.getEventCount("RestartAppender"));
    } finally {
      if (setConf != null) {
        setConf.cancel(true);
      }
      shutdown(cluster);
    }
  }

  private MiniRaftClusterWithGrpc newSnapshotCluster() {
    final RaftProperties properties = new RaftProperties();
    properties.setClass(MiniRaftCluster.STATEMACHINE_CLASS_KEY,
        MultiFileSnapshotStateMachine.class, StateMachine.class);
    GrpcConfigKeys.Server.setHeartbeatChannel(properties, true);
    RaftServerConfigKeys.Snapshot.setAutoTriggerEnabled(properties, true);
    RaftServerConfigKeys.Snapshot.setAutoTriggerThreshold(properties, SNAPSHOT_TRIGGER_THRESHOLD);
    RaftServerConfigKeys.Log.setPurgeGap(properties, SNAPSHOT_PURGE_GAP);
    RaftServerConfigKeys.Log.Appender.setSnapshotChunkSizeMax(properties, SizeInBytes.ONE_KB);
    RaftServerConfigKeys.LeaderElection.setMemberMajorityAdd(properties, true);
    RaftServerConfigKeys.Rpc.setTimeoutMax(properties, TimeDuration.valueOf(500, TimeUnit.MILLISECONDS));
    RaftServerConfigKeys.setStagingTimeout(properties, TimeDuration.valueOf(5, TimeUnit.SECONDS));
    RaftClientConfigKeys.Rpc.setRequestTimeout(properties, TimeDuration.valueOf(30, TimeUnit.SECONDS));
    GrpcConfigKeys.Server.setInstallSnapshotRequestElementLimit(properties, 1);
    return getFactory().newCluster(1, properties);
  }

  private RaftServer.Division startTrace(MiniRaftClusterWithGrpc cluster, String scenario) throws Exception {
    final RaftServer.Division leader = waitForLeader(cluster);
    RatisGrpcTrace.startScenario(scenario);
    RatisGrpcTrace.registerLeader(leader.getId());
    cluster.getFollowers().forEach(follower -> RatisGrpcTrace.registerFollower(follower.getId()));
    return leader;
  }

  private static void createLeaderSnapshot(MiniRaftClusterWithGrpc cluster, RaftPeerId leaderId) throws Exception {
    sendMessages(cluster, leaderId, "snap", SNAPSHOT_TRIGGER_THRESHOLD * 2);
    try (RaftClient client = cluster.createClient(leaderId)) {
      final RaftClientReply snapshotReply = client.getSnapshotManagementApi(leaderId).create(3000);
      Assertions.assertTrue(snapshotReply.isSuccess(), () -> "snapshot create failed: " + snapshotReply);
    }
    Assertions.assertNotNull(waitForLeader(cluster).getStateMachine().getLatestSnapshot());
  }

  private static void sendMessages(MiniRaftClusterWithGrpc cluster, RaftPeerId leaderId, String prefix, int count)
      throws IOException {
    try (RaftClient client = cluster.createClient(leaderId)) {
      for (int i = 0; i < count; i++) {
        Assertions.assertTrue(client.io().send(new RaftTestUtil.SimpleMessage(prefix + "-" + i)).isSuccess());
      }
    }
  }

  private static CompletableFuture<RaftClientReply> setConfigurationAsync(MiniRaftClusterWithGrpc cluster,
      RaftPeerId leaderId, PeerChanges change) {
    return CompletableFuture.supplyAsync(() -> {
      try (RaftClient client = cluster.createClient(leaderId)) {
        return client.admin().setConfiguration(change.getPeersInNewConf());
      } catch (Exception e) {
        throw new CompletionException(e);
      }
    });
  }

  private static void waitForTrace(BooleanSupplier condition, String description, long timeoutMs)
      throws InterruptedException {
    final long deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs);
    while (System.nanoTime() < deadline) {
      if (condition.getAsBoolean()) {
        return;
      }
      Thread.sleep(10);
    }
    Assertions.fail("Timed out waiting for " + description + "; counts=" + RatisGrpcTrace.eventCounts());
  }

  private static Path tracePath(String scenario) {
    return Paths.get(System.getProperty(RatisGrpcTrace.TRACE_DIR_PROPERTY, "target/specula-traces"),
        scenario + ".ndjson");
  }

  private static List<String> appenderFollowers(RaftServer.Division leader) {
    return RaftServerTestUtil.getLogAppenders(leader)
        .map(LogAppender::getFollowerId)
        .map(String::valueOf)
        .collect(Collectors.toList());
  }

  private static SequenceEvidence analyzeSequence(List<String> lines) {
    final Set<String> progressed = new HashSet<>();
    final Set<String> reset = new HashSet<>();
    final SequenceEvidence evidence = new SequenceEvidence();
    for (String line : lines) {
      final String event = field(line, EVENT_PATTERN);
      final String follower = field(line, FOLLOWER_PATTERN);
      if (follower == null) {
        if ("ApplyStagingConfiguration".equals(event) && !reset.isEmpty()) {
          evidence.maskAfterReset = true;
          evidence.maskLine = line;
        }
        continue;
      }
      if (isSnapshotProgress(event) && line.contains("\"snapshotIndex\":")
          && (line.contains("\"matchIndex\":") || line.contains("\"nextIndex\":"))) {
        progressed.add(follower);
      }
      if ("RestartAppender".equals(event) && progressed.contains(follower)
          && line.contains("\"nextIndex\":0") && line.contains("\"matchIndex\":-1")
          && line.contains("\"attemptedSnapshot\":false")) {
        reset.add(follower);
        evidence.resetAfterProgress = true;
        evidence.resetLine = line;
      }
      if (reset.contains(follower) && (isSnapshotProgress(event)
          || ("CheckProgress".equals(event) && line.contains("\"caughtUp\":true")
          && line.contains("\"attemptedSnapshot\":true")))) {
        evidence.maskAfterReset = true;
        evidence.maskLine = line;
      }
    }
    return evidence;
  }

  private static boolean isSnapshotProgress(String event) {
    return "SnapshotInstalled".equals(event) || "SnapshotAlreadyInstalled".equals(event);
  }

  private static String field(String line, Pattern pattern) {
    final Matcher matcher = pattern.matcher(line);
    return matcher.find() ? matcher.group(1) : null;
  }

  private static void shutdown(MiniRaftClusterWithGrpc cluster) {
    if (cluster != null) {
      cluster.shutdown();
    }
  }

  private static final class SequenceEvidence {
    private boolean resetAfterProgress;
    private boolean maskAfterReset;
    private String resetLine;
    private String maskLine;
  }

  public static class MultiFileSnapshotStateMachine extends SimpleStateMachine4Testing {
    private File snapshotRoot;
    private File file1;
    private File file2;

    @Override
    public synchronized void initialize(RaftServer server, RaftGroupId groupId, RaftStorage raftStorage)
        throws IOException {
      super.initialize(server, groupId, raftStorage);
      snapshotRoot = new File(getStateMachineDir(), "snapshot");
      file1 = new File(snapshotRoot, "1.bin");
      file2 = new File(new File(snapshotRoot, "sub"), "2.bin");
    }

    @Override
    public synchronized void pause() {
      if (getLifeCycle().getCurrentState() == LifeCycle.State.RUNNING) {
        getLifeCycle().transition(LifeCycle.State.PAUSING);
        getLifeCycle().transition(LifeCycle.State.PAUSED);
      }
    }

    @Override
    public long takeSnapshot() {
      final TermIndex termIndex = getLastAppliedTermIndex();
      if (termIndex.getTerm() <= 0 || termIndex.getIndex() <= 0) {
        return RaftLog.INVALID_LOG_INDEX;
      }

      try {
        if (!snapshotRoot.exists()) {
          FileUtils.createDirectories(snapshotRoot);
          FileUtils.createDirectories(file1.getParentFile());
          FileUtils.createDirectories(file2.getParentFile());
          FileUtils.newOutputStream(file1, StandardOpenOption.CREATE_NEW).close();
          final byte[] data = new byte[4096];
          Arrays.fill(data, (byte) 0x01);
          try (OutputStream out = FileUtils.newOutputStream(file2, StandardOpenOption.CREATE_NEW)) {
            out.write(data);
          }
        }
      } catch (IOException e) {
        return RaftLog.INVALID_LOG_INDEX;
      }

      return super.takeSnapshot();
    }

    @Override
    public SnapshotInfo getLatestSnapshot() {
      if (snapshotRoot == null || !snapshotRoot.exists() || !file1.exists() || !file2.exists()) {
        return null;
      }
      final SnapshotInfo info = super.getLatestSnapshot();
      if (info == null) {
        return null;
      }
      final List<FileInfo> files = new ArrayList<>();
      files.add(new FileInfo(file1.toPath(), null));
      files.add(new FileInfo(file2.toPath(), null));
      files.add(info.getFiles().get(0));
      return new FileListSnapshotInfo(files, info.getTerm(), info.getIndex());
    }
  }
}
JAVA

export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-"-Djava.io.tmpdir=${TMP_DIR}"}"
cd "${WORKTREE}"

echo "COMMAND: timeout 12m ./mvnw -pl ratis-test -am -DskipShade -DskipRat -Dcheckstyle.skip -Dspotbugs.skip -Dfindbugs.skip -Dtest=TestSpeculaMC2StagingRestartProgress -DfailIfNoTests=false -Dspecula.ratis.grpc.trace.dir=${TRACE_DIR} -Dsurefire.useFile=false test"
timeout 12m ./mvnw -pl ratis-test -am \
  -DskipShade \
  -DskipRat \
  -Dcheckstyle.skip \
  -Dspotbugs.skip \
  -Dfindbugs.skip \
  -Dtest=TestSpeculaMC2StagingRestartProgress \
  -DfailIfNoTests=false \
  -Dspecula.ratis.grpc.trace.dir="${TRACE_DIR}" \
  -Dsurefire.useFile=false \
  test

echo "TRACE_DIR: ${TRACE_DIR}"
for trace in "${TRACE_DIR}"/mc2-*.ndjson; do
  echo "TRACE: ${trace}"
  grep -E '"event":"(AddStagingPeer|SnapshotAttemptForStagingPeer|SnapshotInstalled|SnapshotAlreadyInstalled|RestartAppender|CheckProgress|ApplyStagingConfiguration)"' "${trace}" | sed -n '1,120p'
done
