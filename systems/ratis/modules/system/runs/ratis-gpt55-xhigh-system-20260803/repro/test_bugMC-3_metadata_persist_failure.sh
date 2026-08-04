#!/usr/bin/env bash
set -euo pipefail

REPO="/home/ubuntu/specula-ratis-issue123-20260803/specula/runs/ratis-gpt55-xhigh-system-20260803/ratis-system/.specula-output/confirmation/MC-3/worktree"
TEST_FILE="$REPO/ratis-server/src/test/java/org/apache/ratis/server/impl/TestBugMC3MetadataPersistFailure.java"
REPORT_DIR="$REPO/ratis-server/target/surefire-reports"

cleanup() {
  rm -f "$TEST_FILE"
}
trap cleanup EXIT

mkdir -p "$(dirname "$TEST_FILE")" "$REPO/target/tmp"

cat > "$TEST_FILE" <<'JAVA'
package org.apache.ratis.server.impl;

import org.apache.ratis.BaseTest;
import org.apache.ratis.conf.RaftProperties;
import org.apache.ratis.proto.RaftProtos.AppendEntriesReplyProto;
import org.apache.ratis.proto.RaftProtos.AppendEntriesReplyProto.AppendResult;
import org.apache.ratis.proto.RaftProtos.AppendEntriesRequestProto;
import org.apache.ratis.proto.RaftProtos.RaftGroupIdProto;
import org.apache.ratis.proto.RaftProtos.RaftRpcRequestProto;
import org.apache.ratis.proto.RaftProtos.RequestVoteReplyProto;
import org.apache.ratis.proto.RaftProtos.RequestVoteRequestProto;
import org.apache.ratis.proto.RaftProtos.TermIndexProto;
import org.apache.ratis.protocol.RaftGroup;
import org.apache.ratis.protocol.RaftGroupId;
import org.apache.ratis.protocol.RaftPeer;
import org.apache.ratis.protocol.RaftPeerId;
import org.apache.ratis.server.RaftServerConfigKeys;
import org.apache.ratis.server.RaftServerRpc;
import org.apache.ratis.server.storage.RaftStorage;
import org.apache.ratis.statemachine.impl.BaseStateMachine;
import org.apache.ratis.util.FileUtils;
import org.apache.ratis.util.TimeDuration;
import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;
import org.mockito.Mockito;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.attribute.PosixFilePermission;
import java.util.Arrays;
import java.util.Collections;
import java.util.EnumSet;
import java.util.Properties;
import java.util.Set;
import java.util.concurrent.TimeUnit;

public class TestBugMC3MetadataPersistFailure extends BaseTest {
  private static final RaftPeerId S1 = RaftPeerId.valueOf("s1");
  private static final RaftPeerId S2 = RaftPeerId.valueOf("s2");
  private static final RaftPeerId S3 = RaftPeerId.valueOf("s3");

  @Test
  public void metadataPersistFailureAllowsSameTermAppendToRemainNonDurable() throws Exception {
    final RaftGroup group = RaftGroup.valueOf(RaftGroupId.randomId(), Arrays.asList(peer(S1), peer(S2), peer(S3)));
    final File storageVolume = new File(getTestDir(), "storage");
    FileUtils.deleteFully(storageVolume);
    Files.createDirectories(storageVolume.toPath());

    RaftServerImpl follower = newServer(group, storageVolume, RaftStorage.StartupOption.FORMAT);
    RaftServerImpl restarted = null;
    try {
      follower.start();
      final File currentDir = follower.getRaftStorage().getStorageDir().getCurrentDir();
      final File metaFile = new File(currentDir, "raft-meta");

      final AppendEntriesReplyProto level0 = follower.appendEntries(appendEntries(group, 0, 0));
      Assertions.assertEquals(AppendResult.SUCCESS, level0.getResult());
      Assertions.assertEquals(0L, readPersistedTerm(metaFile));
      System.out.println("MC3_LEVEL0_CONTROL result=" + level0.getResult()
          + " volatileTerm=" + follower.getState().getCurrentTerm()
          + " persistedTerm=" + readPersistedTerm(metaFile));

      final Set<PosixFilePermission> originalPermissions = Files.getPosixFilePermissions(currentDir.toPath());
      Files.setPosixFilePermissions(currentDir.toPath(),
          EnumSet.of(PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_EXECUTE));
      try {
        final RaftServerImpl followerDuringFault = follower;
        final IOException thrown = Assertions.assertThrows(IOException.class,
            () -> followerDuringFault.appendEntries(appendEntries(group, 1, 1)));
        System.out.println("MC3_FAULT_STEP firstHigherTermAppendFailed=" + thrown.getClass().getSimpleName()
            + " volatileTerm=" + follower.getState().getCurrentTerm()
            + " persistedTerm=" + readPersistedTerm(metaFile));
      } finally {
        Files.setPosixFilePermissions(currentDir.toPath(), originalPermissions);
      }

      Assertions.assertEquals(1L, follower.getState().getCurrentTerm());
      Assertions.assertEquals(0L, readPersistedTerm(metaFile));

      final AppendEntriesReplyProto accepted = follower.appendEntries(appendEntries(group, 1, 2));
      Assertions.assertEquals(AppendResult.SUCCESS, accepted.getResult());
      Assertions.assertEquals(S1, follower.getState().getLeaderId());
      Assertions.assertEquals(1L, follower.getState().getCurrentTerm());
      Assertions.assertEquals(0L, readPersistedTerm(metaFile));
      System.out.println("MC3_BUG_ACCEPTED_SAME_TERM_APPEND result=" + accepted.getResult()
          + " replySuccess=" + accepted.getServerReply().getSuccess()
          + " leaderId=" + follower.getState().getLeaderId()
          + " volatileTerm=" + follower.getState().getCurrentTerm()
          + " persistedTerm=" + readPersistedTerm(metaFile));

      follower.close();
      follower = null;

      restarted = newServer(group, storageVolume, RaftStorage.StartupOption.RECOVER);
      restarted.start();
      System.out.println("MC3_AFTER_RESTART volatileTerm=" + restarted.getState().getCurrentTerm()
          + " persistedTerm=" + readPersistedTerm(metaFile));
      Assertions.assertEquals(0L, restarted.getState().getCurrentTerm());

      final RequestVoteReplyProto vote = restarted.requestVote(requestVote(group, 1, 3));
      Assertions.assertTrue(vote.getServerReply().getSuccess());
      Assertions.assertEquals(1L, vote.getTerm());
      Assertions.assertEquals(S3, restarted.getState().getVotedFor());
      System.out.println("MC3_BUG_SAME_TERM_VOTE_AFTER_ACCEPTED_LEADER voteGranted="
          + vote.getServerReply().getSuccess()
          + " candidate=" + S3
          + " volatileTerm=" + restarted.getState().getCurrentTerm()
          + " votedFor=" + restarted.getState().getVotedFor());
    } finally {
      if (follower != null) {
        follower.close();
      }
      if (restarted != null) {
        restarted.close();
      }
    }
  }

  private static RaftPeer peer(RaftPeerId id) {
    return RaftPeer.newBuilder().setId(id).setAddress("127.0.0.1:0").build();
  }

  private static RaftServerImpl newServer(RaftGroup group, File storageVolume, RaftStorage.StartupOption option)
      throws IOException {
    final RaftProperties properties = new RaftProperties();
    RaftServerConfigKeys.setStorageDir(properties, Collections.singletonList(storageVolume));
    RaftServerConfigKeys.Rpc.setTimeoutMin(properties, TimeDuration.valueOf(60, TimeUnit.SECONDS));
    RaftServerConfigKeys.Rpc.setTimeoutMax(properties, TimeDuration.valueOf(61, TimeUnit.SECONDS));
    RaftServerConfigKeys.Rpc.setFirstElectionTimeoutMin(properties, TimeDuration.valueOf(60, TimeUnit.SECONDS));
    RaftServerConfigKeys.Rpc.setFirstElectionTimeoutMax(properties, TimeDuration.valueOf(61, TimeUnit.SECONDS));

    final RaftServerProxy proxy = Mockito.mock(RaftServerProxy.class);
    Mockito.when(proxy.getId()).thenReturn(S2);
    Mockito.when(proxy.getPeer()).thenReturn(group.getPeer(S2));
    Mockito.when(proxy.getProperties()).thenReturn(properties);
    Mockito.when(proxy.getThreadGroup()).thenReturn(new ThreadGroup("mc3-" + option));
    Mockito.when(proxy.getServerRpc()).thenReturn(Mockito.mock(RaftServerRpc.class));

    return new RaftServerImpl(group, new BaseStateMachine(), proxy, option);
  }

  private static AppendEntriesRequestProto appendEntries(RaftGroup group, long term, long callId) {
    return AppendEntriesRequestProto.newBuilder()
        .setServerRequest(rpc(group, S1, callId))
        .setLeaderTerm(term)
        .setLeaderCommit(0)
        .build();
  }

  private static RequestVoteRequestProto requestVote(RaftGroup group, long term, long callId) {
    return RequestVoteRequestProto.newBuilder()
        .setServerRequest(rpc(group, S3, callId))
        .setCandidateTerm(term)
        .setCandidateLastEntry(TermIndexProto.newBuilder().setTerm(0).setIndex(0).build())
        .build();
  }

  private static RaftRpcRequestProto rpc(RaftGroup group, RaftPeerId requestor, long callId) {
    return RaftRpcRequestProto.newBuilder()
        .setRequestorId(requestor.toByteString())
        .setReplyId(S2.toByteString())
        .setRaftGroupId(RaftGroupIdProto.newBuilder().setId(group.getGroupId().toByteString()).build())
        .setCallId(callId)
        .build();
  }

  private static long readPersistedTerm(File metaFile) throws IOException {
    final Properties p = new Properties();
    try (InputStream in = Files.newInputStream(metaFile.toPath())) {
      p.load(in);
    }
    return Long.parseLong(p.getProperty("term"));
  }
}
JAVA

cd "$REPO"
unset JAVA_TOOL_OPTIONS
export MAVEN_OPTS="${MAVEN_OPTS:-} -Djava.io.tmpdir=$REPO/target/tmp"

echo "MC3_REPRO_COMMAND timeout 12m ./mvnw -pl ratis-server -am -Dtest=TestBugMC3MetadataPersistFailure#metadataPersistFailureAllowsSameTermAppendToRemainNonDurable test"
set +e
timeout 12m ./mvnw -pl ratis-server -am \
  -Dtest=TestBugMC3MetadataPersistFailure#metadataPersistFailureAllowsSameTermAppendToRemainNonDurable \
  -DfailIfNoTests=false \
  -Dsurefire.failIfNoSpecifiedTests=false \
  -Dcheckstyle.skip=true \
  -Dspotbugs.skip=true \
  -Drat.skip=true \
  -Dmaven.javadoc.skip=true \
  -DskipShade=true \
  test
rc=$?
set -e
echo "MC3_MAVEN_EXIT $rc"

if [ -d "$REPORT_DIR" ]; then
  echo "MC3_SUREFIRE_MARKERS"
  rg -n "MC3_|Tests run:|Failures:|Errors:" "$REPORT_DIR" || true
fi

exit "$rc"
