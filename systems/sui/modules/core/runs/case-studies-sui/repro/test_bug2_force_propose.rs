// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
//
// Reproduction for Specula MC bug F4 / MC4:
// `Proposer::smart_ancestors_to_propose` force path asserts
//   "Fatal error, quorum not reached for parent round when proposing for round
//    {clock_round}. Possible mismatch between DagState and Core."
// at proposer.rs:352-354.
//
// The MC counterexample fires this assertion via a 3-step trace:
//   1. Initial: clockRound[*] = 1, dag = genesis only.
//   2. AddCertifiedCommit(s2, 2): certifiedCommitRound[s2] = 2; clockRound[s2]
//      jumps to 2 — modelling Core::add_certified_commits, which can advance
//      threshold_clock via threshold_clock.rs:65-80 (Ordering::Greater catch-up)
//      without filling in 2f+1 of round (clockRound-1) into the local DAG.
//   3. ForcePropose(s2): leader-timeout fires; try_propose(force=true) goes
//      through proposer.rs:170-364 with smart_select=false; the assertion at
//      :352-354 fails because dag[s2] has 0 blocks at quorum_round = 1.
//
// This reproduction triggers the same assertion by directly forcing the same
// state — DagState's threshold_clock_round jumps to 5 via a single
// `dag_state.accept_block` on a peer block at round 5 (the Ordering::Greater
// catch-up branch). We then call `Core::new_block(5, force=true)`, which
// dispatches through `try_propose(true)` -> `proposer.try_new_block(true)` ->
// `smart_ancestors_to_propose(5, smart_select=false)` and hits the assert.
//
// We do not modify production logic. We use the same DagState API
// (`accept_block`) that the production `BlockManager::try_accept_one_committed_block`
// uses to install certified-commit blocks while bypassing ancestor checks
// (block_manager.rs:183-209).

use consensus_config::Stake;
use consensus_types::block::BlockRef;

use crate::{
    block::{TestBlock, VerifiedBlock},
    context::Context,
    core::create_cores,
};

#[tokio::test(flavor = "current_thread", start_paused = true)]
#[should_panic(expected = "quorum not reached for parent round")]
async fn repro_bug2_force_propose_assertion() {
    let _ = telemetry_subscribers::init_for_testing();

    let (context, _signers) = Context::new_for_test(4);
    let authorities: Vec<Stake> = vec![1, 1, 1, 1];
    let mut cores = create_cores(context, authorities).await;
    // own_index = 0
    let fixture = &mut cores[0];

    // After Core::new_validator + recover_validator the validator has proposed
    // a round-1 block (threshold_clock started at 1, last_proposed went from
    // round 0 (genesis) to round 1). Sanity-check that.
    let initial_clock = fixture.dag_state.read().threshold_clock_round();
    assert_eq!(initial_clock, 1, "expected threshold_clock_round = 1 after recover");
    assert_eq!(
        fixture.core.last_proposed_round(),
        Some(1),
        "expected last_proposed_round = Some(1) after recover"
    );

    // Build a foreign peer block at round 5 referencing genesis. This is a
    // structurally well-formed block (round, author, ancestors all valid types).
    let genesis: Vec<BlockRef> = fixture
        .dag_state
        .read()
        .genesis_blocks()
        .iter()
        .map(|b| b.reference())
        .collect();
    let foreign_high = VerifiedBlock::new_for_test(
        TestBlock::new(5, 1)
            .set_timestamp_ms(500)
            .set_ancestors(genesis)
            .build(),
    );

    // Bypass BlockManager (modelling either the certified-commit fast-sync path
    // or any direct `accept_block` site). This drives threshold_clock through
    // the Ordering::Greater catch-up branch and bumps clockRound to 5.
    fixture
        .dag_state
        .write()
        .accept_block(foreign_high);

    let new_clock = fixture.dag_state.read().threshold_clock_round();
    assert_eq!(
        new_clock, 5,
        "threshold_clock should have caught up to round 5 via Ordering::Greater"
    );

    // Confirm dag[own] has nothing at quorum_round = 4 (we never filled it).
    let at_4 = fixture
        .dag_state
        .read()
        .get_uncommitted_blocks_at_round(4);
    assert!(
        at_4.is_empty(),
        "expected no blocks at quorum_round 4 — got {} blocks",
        at_4.len()
    );

    // Force-propose at round 5 — the path Core::new_block(round, force=true)
    // takes when LeaderTimeout fires. This is the exact production entry
    // exercised at proposer.rs assertion site.
    let _ = fixture.core.new_block(5, true);
    // Unreachable: assertion at proposer.rs:352-354 must fire.
}
