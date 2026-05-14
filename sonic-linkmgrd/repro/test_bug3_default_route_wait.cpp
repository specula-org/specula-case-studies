/*
 * Bug 3 Reproduction: DefaultRoute::Wait Passes != NA Check (Premature Active Switch)
 *
 * This test is added to the existing gtest suite:
 *   test/LinkManagerStateMachineActiveActiveTest.cpp
 *
 * Test name: LinkManagerStateMachineActiveActiveTest.BugDefaultRouteWaitPrematureActiveSwitch
 *
 * Run command:
 *   docker exec sonic-build bash -c \
 *     "cd /workspace/case-studies/sonic-linkmgrd/artifact/sonic-linkmgrd && \
 *      ./linkmgrd-test --gtest_filter='LinkManagerStateMachineActiveActiveTest.BugDefaultRouteWaitPrematureActiveSwitch'"
 *
 * Result: PASS (bug triggered) — system switches to Active with DR = Wait when DR feature enabled.
 */

// This test was added to test/LinkManagerStateMachineActiveActiveTest.cpp
// Reproduced below for reference:

TEST_F(LinkManagerStateMachineActiveActiveTest, BugDefaultRouteWaitPrematureActiveSwitch)
{
    // BUG REPRODUCTION: DefaultRoute::Wait passes the `!= NA` check in
    // LinkProberActiveMuxStandbyLinkUpTransitionFunction (ActiveActive.cpp:807),
    // causing a premature switch to Active before the default route is confirmed.
    //
    // The health computation at line 1147 correctly checks `== OK`, but the
    // transition handler at line 807 uses the weaker `!= NA` check.
    // When the DR feature is enabled and DR is still Wait (initial/unknown),
    // the system incorrectly switches to Active.

    // Enable default route feature from the start — DR initializes to Wait
    activateStateMachine(/*enable_feature_default_route=*/true);
    VALIDATE_STATE(Wait, Wait, Down);

    // Bring link up
    postLinkEvent(link_state::LinkState::Up);
    VALIDATE_STATE(Wait, Wait, Up);

    // LP becomes Active — triggers switch to Active via {Active, Wait, Up} handler
    postLinkProberEvent(link_prober::LinkProberState::Active, 3);
    VALIDATE_STATE(Active, Active, Up);
    EXPECT_EQ(mDbInterfacePtr->mSetMuxStateInvokeCount, 1);
    EXPECT_EQ(mDbInterfacePtr->mLastSetMuxState, mux_state::MuxState::Label::Active);

    // Mux confirms active
    handleMuxState("active", 3);
    VALIDATE_STATE(Active, Active, Up);

    // Now mux reports standby (e.g., orchagent override or hardware glitch).
    // DR is still Wait — never received a DR notification.
    handleMuxState("standby", 3);

    // BUG ASSERTION: The handler at line 807 checks `mDefaultRouteState != DefaultRoute::NA`.
    // DR = Wait satisfies this (Wait != NA), so it calls switchMuxState(Active).
    // With DR feature enabled, this is WRONG — should only switch when DR == OK.
    EXPECT_EQ(mDbInterfacePtr->mLastSetMuxState, mux_state::MuxState::Label::Active)
        << "BUG: System switched to Active despite DR = Wait (unknown). "
           "Should wait for DR = OK before switching when DR feature is enabled.";

    // The switch count increased — proving the premature switch occurred
    EXPECT_GT(mDbInterfacePtr->mSetMuxStateInvokeCount, 1u)
        << "BUG: switchMuxState was called with DR still in Wait state";
}
