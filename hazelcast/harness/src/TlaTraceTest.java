package com.hazelcast.cp.internal.raft.impl;

import com.hazelcast.config.cp.RaftAlgorithmConfig;
import com.hazelcast.cp.internal.raft.impl.testing.LocalRaftGroup;
import com.hazelcast.cp.internal.raft.impl.testing.LocalRaftGroup.LocalRaftGroupBuilder;
import com.hazelcast.test.HazelcastTestSupport;
import org.junit.After;
import org.junit.Test;

import java.io.File;
import java.util.concurrent.Future;

import static com.hazelcast.cp.internal.raft.impl.RaftUtil.getCommitIndex;
import static com.hazelcast.cp.internal.raft.impl.RaftUtil.getLeaderMember;
import static com.hazelcast.cp.internal.raft.impl.RaftUtil.getRole;
import static com.hazelcast.cp.internal.raft.impl.RaftUtil.getTerm;
import static com.hazelcast.test.HazelcastTestSupport.assertTrueEventually;
import static com.hazelcast.test.HazelcastTestSupport.sleepAtLeastMillis;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotNull;

/**
 * TLA+ trace generation tests for Hazelcast Raft CP Subsystem.
 * Each test writes an NDJSON trace file under traces/.
 */
public class TlaTraceTest extends HazelcastTestSupport {

    private static final String TRACE_DIR = System.getProperty("tla.trace.dir",
            System.getenv("TLA_TRACE_DIR") != null ? System.getenv("TLA_TRACE_DIR") : "traces");

    private LocalRaftGroup group;

    @After
    public void destroy() {
        TlaTraceLogger.shutdown();
        if (group != null) {
            group.destroy();
        }
    }

    private void initTrace(String name) {
        new File(TRACE_DIR).mkdirs();
        TlaTraceLogger.init(TRACE_DIR + "/" + name + ".ndjson");
    }

    // -----------------------------------------------------------------------
    // Scenario 1: Basic consensus — election + replication + commit
    // -----------------------------------------------------------------------
    @Test
    public void test_basic_consensus() throws Exception {
        initTrace("basic_consensus");

        RaftAlgorithmConfig config = new RaftAlgorithmConfig();
        group = new LocalRaftGroupBuilder(3, config)
                .setAppendNopEntryOnLeaderElection(true)
                .build();
        group.start();
        group.waitUntilLeaderElected();

        RaftNodeImpl leader = group.getLeaderNode();
        assertNotNull(leader);

        // Replicate 3 entries
        for (int i = 0; i < 3; i++) {
            leader.replicate(new com.hazelcast.cp.internal.raft.impl.dataservice.ApplyRaftRunnable("val-" + i)).get();
        }

        // Wait for commit to propagate
        assertTrueEventually(() -> {
            for (RaftNodeImpl node : group.getNodes()) {
                long ci = getCommitIndex(node);
                // 1 noop + 3 values = 4
                assertEquals(4, ci);
            }
        });

        System.out.println("[TlaTraceTest] basic_consensus trace written");
    }

    // -----------------------------------------------------------------------
    // Scenario 2: Leader step-down — lease timeout causes demotion
    // -----------------------------------------------------------------------
    @Test
    public void test_leader_step_down() throws Exception {
        initTrace("leader_step_down");

        RaftAlgorithmConfig config = new RaftAlgorithmConfig();
        config.setLeaderHeartbeatPeriodInMillis(500);
        config.setMaxMissedLeaderHeartbeatCount(3);
        group = new LocalRaftGroupBuilder(3, config)
                .setAppendNopEntryOnLeaderElection(true)
                .build();
        group.start();
        group.waitUntilLeaderElected();

        RaftNodeImpl leader = group.getLeaderNode();
        RaftEndpoint leaderEndpoint = group.getLeaderEndpoint();

        // Replicate an entry first
        leader.replicate(new com.hazelcast.cp.internal.raft.impl.dataservice.ApplyRaftRunnable("val-0")).get();

        // Isolate the leader from all followers
        group.split(group.getLeaderIndex());

        // Wait for leader to step down (heartbeat timeout)
        assertTrueEventually(() -> {
            RaftRole role = getRole(leader);
            assertEquals(RaftRole.FOLLOWER, role);
        }, 30);

        // Merge back and let re-election happen
        group.merge();
        group.waitUntilLeaderElected();

        // Replicate another entry under new leader
        RaftNodeImpl newLeader = group.getLeaderNode();
        newLeader.replicate(new com.hazelcast.cp.internal.raft.impl.dataservice.ApplyRaftRunnable("val-1")).get();

        System.out.println("[TlaTraceTest] leader_step_down trace written");
    }

    // -----------------------------------------------------------------------
    // Scenario 3: Split-vote — 5 nodes, initial split may cause re-election
    // -----------------------------------------------------------------------
    @Test
    public void test_five_node_election() throws Exception {
        initTrace("five_node_election");

        RaftAlgorithmConfig config = new RaftAlgorithmConfig();
        group = new LocalRaftGroupBuilder(5, config)
                .setAppendNopEntryOnLeaderElection(true)
                .build();
        group.start();
        group.waitUntilLeaderElected();

        RaftNodeImpl leader = group.getLeaderNode();

        // Replicate several entries
        for (int i = 0; i < 5; i++) {
            leader.replicate(new com.hazelcast.cp.internal.raft.impl.dataservice.ApplyRaftRunnable("val-" + i)).get();
        }

        // Wait for all to commit
        assertTrueEventually(() -> {
            for (RaftNodeImpl node : group.getNodes()) {
                long ci = getCommitIndex(node);
                // 1 noop + 5 values = 6
                assertEquals(6, ci);
            }
        });

        System.out.println("[TlaTraceTest] five_node_election trace written");
    }
}
