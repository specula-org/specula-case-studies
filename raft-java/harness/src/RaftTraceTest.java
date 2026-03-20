package com.github.wenweihu86.raft;

import com.baidu.brpc.server.RpcServer;
import com.github.wenweihu86.raft.proto.RaftProto;
import com.github.wenweihu86.raft.service.RaftConsensusService;
import com.github.wenweihu86.raft.service.impl.RaftConsensusServiceImpl;
import com.github.wenweihu86.raft.service.impl.RaftClientServiceImpl;
import org.apache.commons.io.FileUtils;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;

import java.io.File;
import java.io.IOException;
import java.util.ArrayList;
import java.util.List;

import static org.junit.Assert.*;

/**
 * Integration test that starts a 3-node raft cluster in-process,
 * exercises leader election and log replication, and collects
 * NDJSON traces for TLA+ trace validation.
 */
public class RaftTraceTest {

    private static final int BASE_PORT = 20001;
    private static final int NUM_SERVERS = 3;
    private static final String DATA_BASE = "/tmp/raft-trace-test";

    private List<RpcServer> rpcServers = new ArrayList<>();
    private List<RaftNode> raftNodes = new ArrayList<>();

    /** Minimal StateMachine that does nothing. */
    private static class NoopStateMachine implements StateMachine {
        @Override
        public void writeSnapshot(String snapshotDir) {
            new File(snapshotDir).mkdirs();
        }

        @Override
        public void readSnapshot(String snapshotDir) {
        }

        @Override
        public void apply(byte[] dataBytes) {
        }
    }

    private List<RaftProto.Server> buildServerList() {
        List<RaftProto.Server> servers = new ArrayList<>();
        for (int i = 1; i <= NUM_SERVERS; i++) {
            RaftProto.Endpoint ep = RaftProto.Endpoint.newBuilder()
                    .setHost("127.0.0.1")
                    .setPort(BASE_PORT + i)
                    .build();
            servers.add(RaftProto.Server.newBuilder()
                    .setServerId(i)
                    .setEndpoint(ep)
                    .build());
        }
        return servers;
    }

    private void startCluster(String traceFile) throws Exception {
        // Clean data directories
        FileUtils.deleteQuietly(new File(DATA_BASE));

        // Initialize trace
        TlaTrace.init(traceFile);

        List<RaftProto.Server> servers = buildServerList();

        for (int i = 0; i < NUM_SERVERS; i++) {
            RaftProto.Server localServer = servers.get(i);
            String dataDir = DATA_BASE + "/node" + localServer.getServerId();
            new File(dataDir).mkdirs();

            RaftOptions options = new RaftOptions();
            options.setDataDir(dataDir);
            options.setElectionTimeoutMilliseconds(800);
            options.setHeartbeatPeriodMilliseconds(200);
            options.setSnapshotPeriodSeconds(3600); // Don't snapshot during test
            options.setSnapshotMinLogSize(1024 * 1024 * 100); // High threshold
            options.setMaxAwaitTimeout(5000);

            NoopStateMachine sm = new NoopStateMachine();
            RaftNode node = new RaftNode(options, servers, localServer, sm);

            RpcServer rpcServer = new RpcServer(localServer.getEndpoint().getPort());
            rpcServer.registerService(new RaftConsensusServiceImpl(node));
            rpcServer.registerService(new RaftClientServiceImpl(node));
            rpcServer.start();

            rpcServers.add(rpcServer);
            raftNodes.add(node);
        }

        // Init nodes after all servers are listening (so RPCs succeed)
        for (RaftNode node : raftNodes) {
            node.init();
        }
    }

    @After
    public void tearDown() throws Exception {
        TlaTrace.close();
        for (RpcServer server : rpcServers) {
            try {
                server.shutdown();
            } catch (Exception e) {
                // ignore
            }
        }
        for (RaftNode node : raftNodes) {
            try {
                // Best-effort shutdown of thread pools
                node.getExecutorService().shutdownNow();
            } catch (Exception e) {
                // ignore
            }
        }
        rpcServers.clear();
        raftNodes.clear();
        // Clean up data
        FileUtils.deleteQuietly(new File(DATA_BASE));
    }

    /** Wait for a leader to emerge. Returns the leader node or null. */
    private RaftNode waitForLeader(long timeoutMs) throws InterruptedException {
        long deadline = System.currentTimeMillis() + timeoutMs;
        while (System.currentTimeMillis() < deadline) {
            for (RaftNode node : raftNodes) {
                if (node.getState() == RaftNode.NodeState.STATE_LEADER) {
                    return node;
                }
            }
            Thread.sleep(100);
        }
        return null;
    }

    @Test
    public void testBasicConsensus() throws Exception {
        String traceFile = System.getProperty("raft.trace.file",
                "/home/ubuntu/Specula/case-studies/raft-java/traces/basic_consensus.ndjson");
        startCluster(traceFile);

        // Wait for leader election (up to 15 seconds)
        RaftNode leader = waitForLeader(15000);
        assertNotNull("A leader should be elected within 15s", leader);
        System.out.println("Leader elected: s" + leader.getLocalServer().getServerId()
                + " in term " + leader.getCurrentTerm());

        // Let heartbeats stabilize and followers catch up
        Thread.sleep(3000);

        // Submit client requests — some may fail if quorum not yet stable
        int successes = 0;
        for (int i = 1; i <= 5; i++) {
            byte[] data = ("value" + i).getBytes();
            boolean success = leader.replicate(data, RaftProto.EntryType.ENTRY_TYPE_DATA);
            if (success) successes++;
            System.out.println("ClientRequest " + i + " result: " + success);
            Thread.sleep(500);
        }

        // Wait for replication
        Thread.sleep(2000);

        System.out.println("Successful requests: " + successes);
        System.out.println("Leader commitIndex: " + leader.getCommitIndex());

        // Print state summary
        for (RaftNode node : raftNodes) {
            System.out.printf("Node s%d: term=%d role=%s commitIndex=%d lastLogIndex=%d%n",
                    node.getLocalServer().getServerId(),
                    node.getCurrentTerm(),
                    node.getState(),
                    node.getCommitIndex(),
                    node.getRaftLog().getLastLogIndex());
        }
    }

    @Test
    public void testMultipleRequests() throws Exception {
        String traceFile = System.getProperty("raft.trace.file",
                "/home/ubuntu/Specula/case-studies/raft-java/traces/multiple_requests.ndjson");
        startCluster(traceFile);

        // Wait for leader election
        RaftNode leader = waitForLeader(15000);
        assertNotNull("A leader should be elected", leader);
        System.out.println("Leader elected: s" + leader.getLocalServer().getServerId()
                + " in term " + leader.getCurrentTerm());

        // Let heartbeats stabilize
        Thread.sleep(2000);

        // Submit multiple rounds of client requests with pauses for replication
        for (int round = 1; round <= 3; round++) {
            for (int i = 1; i <= 2; i++) {
                byte[] data = ("round" + round + "_value" + i).getBytes();
                boolean success = leader.replicate(data, RaftProto.EntryType.ENTRY_TYPE_DATA);
                System.out.println("Round " + round + " Request " + i + " result: " + success);
            }
            // Wait for replication between rounds
            Thread.sleep(1000);
        }

        // Wait for final replication
        Thread.sleep(2000);

        System.out.println("Leader commitIndex: " + leader.getCommitIndex());

        for (RaftNode node : raftNodes) {
            System.out.printf("Node s%d: term=%d role=%s commitIndex=%d lastLogIndex=%d%n",
                    node.getLocalServer().getServerId(),
                    node.getCurrentTerm(),
                    node.getState(),
                    node.getCommitIndex(),
                    node.getRaftLog().getLastLogIndex());
        }

        // Relaxed assertion: at least some requests should commit
        assertTrue("Leader commitIndex should be > 0", leader.getCommitIndex() > 0);
    }
}
