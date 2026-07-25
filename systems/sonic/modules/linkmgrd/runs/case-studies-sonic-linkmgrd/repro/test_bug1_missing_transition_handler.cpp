/*
 * Bug 1 Reproduction: Missing Transition Handler for (LPWait, MuxError, LinkUp)
 *
 * This test is added to the existing gtest suite:
 *   test/LinkManagerStateMachineActiveActiveTest.cpp
 *
 * Test name: LinkManagerStateMachineActiveActiveTest.BugMissingHandlerWaitErrorUp
 *
 * Run command:
 *   docker exec sonic-build bash -c \
 *     "cd /workspace/case-studies/sonic-linkmgrd/artifact/sonic-linkmgrd && \
 *      ./linkmgrd-test --gtest_filter='LinkManagerStateMachineActiveActiveTest.BugMissingHandlerWaitErrorUp'"
 *
 * Result: PASS (bug triggered) — system stuck at (Wait, Error, Up) with no recovery action.
 */

// This test was added to test/LinkManagerStateMachineActiveActiveTest.cpp
// Reproduced below for reference:

TEST_F(LinkManagerStateMachineActiveActiveTest, BugMissingHandlerWaitErrorUp)
{
    // BUG REPRODUCTION: Missing transition handler for composite state (Wait, Error, Up).
    // The transition table in ActiveActiveStateMachine::initializeTransitionFunctionTable()
    // does not register a handler for {LPWait, MuxError, LinkUp}.
    // When this state is reached, noopTransitionFunction runs — no recovery action.
    // Expected correct behavior: start mux probe timer (like {Active, Error, Up} handler).

    activateStateMachine();
    VALIDATE_STATE(Wait, Wait, Down);

    // Link comes up — LP stays in Wait (no heartbeats yet)
    postLinkEvent(link_state::LinkState::Up);
    VALIDATE_STATE(Wait, Wait, Up);

    // Record counters before the bug trigger
    uint32_t setMuxStateBefore = mDbInterfacePtr->mSetMuxStateInvokeCount;
    uint32_t probeStateBefore = mDbInterfacePtr->mProbeForwardingStateInvokeCount;

    // Mux hardware reports Error while LP is still in Wait
    postMuxEvent(mux_state::MuxState::Error);
    VALIDATE_STATE(Wait, Error, Up);

    // BUG ASSERTION: No recovery action was taken — system is stuck.
    // The {Active, Error, Up} handler would call startMuxProbeTimer() which calls
    // probeMuxState() (incrementing mProbeForwardingStateInvokeCount).
    // But {Wait, Error, Up} has no handler, so no probe is issued.
    EXPECT_EQ(mDbInterfacePtr->mSetMuxStateInvokeCount, setMuxStateBefore)
        << "BUG: No mux state change requested — system stuck at (Wait, Error, Up)";
    EXPECT_EQ(mDbInterfacePtr->mProbeForwardingStateInvokeCount, probeStateBefore)
        << "BUG: No mux probe issued — no recovery path from (Wait, Error, Up)";
}
