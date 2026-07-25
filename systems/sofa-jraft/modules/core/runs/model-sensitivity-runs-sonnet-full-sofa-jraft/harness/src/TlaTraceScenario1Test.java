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
import com.alipay.sofa.jraft.Status;
import com.alipay.sofa.jraft.entity.PeerId;
import com.alipay.sofa.jraft.entity.Task;
import com.alipay.sofa.jraft.error.RaftError;
import com.alipay.sofa.jraft.test.TestUtils;
import com.alipay.sofa.jraft.util.Endpoint;

/**
 * Scenario 1: normal election + log replication across a 3-node cluster.
 *
 * Trace events expected: ElectionTimeout (one per candidate), HandleRequestVoteRequest*
 * (vote processing on followers), HandleRequestVoteResponse (candidate tallies votes),
 * ClientRequest (leader appends entries), HandleAppendEntriesRequest (followers persist),
 * and ApplyCommittedEntries (FSM applies) — well above the 20-event minimum.
 */
public class TlaTraceScenario1Test {

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
    public void testNormalElectionAndReplication() throws Exception {
        final String traceFile = System.getProperty("tla.trace.dir", "traces") + "/scenario1.ndjson";
        new File(traceFile).getParentFile().mkdirs();
        TlaTrace.reset(traceFile);

        final List<PeerId> peers = TestUtils.generatePeers(3);
        // Register in sorted order so s1/s2/s3 are deterministic across runs.
        TlaTrace.registerPeers(peers.get(0).toString(), peers.get(1).toString(), peers.get(2).toString());

        this.cluster = new TestCluster("tla-scenario1", this.dataPath, peers, 300);
        for (final PeerId peer : peers) {
            assertTrue(this.cluster.start(peer.getEndpoint()));
        }

        // Wait for leader — triggers ElectionTimeout + vote exchange on all 3 nodes.
        this.cluster.waitLeader();
        Thread.sleep(300); // let heartbeat AE round settle

        final Node leader = this.cluster.getLeader();
        assertNotNull("No leader elected", leader);

        // Apply tasks one-by-one to avoid batching, ensuring a ClientRequest event per
        // task. 10 tasks → ~10 ClientRequest + ~20 AE + ~30 ACE events.
        for (int i = 0; i < 5; i++) {
            applyTasks(leader, 1);
            Thread.sleep(50);
        }

        // Wait for all 3 FSMs to converge (ensures ApplyCommittedEntries events fire).
        assertTrue("FSMs did not converge", this.cluster.ensureSame(200));

        Thread.sleep(200);
        TlaTrace.close();
        System.out.println("[TlaTrace] Scenario1 trace written to: " + traceFile);
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
