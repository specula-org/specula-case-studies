// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0
//
// Reproduction for Specula MC bug F3 / CR1:
// `BaseCommitter::decide_leader_from_anchor` -> `DagState::ancestors_at_round`
// (and symmetrically `find_supported_block`) panic with
//   "Block {:?} should exist in DAG!"
// when an ancestor at `round > gc_round` is missing from `DagState`.
//
// The bug is the asymmetry between `is_certificate` (which has an explicit
//   assert!(reference.round <= gc_round, ...)
// fallback at base_committer.rs:250-256) and `find_supported_block` /
// `ancestors_at_round`, which unconditionally `panic!` if the ancestor lookup
// returns `None`.
//
// In production this precondition is supposed to be enforced by
// `BlockManager::try_accept_one_block` (suspends blocks whose `round > gc_round`
// ancestors are not in `DagState`). The MC counterexample shows that ANY code
// path that leaves `DagState[s]` with a block whose `round > gc_round` ancestor
// is missing (test scaffolding, race during gc advance, certified-commit
// fast-sync via `try_accept_one_committed_block` which bypasses the ancestor
// check) immediately panics the validator process on the next commit decision.
//
// Reproduction uses `DagState::accept_block` directly. This is the same API
// path that:
//   - `BlockManager::try_accept_one_committed_block` uses to install a
//     certified-commit block while skipping ancestor presence checks
//     (block_manager.rs:183-209), and
//   - the existing `tla_trace_scenarios.rs` test harness uses
//     (consensus/core/src/tests/tla_trace_scenarios.rs:118).
//
// We do NOT modify any production logic: we just exercise an externally
// reachable precondition that the production assertion does not defensively
// guard against.

use std::sync::Arc;

use consensus_config::AuthorityIndex;
use consensus_types::block::{BlockRef, BlockTimestampMs, Round};
use parking_lot::RwLock;

use crate::{
    base_committer::{BaseCommitter, BaseCommitterOptions},
    block::{TestBlock, VerifiedBlock, genesis_blocks},
    commit::{DEFAULT_WAVE_LENGTH, LeaderStatus},
    context::Context,
    dag_state::DagState,
    leader_schedule::{LeaderSchedule, LeaderSwapTable},
    storage::mem_store::MemStore,
};

fn build_block(
    r: Round,
    a: u32,
    ancestors: Vec<BlockRef>,
    ts: BlockTimestampMs,
) -> VerifiedBlock {
    VerifiedBlock::new_for_test(
        TestBlock::new(r, a)
            .set_timestamp_ms(ts)
            .set_ancestors(ancestors)
            .build(),
    )
}

#[tokio::test]
#[should_panic(expected = "should exist in DAG")]
async fn repro_bug1_ancestors_at_round_panic() {
    let _ = telemetry_subscribers::init_for_testing();

    let (mut context, _signers) = Context::new_for_test(4);
    context = context.with_authority_index(AuthorityIndex::new_for_test(0));
    let context = Arc::new(context);
    let dag_state = Arc::new(RwLock::new(DagState::new(
        context.clone(),
        Arc::new(MemStore::new()),
    )));
    let leader_schedule = Arc::new(LeaderSchedule::new(
        context.clone(),
        LeaderSwapTable::default(),
    ));
    let committer = BaseCommitter::new(
        context.clone(),
        leader_schedule,
        dag_state.clone(),
        BaseCommitterOptions {
            wave_length: DEFAULT_WAVE_LENGTH,
            leader_offset: 0,
            round_offset: 0,
        },
    );

    // Seed the genesis ancestors.
    let genesis: Vec<BlockRef> = genesis_blocks(context.as_ref())
        .iter()
        .map(|b| b.reference())
        .collect();

    // Round 1..=5: full DAG (4 blocks per round, all reference the previous round).
    let mut prev_refs = genesis;
    for r in 1u32..=5 {
        let mut new_refs = Vec::with_capacity(4);
        let mut blocks: Vec<VerifiedBlock> = Vec::with_capacity(4);
        for a in 0..4u32 {
            let ts = (r as BlockTimestampMs) * 100 + a as BlockTimestampMs;
            let b = build_block(r, a, prev_refs.clone(), ts);
            new_refs.push(b.reference());
            blocks.push(b);
        }
        for b in blocks {
            dag_state.write().accept_block(b);
        }
        prev_refs = new_refs;
    }

    // Round 6: build 4 blocks but INSERT only 3. Author 3's (6,3) block is
    // never inserted into DagState — we just keep its reference so the round-7
    // block below points at it. This is exactly the precondition state the MC
    // counterexample reaches: `dag[s]` contains a block whose `round > gc_round`
    // ancestor is missing.
    let mut round6_refs = Vec::with_capacity(4);
    let mut round6_blocks: Vec<VerifiedBlock> = Vec::with_capacity(4);
    for a in 0..4u32 {
        let ts = 600 + a as BlockTimestampMs;
        let b = build_block(6, a, prev_refs.clone(), ts);
        round6_refs.push(b.reference());
        round6_blocks.push(b);
    }
    for (a, b) in round6_blocks.into_iter().enumerate() {
        if a == 3 {
            continue;
        }
        dag_state.write().accept_block(b);
    }

    // Round 7 anchor: a single block by author 0 referencing all 4 round-6
    // blocks (including the missing (6, 3)). This is a perfectly well-formed
    // block from the protocol's structural standpoint — its parents are the
    // previous round, as required.
    let anchor = build_block(7, 0, round6_refs, 700);
    dag_state.write().accept_block(anchor.clone());

    // Pick a leader at round 3 (wave 1, decision_round = 5). With
    // wave_length = DEFAULT_WAVE_LENGTH = 3, elect_leader(3) succeeds.
    let leader_slot = committer
        .elect_leader(3)
        .expect("leader at round 3 should be electable");

    // Drive `try_indirect_decide` with the round-7 anchor. Internally this
    // calls `decide_leader_from_anchor` -> `DagState::ancestors_at_round(anchor, decision_round=5)`,
    // which walks the chain anchor@7 -> round-6 ancestors. Popping (6, 3) calls
    // `get_block(&(6, 3))` -> `None`, which panics at dag_state.rs:574:
    //     panic!("Block {:?} should exist in DAG!", block_ref);
    let leaders = [LeaderStatus::Commit(anchor)];
    let _ = committer.try_indirect_decide(leader_slot, leaders.iter());
    // Unreachable: panic must fire above.
}
