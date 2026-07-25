/*
 * Test scenarios for TLA+ trace generation.
 * Exercises core Raft protocol paths: leader election, log replication, commit advancement.
 */
package org.apache.ratis.server.impl;

import org.apache.ratis.BaseTest;
import org.apache.ratis.RaftTestUtil;
import org.apache.ratis.client.RaftClient;
import org.apache.ratis.conf.RaftProperties;
import org.apache.ratis.protocol.Message;
import org.apache.ratis.protocol.RaftClientReply;
import org.apache.ratis.server.RaftServer;
import org.apache.ratis.server.RaftServerConfigKeys;
import org.apache.ratis.server.TlaTrace;
import org.apache.ratis.server.simulation.MiniRaftClusterWithSimulatedRpc;
import org.apache.ratis.util.TimeDuration;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;

import java.io.File;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.assertTrue;

public class TlaTraceTest extends BaseTest {

    private static final String TRACE_DIR = System.getProperty("ratis.tla.trace.dir",
        System.getenv("RATIS_TLA_TRACE_DIR") != null ? System.getenv("RATIS_TLA_TRACE_DIR") : "/tmp/ratis-traces");

    @AfterEach
    void cleanup() {
        TlaTrace.close();
    }

    /**
     * Scenario 1: Basic consensus — leader election + client requests + log replication.
     * Generates: Timeout, HandleRequestVoteRequest, HandleRequestVoteResponse,
     *            ClientRequest, AppendEntries, Heartbeat, HandleAppendEntriesRequest,
     *            HandleAppendEntriesResponse, AdvanceCommitIndex
     */
    @Test
    public void testBasicConsensus() throws Exception {
        String traceFile = TRACE_DIR + "/basic_consensus.ndjson";
        new File(TRACE_DIR).mkdirs();
        TlaTrace.init(traceFile);

        final RaftProperties prop = new RaftProperties();
        // Use fast election timeouts for quick test
        RaftServerConfigKeys.LeaderElection.setPreVote(prop, false);

        final MiniRaftClusterWithSimulatedRpc cluster =
            MiniRaftClusterWithSimulatedRpc.FACTORY.newCluster(
                new String[]{"s1", "s2", "s3"}, new String[]{}, prop);

        try {
            cluster.start();

            // Wait for leader election
            final RaftServer.Division leader = RaftTestUtil.waitForLeader(cluster);
            LOG.info("Leader elected: {}", leader.getId());

            // Submit client requests — triggers log replication
            try (RaftClient client = cluster.createClient()) {
                for (int i = 0; i < 5; i++) {
                    RaftClientReply reply = client.io().send(Message.valueOf("msg-" + i));
                    assertTrue(reply.isSuccess(), "Client request " + i + " failed");
                }
            }

            // Give time for replication and commit advancement
            Thread.sleep(2000);

            LOG.info("Basic consensus trace written to {}", traceFile);
        } finally {
            cluster.shutdown();
            TlaTrace.close();
        }

        // Verify trace file exists and has content
        File f = new File(traceFile);
        assertTrue(f.exists(), "Trace file not created");
        assertTrue(f.length() > 0, "Trace file is empty");
    }

    /**
     * Scenario 2: Leader re-election — kill leader, new leader elected.
     * Generates: Crash-related events, multiple election rounds, re-replication.
     */
    @Test
    public void testLeaderReelection() throws Exception {
        String traceFile = TRACE_DIR + "/leader_reelection.ndjson";
        new File(TRACE_DIR).mkdirs();
        TlaTrace.init(traceFile);

        final RaftProperties prop = new RaftProperties();
        RaftServerConfigKeys.LeaderElection.setPreVote(prop, false);

        final MiniRaftClusterWithSimulatedRpc cluster =
            MiniRaftClusterWithSimulatedRpc.FACTORY.newCluster(
                new String[]{"s1", "s2", "s3"}, new String[]{}, prop);

        try {
            cluster.start();

            // Wait for initial leader
            RaftServer.Division leader = RaftTestUtil.waitForLeader(cluster);
            LOG.info("Initial leader: {}", leader.getId());

            // Submit some initial requests
            try (RaftClient client = cluster.createClient()) {
                for (int i = 0; i < 3; i++) {
                    client.io().send(Message.valueOf("before-" + i));
                }
            }

            // Wait for replication
            Thread.sleep(1000);

            // Kill the leader
            String leaderId = leader.getId().toString();
            LOG.info("Killing leader: {}", leaderId);
            cluster.killServer(leader.getId());

            // Wait for new leader
            leader = RaftTestUtil.waitForLeader(cluster);
            LOG.info("New leader: {}", leader.getId());

            // Submit more requests under new leader
            try (RaftClient client = cluster.createClient()) {
                for (int i = 0; i < 3; i++) {
                    RaftClientReply reply = client.io().send(Message.valueOf("after-" + i));
                    assertTrue(reply.isSuccess(), "Post-reelection request " + i + " failed");
                }
            }

            Thread.sleep(2000);
            LOG.info("Leader re-election trace written to {}", traceFile);
        } finally {
            cluster.shutdown();
            TlaTrace.close();
        }

        File f = new File(traceFile);
        assertTrue(f.exists(), "Trace file not created");
        assertTrue(f.length() > 0, "Trace file is empty");
    }
}
