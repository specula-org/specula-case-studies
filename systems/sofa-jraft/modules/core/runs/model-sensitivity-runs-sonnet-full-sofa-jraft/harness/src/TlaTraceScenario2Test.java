/*
 * Licensed to the Apache Software Foundation (ASF) under one or more
 * contributor license agreements.  See the NOTICE file distributed with
 * this work for additional information regarding copyright ownership.
 * The ASF licenses this file to You under the Apache License, Version 2.0
 * (the "License"); you may not use this file except in compliance with
 * the License.  You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package com.alipay.sofa.jraft.core;

import java.io.File;
import java.nio.ByteBuffer;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

import org.apache.commons.io.FileUtils;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;

import com.alipay.sofa.jraft.Node;
import com.alipay.sofa.jraft.NodeManager;
import com.alipay.sofa.jraft.entity.PeerId;
import com.alipay.sofa.jraft.entity.Task;
import com.alipay.sofa.jraft.storage.RaftMetaStorage;
import com.alipay.sofa.jraft.test.TestUtils;
import com.alipay.sofa.jraft.util.Endpoint;

/**
 * Scenario 2: leader crash + re-election + restart-from-persisted.
 *
 * Timeline:
 *   1. 3-node cluster elects a leader.
 *   2. Leader applies 3 tasks (ClientRequest × 3).
 *   3. Crash event emitted for the leader; node is stopped.
 *      → Followers lose heartbeat → new election (ElectionTimeout × N, vote exchange).
 *   4. New leader elected; applies 3 more tasks.
 *   5. Old leader restarted → RestartFromPersisted event emitted in initMetaStorage().
 *   6. All FSMs converge.
 *
 * Guarantees ≥20 trace events:
 *   election1: ~6 (ElectionTimeout + 4 vote msgs), replication1: ~9 (3×CR + 2×AE + 3×ACE),
 *   crash: 1, election2: ~6, replication2: ~9, restart: 1 → ~32 events minimum.
 */
public class TlaTraceScenario2Test {

    private String      dataPath;
    private TestCluster cluster;

    @Before
    public void setUp() throws Exception {
        this.dataPath = TestUtils.mkTempDir();
        FileUtils.forceMkdir(new File(this.dataPath));
    }

    @After
    public void tearDown() throws Exception {
        if (this.cluster != null) {
            this.cluster.stopAll();
        }
        FileUtils.deleteDirectory(new File(this.dataPath));
        NodeManager.getInstance().clear();
        TlaTrace.close();
    }

    @Test
    public void testLeaderCrashAndReelection() throws Exception {
        final String traceFile = System.getProperty("tla.trace.dir", "traces") + "/scenario2.ndjson";
        new File(traceFile).getParentFile().mkdirs();
        TlaTrace.reset(traceFile);

        final List<PeerId> peers = TestUtils.generatePeers(3);
        TlaTrace.registerPeers(peers.get(0).toString(), peers.get(1).toString(), peers.get(2).toString());

        // election_timeout_ms=500 so followers notice leader loss within ~1s.
        this.cluster = new TestCluster("tla-scenario2", this.dataPath, peers, 500);
        for (final PeerId peer : peers) {
            assertTrue(this.cluster.start(peer.getEndpoint()));
        }

        this.cluster.waitLeader();
        Thread.sleep(300);

        Node leader = this.cluster.getLeader();
        assertNotNull("No initial leader", leader);
        final Endpoint leaderEndpoint = leader.getNodeId().getPeerId().getEndpoint();
        final NodeImpl leaderImpl = (NodeImpl) leader;

        // Apply 3 tasks before crash.
        applyTasks(leader, 3);
        Thread.sleep(200);

        // Snapshot persisted state before stopping the node.
        final RaftMetaStorage meta = leaderImpl.getMetaStorage();
        final long crashTerm = leaderImpl.getCurrentTerm();
        final String crashRole = TlaTrace.roleStr(leaderImpl.getNodeState());
        final long persistedTerm = meta.getTerm();
        final String persistedVotedFor = TlaTrace.persistedVotedForStr(meta.getVotedFor());

        // Emit Crash event and stop the leader node.
        TlaTrace.emitCrash(leaderImpl.getServerId().toString(), crashTerm, crashRole, persistedTerm, persistedVotedFor);
        assertTrue("Failed to stop leader", this.cluster.stop(leaderEndpoint));

        // Wait for the remaining 2 nodes to elect a new leader.
        this.cluster.waitLeader();
        Thread.sleep(400);

        final Node newLeader = this.cluster.getLeader();
        assertNotNull("No new leader after crash", newLeader);

        // Apply 3 more tasks on new leader.
        applyTasks(newLeader, 3);
        Thread.sleep(200);

        // Restart old leader — triggers RestartFromPersisted in initMetaStorage().
        assertTrue("Failed to restart old leader", this.cluster.start(leaderEndpoint));
        Thread.sleep(500);

        // Converge all 3 FSMs.
        assertTrue("FSMs did not converge after restart", this.cluster.ensureSame(300));

        Thread.sleep(200);
        TlaTrace.close();
        System.out.println("[TlaTrace] Scenario2 trace written to: " + traceFile);
    }

    // -------------------------------------------------------------------------

    private static void applyTasks(final Node node, final int count) throws InterruptedException {
        final CountDownLatch latch = new CountDownLatch(count);
        for (int i = 0; i < count; i++) {
            final byte[] data = ("value" + i).getBytes();
            node.apply(new Task(ByteBuffer.wrap(data), status -> latch.countDown()));
        }
        assertTrue("Tasks did not complete in time",
            latch.await(30, TimeUnit.SECONDS));
    }

    private static void assertNotNull(final String msg, final Object obj) {
        if (obj == null)
            throw new AssertionError(msg);
    }

    private static void assertTrue(final String msg, final boolean condition) {
        if (!condition)
            throw new AssertionError(msg);
    }

    private static void assertTrue(final boolean condition) {
        if (!condition)
            throw new AssertionError();
    }
}
