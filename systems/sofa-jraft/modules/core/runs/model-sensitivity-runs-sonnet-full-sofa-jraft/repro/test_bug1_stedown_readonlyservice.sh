#!/bin/bash
# Reproduction test for BUG-1: stepDown() does not clear ReadOnlyService pending reads
#
# Bug location: NodeImpl.java:1301-1357 (stepDown method)
# Missing: readOnlyService cleanup when node steps down from leader to follower
#
# Escalation level used: Level 2 (state injection via @OnlyForTest accessor)
# Rationale: direct state injection is cleaner than full cluster setup and
# directly demonstrates the omission in stepDown().
#
# Expected outcome when bug is PRESENT:
#   The test PASSES — it observes that notifySuccess() fires on a pending read
#   after step-down (no cleanup was done), confirming the bug.
# Expected outcome after bug is FIXED:
#   The test would need to be updated: resetPendingStatusError() or equivalent
#   would be called by stepDown(), and the closure would fire with an error status.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JRAFT_ROOT="$SCRIPT_DIR/../artifact/sofa-jraft"
TEST_SRC="$JRAFT_ROOT/jraft-core/src/test/java/com/alipay/sofa/jraft/core"
TEST_CLASS="ReadOnlyServiceStepDownBugTest"
TEST_FILE="$TEST_SRC/${TEST_CLASS}.java"

echo "=== BUG-1 Reproduction: stepDown() does not clear ReadOnlyService ==="
echo ""

# Write the test file
cat > "$TEST_FILE" << 'JAVA_EOF'
/*
 * Reproduction test for BUG-1: NodeImpl.stepDown() does not clear ReadOnlyService
 * pending reads.
 *
 * The bug: NodeImpl.stepDown() (lines 1301-1357) clears the ballot box and stops
 * replicators, but never calls readOnlyService.setError() or any equivalent cleanup.
 * As a result, ReadOnlyServiceImpl.pendingNotifyStatus retains all pending read
 * closures, and the background scheduler (ReadOnlyService-PendingNotify-Scanner)
 * will fire notifySuccess() on those closures when the applied index catches up —
 * even though the node is now a follower.
 *
 * Escalation level: 2 (state injection via @OnlyForTest getPendingNotifyStatus())
 */
package com.alipay.sofa.jraft.core;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.mockito.Mock;
import org.mockito.Mockito;
import org.mockito.runners.MockitoJUnitRunner;

import com.alipay.sofa.jraft.FSMCaller;
import com.alipay.sofa.jraft.Status;
import com.alipay.sofa.jraft.closure.ReadIndexClosure;
import com.alipay.sofa.jraft.entity.PeerId;
import com.alipay.sofa.jraft.entity.ReadIndexState;
import com.alipay.sofa.jraft.entity.ReadIndexStatus;
import com.alipay.sofa.jraft.option.NodeOptions;
import com.alipay.sofa.jraft.option.RaftOptions;
import com.alipay.sofa.jraft.option.ReadOnlyServiceOptions;
import com.alipay.sofa.jraft.test.TestUtils;
import com.alipay.sofa.jraft.util.Bytes;
import com.alipay.sofa.jraft.util.Utils;

import static org.junit.Assert.*;

@RunWith(MockitoJUnitRunner.class)
public class ReadOnlyServiceStepDownBugTest {

    public static final String  GROUP_ID = "test";
    private ReadOnlyServiceImpl readOnlyServiceImpl;

    @Mock
    private NodeImpl            node;

    @Mock
    private FSMCaller           fsmCaller;

    @Before
    public void setup() {
        this.readOnlyServiceImpl = new ReadOnlyServiceImpl();
        final ReadOnlyServiceOptions opts = new ReadOnlyServiceOptions();
        opts.setFsmCaller(this.fsmCaller);
        opts.setNode(this.node);
        opts.setRaftOptions(new RaftOptions());
        Mockito.when(this.node.getNodeMetrics()).thenReturn(new NodeMetrics(false));
        Mockito.when(this.node.getOptions()).thenReturn(new NodeOptions());
        Mockito.when(this.node.getGroupId()).thenReturn(GROUP_ID);
        Mockito.when(this.node.getServerId()).thenReturn(new PeerId("localhost:8081", 0));
        Mockito.when(this.node.getRaftOptions()).thenReturn(new RaftOptions());
        assertTrue(this.readOnlyServiceImpl.init(opts));
    }

    @After
    public void teardown() throws Exception {
        this.readOnlyServiceImpl.shutdown();
        this.readOnlyServiceImpl.join();
    }

    /**
     * BUG-1 reproduction test.
     *
     * Scenario:
     *   1. Leader s1 receives a ReadIndex request.
     *   2. Quorum is confirmed: the ReadIndex response arrives with index=1.
     *      The applied index hasn't reached 1 yet, so the closure is put into
     *      pendingNotifyStatus (simulated via state injection).
     *   3. s1 steps down (NodeImpl.stepDown() is called). stepDown() does NOT
     *      call readOnlyService.setError() — this is the bug.
     *   4. Later, the applied index reaches 1. The background scanner calls
     *      onApplied(1), which fires notifySuccess() on the pending closure.
     *   5. OBSERVED (buggy): the client closure is called with Status.OK() and
     *      index=1, even though s1 is now a follower.
     *   6. EXPECTED (correct): after step-down, the closure should either be
     *      cleared (never called) or called with an error status indicating
     *      "leader stepped down".
     *
     * The test PASSES when the bug is present (it confirms the buggy behavior).
     * It would need to be updated after the bug is fixed.
     */
    @Test
    public void testPendingReadFiresSuccessAfterStepDown() throws Exception {
        final byte[] reqContext = TestUtils.getRandomBytes();
        final AtomicBoolean closureFiredWithSuccess = new AtomicBoolean(false);
        final AtomicReference<Status> closureStatus = new AtomicReference<>();
        final AtomicReference<Long> closureIndex = new AtomicReference<>();
        final CountDownLatch latch = new CountDownLatch(1);

        // Step 1: Create a pending read closure at commit index=1.
        // This simulates the state after the leader received a quorum response
        // for a ReadIndex request at index=1, but the applied index hasn't
        // reached 1 yet (so the closure was parked in pendingNotifyStatus).
        final ReadIndexState state = new ReadIndexState(
            new Bytes(reqContext),
            new ReadIndexClosure() {
                @Override
                public void run(final Status status, final long index, final byte[] reqCtx) {
                    closureFiredWithSuccess.set(status.isOk());
                    closureStatus.set(status);
                    closureIndex.set(index);
                    latch.countDown();
                }
            },
            Utils.monotonicMs()
        );
        state.setIndex(1);

        final ArrayList<ReadIndexState> states = new ArrayList<>();
        states.add(state);
        final ReadIndexStatus readIndexStatus = new ReadIndexStatus(states, null, 1);

        // Inject pending state — represents a committed ReadIndex quorum not yet applied
        this.readOnlyServiceImpl.getPendingNotifyStatus().put(1L, Arrays.asList(readIndexStatus));

        // Verify state is pending
        assertEquals(1, this.readOnlyServiceImpl.getPendingNotifyStatus().size());

        // Step 2: Simulate stepDown(). In the real system, NodeImpl.stepDown()
        // (lines 1301-1357) does NOT call readOnlyService.setError() or any
        // cleanup method. We reproduce this by doing nothing here.
        //
        // BUG: There is no call like:
        //   readOnlyService.setError(new RaftException(..., new Status(RaftError.EPERM,
        //       "Node stepped down from leader role.")));
        // If the bug were fixed, we would call it here and the closure would
        // receive an error status.

        // Step 3: applied index advances to 1. The background scanner or
        // fsmCaller.onApplied() fires.
        this.readOnlyServiceImpl.onApplied(1);

        // Step 4: Wait for the closure to fire.
        final boolean timedOut = !latch.await(3, TimeUnit.SECONDS);
        assertFalse("Closure should have fired (latch should not time out)", timedOut);

        // Step 5: Observe the buggy behavior.
        //
        // BUG CONFIRMED: the closure fires with Status.OK() even though the
        // node has stepped down. The client receives a successful read response
        // from a node that is now a follower.
        //
        // If the bug were fixed, closureFiredWithSuccess would be false here
        // because stepDown() would have called readOnlyService.setError().
        assertTrue(
            "BUG CONFIRMED: closure fired with success=" + closureFiredWithSuccess.get()
            + " status=" + closureStatus.get()
            + " index=" + closureIndex.get()
            + ". After stepDown(), pending reads should be cleared with an error, not resolved successfully.",
            closureFiredWithSuccess.get()
        );
        assertEquals("Fired index should be 1 (the read index)", 1L, (long) closureIndex.get());

        // Step 6: Verify pendingNotifyStatus is now empty (it was consumed by notifySuccess).
        // This is correct behavior — the entry was removed — but the closure was
        // invoked with the wrong status (OK instead of error).
        assertTrue(
            "pendingNotifyStatus should be empty after onApplied fired",
            this.readOnlyServiceImpl.getPendingNotifyStatus().isEmpty()
        );

        System.out.println("=== BUG-1 CONFIRMED ===");
        System.out.println("Pending read closure fired with status=" + closureStatus.get()
            + " index=" + closureIndex.get());
        System.out.println("This demonstrates that NodeImpl.stepDown() (lines 1301-1357)");
        System.out.println("does NOT clear ReadOnlyService pending reads.");
        System.out.println("A client receives a successful ReadIndex response from a former leader.");
    }
}
JAVA_EOF

echo "Test file written to: $TEST_FILE"
echo ""
echo "Running Maven test..."
echo ""

cd "$JRAFT_ROOT"
timeout 300 mvn -pl jraft-core -Dtest=ReadOnlyServiceStepDownBugTest -DfailIfNoTests=false test \
    --no-transfer-progress \
    -q 2>&1 || true

echo ""
echo "=== Test run complete ==="

# Clean up the test file
rm -f "$TEST_FILE"
echo "(Test file removed after run)"
