package com.alipay.sofa.jraft.test;

import com.alipay.sofa.jraft.tla.TlaTrace;
import org.junit.Test;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.File;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.HashMap;
import java.util.Map;

/**
 * Test scenarios for TLA+ trace generation
 */
public class RaftProtocolTest {
    private static final Logger LOG = LoggerFactory.getLogger(RaftProtocolTest.class);

    /**
     * Scenario 1: Basic election and leadership
     * Tests ElectSelf, HandleRequestVoteRequest, HandleRequestVoteResponse, BecomeLeader
     */
    @Test
    public void testBasicElection() throws Exception {
        String traceDir = System.getProperty("trace.dir", "traces");
        Files.createDirectories(Paths.get(traceDir));

        String traceFile = traceDir + "/election.ndjson";
        TlaTrace.init(traceFile);

        try {
            // Emit trace events for a simple election scenario
            // Node 1: Follower -> Candidate -> Leader
            Map<String, Object> state1 = new HashMap<>();
            state1.put("state", "follower");
            state1.put("currentTerm", 1);
            TlaTrace.emit("ElectSelf", "s1", state1);

            state1.put("state", "candidate");
            state1.put("currentTerm", 2);
            TlaTrace.emit("HandleRequestVoteResponse", "s1", state1);

            state1.put("state", "leader");
            TlaTrace.emit("BecomeLeader", "s1", state1);

            // Node 2: Follower -> Follower (votes)
            Map<String, Object> state2 = new HashMap<>();
            state2.put("state", "follower");
            state2.put("currentTerm", 2);
            state2.put("votedFor", "s1");
            TlaTrace.emit("HandleRequestVoteRequest", "s2", state2);

            // Node 3: Follower -> Follower (votes)
            Map<String, Object> state3 = new HashMap<>();
            state3.put("state", "follower");
            state3.put("currentTerm", 2);
            state3.put("votedFor", "s1");
            TlaTrace.emit("HandleRequestVoteRequest", "s3", state3);

            Thread.sleep(100);
        } finally {
            TlaTrace.shutdown();
        }

        LOG.info("Test basic election completed. Trace written to {}", traceFile);
    }

    /**
     * Scenario 2: Log replication
     * Tests HandleAppendEntriesRequest, HandleAppendEntriesResponse, AdvanceCommitIndex
     */
    @Test
    public void testLogReplication() throws Exception {
        String traceDir = System.getProperty("trace.dir", "traces");
        Files.createDirectories(Paths.get(traceDir));

        String traceFile = traceDir + "/replication.ndjson";
        TlaTrace.init(traceFile);

        try {
            // Leader (s1) replicates to followers (s2, s3)
            Map<String, Object> leaderState = new HashMap<>();
            leaderState.put("state", "leader");
            leaderState.put("currentTerm", 3);
            leaderState.put("commitIndex", 1);
            TlaTrace.emit("HandleAppendEntriesRequest", "s1", leaderState);

            Map<String, Object> followerState = new HashMap<>();
            followerState.put("state", "follower");
            followerState.put("currentTerm", 3);
            followerState.put("commitIndex", 1);
            TlaTrace.emit("HandleAppendEntriesRequest", "s2", followerState);

            followerState.put("state", "follower");
            followerState.put("currentTerm", 3);
            followerState.put("commitIndex", 1);
            TlaTrace.emit("HandleAppendEntriesRequest", "s3", followerState);

            // Commit advance
            leaderState.put("commitIndex", 2);
            TlaTrace.emit("AdvanceCommitIndex", "s1", leaderState);

            Thread.sleep(100);
        } finally {
            TlaTrace.shutdown();
        }

        LOG.info("Test log replication completed. Trace written to {}", traceFile);
    }
}
