// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

//! TLA+ trace generation scenarios for Mysticeti consensus.
//!
//! Each test below drives the real `BaseCommitter` / `Linearizer` / `DagState`
//! code paths and emits NDJSON trace events via the `tla_trace` module.
//! Scenarios are activated by setting the `TLA_TRACE_FILE` environment
//! variable before the test runs; without it, all emit calls are no-ops.

use std::sync::Arc;

use consensus_config::AuthorityIndex;
use consensus_types::block::{BlockRef, BlockTimestampMs, Round};
use parking_lot::RwLock;

use crate::{
    base_committer::{BaseCommitter, BaseCommitterOptions},
    block::{BlockAPI, TestBlock, VerifiedBlock},
    commit::{DEFAULT_WAVE_LENGTH, LeaderStatus},
    context::Context,
    dag_state::DagState,
    leader_schedule::{LeaderSchedule, LeaderSwapTable},
    linearizer::Linearizer,
    storage::mem_store::MemStore,
    tla_trace,
};

/// Per-validator harness state.
struct ValidatorHarness {
    idx: AuthorityIndex,
    context: Arc<Context>,
    dag_state: Arc<RwLock<DagState>>,
    committer: crate::base_committer::BaseCommitter,
    linearizer: Linearizer,
    last_proposed_round: Round,
    decided: std::collections::BTreeMap<(Round, AuthorityIndex), LeaderStatus>,
}

/// Build N validators that share the same Committee but each has its own DagState.
fn make_validators(n: usize) -> Vec<ValidatorHarness> {
    let mut out = Vec::with_capacity(n);
    for i in 0..n {
        // Re-use new_for_test's committee construction; override own_index per validator.
        let (mut context, _keys) = Context::new_for_test(n);
        context = context.with_authority_index(AuthorityIndex::new_for_test(i as u32));
        let context = Arc::new(context);
        let dag_state = Arc::new(RwLock::new(DagState::new(
            context.clone(),
            Arc::new(MemStore::new()),
        )));
        let committer = BaseCommitter::new(
            context.clone(),
            Arc::new(LeaderSchedule::new(
                context.clone(),
                LeaderSwapTable::default(),
            )),
            dag_state.clone(),
            BaseCommitterOptions {
                wave_length: DEFAULT_WAVE_LENGTH,
                leader_offset: 0,
                round_offset: 0,
            },
        );
        let linearizer = Linearizer::new(context.clone(), dag_state.clone());
        out.push(ValidatorHarness {
            idx: AuthorityIndex::new_for_test(i as u32),
            context,
            dag_state,
            committer,
            linearizer,
            last_proposed_round: 0,
            decided: std::collections::BTreeMap::new(),
        });
    }
    out
}

/// Compute (clock_round, gc_round) snapshot from a DagState.
fn clock_gc(dag: &Arc<RwLock<DagState>>) -> (Round, Round) {
    let d = dag.read();
    (d.threshold_clock_round(), d.gc_round())
}

/// Helper: create a block at `(round, author)` with given ancestors.
fn build_block(round: Round, author: u32, ancestors: Vec<BlockRef>, ts: BlockTimestampMs) -> VerifiedBlock {
    VerifiedBlock::new_for_test(
        TestBlock::new(round, author)
            .set_timestamp_ms(ts)
            .set_ancestors(ancestors)
            .build(),
    )
}

/// Drive a fully connected round across all validators. Each author proposes
/// one block; each non-author observer delivers it. Real `accept_block` is
/// called on every validator's dag_state (the real DAG update path).
///
/// Phasing matters: every validator first proposes at the current clockRound
/// before any block is cross-delivered. Otherwise the threshold clock would
/// advance on the latest author's dag mid-round, causing its block to be
/// "proposed at round r" while clockRound is already r+1 — the spec rejects
/// that.
fn one_round_all_authors(
    validators: &mut [ValidatorHarness],
    round: Round,
    ancestors: &[Vec<BlockRef>],
) -> Vec<BlockRef> {
    let n = validators.len();
    let base_ts = round as BlockTimestampMs * 100;

    // Phase 1: each author produces a round-r block and accepts it locally.
    // clockRound[a] stays at `round` because dag[a] only has a@r at round r.
    let mut new_blocks: Vec<VerifiedBlock> = Vec::with_capacity(n);
    for a in 0..n {
        let ts = base_ts + a as BlockTimestampMs;
        let block = build_block(round, a as u32, ancestors[a].clone(), ts);
        validators[a].dag_state.write().accept_block(block.clone());
        validators[a].last_proposed_round = round;
        let (cr, gc) = clock_gc(&validators[a].dag_state);
        tla_trace::emit_propose(
            false,
            validators[a].idx,
            &block,
            cr,
            gc,
            validators[a].last_proposed_round,
        );
        new_blocks.push(block);
    }

    // Phase 2: cross-deliver. Each non-author observer accepts every block.
    for b in 0..n {
        for block in &new_blocks {
            if block.author().value() == b {
                continue;
            }
            validators[b].dag_state.write().accept_block(block.clone());
            let (cr2, gc2) = clock_gc(&validators[b].dag_state);
            tla_trace::emit_deliver_block(validators[b].idx, block, cr2, gc2);
        }
    }

    new_blocks.iter().map(|b| b.reference()).collect()
}

/// Like `one_round_all_authors`, but caller controls which subset of authors
/// actually proposes (the others stay silent), and which proposes are tagged
/// `force=true` (emitted as `ForcePropose` instead of `HonestPropose`).
fn one_round_subset(
    validators: &mut [ValidatorHarness],
    round: Round,
    ancestors: &[Vec<BlockRef>],
    silent: &[usize],
    force: &[usize],
) -> Vec<BlockRef> {
    let n = validators.len();
    let base_ts = round as BlockTimestampMs * 100;
    let mut new_blocks: Vec<VerifiedBlock> = Vec::new();
    let mut authoring: Vec<usize> = Vec::new();

    // Phase 1: each non-silent author proposes once.
    for a in 0..n {
        if silent.contains(&a) {
            continue;
        }
        let ts = base_ts + a as BlockTimestampMs;
        let block = build_block(round, a as u32, ancestors[a].clone(), ts);
        validators[a].dag_state.write().accept_block(block.clone());
        validators[a].last_proposed_round = round;
        let (cr, gc) = clock_gc(&validators[a].dag_state);
        tla_trace::emit_propose(
            force.contains(&a),
            validators[a].idx,
            &block,
            cr,
            gc,
            round,
        );
        new_blocks.push(block);
        authoring.push(a);
    }

    // Phase 2: every observer accepts every other author's block.
    for b in 0..n {
        for block in &new_blocks {
            if block.author().value() == b {
                continue;
            }
            validators[b].dag_state.write().accept_block(block.clone());
            let (cr2, gc2) = clock_gc(&validators[b].dag_state);
            tla_trace::emit_deliver_block(validators[b].idx, block, cr2, gc2);
        }
    }
    let _ = authoring;
    new_blocks.iter().map(|b| b.reference()).collect()
}

/// Run the direct-decide rule for every leader slot up to `up_to_round`, on
/// every validator, in ascending slot order. Emit `TryDirectDecide` per call.
/// Return the per-validator list of (leader_block_ref, LeaderStatus) for use
/// by linearization.
fn run_direct_decide_all(
    validators: &mut [ValidatorHarness],
    up_to_round: Round,
) -> Vec<Vec<(Round, AuthorityIndex, LeaderStatus)>> {
    let mut results: Vec<Vec<(Round, AuthorityIndex, LeaderStatus)>> =
        vec![vec![]; validators.len()];
    // Iterate leader rounds in ascending order so commits sequence correctly.
    for r in 1..=up_to_round {
        for v_idx in 0..validators.len() {
            let slot = match validators[v_idx].committer.elect_leader(r) {
                Some(s) => s,
                None => continue,
            };
            // Need decision_round visible in the DAG; if not, skip.
            let dec_round = r + DEFAULT_WAVE_LENGTH - 1;
            if dec_round > up_to_round {
                continue;
            }
            // Already decided?
            if validators[v_idx]
                .decided
                .contains_key(&(r, slot.authority))
            {
                continue;
            }
            let status = validators[v_idx].committer.try_direct_decide(slot);
            let (cr, gc) = clock_gc(&validators[v_idx].dag_state);
            let (outcome_tag, commit_ref): (&str, Option<BlockRef>) = match &status {
                LeaderStatus::Commit(b) => ("Commit", Some(b.reference())),
                LeaderStatus::Skip(_) => ("Skip", None),
                LeaderStatus::Undecided(_) => ("Undecided", None),
            };
            tla_trace::emit_try_direct_decide(
                validators[v_idx].idx,
                slot.authority,
                slot.round,
                outcome_tag,
                commit_ref.as_ref(),
                cr,
                gc,
            );
            validators[v_idx]
                .decided
                .insert((r, slot.authority), status.clone());
            results[v_idx].push((r, slot.authority, status));
        }
    }
    results
}

/// For each decided `Commit`, run `Linearizer::handle_commit` (real path) and
/// emit `Linearize` events.
fn run_linearize_all(
    validators: &mut [ValidatorHarness],
    decisions: &[Vec<(Round, AuthorityIndex, LeaderStatus)>],
) {
    for (v_idx, v_decisions) in decisions.iter().enumerate() {
        for (_r, _a, status) in v_decisions {
            if let LeaderStatus::Commit(leader_block) = status {
                let sub_dags = validators[v_idx]
                    .linearizer
                    .handle_commit(vec![leader_block.clone()]);
                for sd in sub_dags {
                    let (_cr, gc) = clock_gc(&validators[v_idx].dag_state);
                    let csl =
                        validators[v_idx].dag_state.read().last_commit_index() as u64;
                    tla_trace::emit_linearize(
                        validators[v_idx].idx,
                        &sd.leader,
                        csl,
                        gc,
                        sd.blocks.len(),
                    );
                }
            }
        }
    }
}

/// Genesis-blocks helper: returns the round-0 refs each validator already has
/// in its dag_state via `DagState::new`.
fn genesis_refs(validators: &[ValidatorHarness]) -> Vec<BlockRef> {
    crate::block::genesis_blocks(validators[0].context.as_ref())
        .iter()
        .map(|b| b.reference())
        .collect()
}

// ============================================================================
// SCENARIO 1: Normal happy-path commit
// ============================================================================
//
// Every validator proposes every round. Run for 6 rounds (= 2 full waves).
// Direct decide commits leaders at rounds 1, 2 (with decision rounds 3, 4).
// Linearize produces sub-dags. Exercises HonestPropose, DeliverBlock,
// TryDirectDecide(Commit), Linearize.

#[tokio::test]
async fn tla_trace_scenario_normal() {
    let _ = telemetry_subscribers::init_for_testing();
    let n = 4usize;
    let mut validators = make_validators(n);
    let mut ancestors: Vec<Vec<BlockRef>> = {
        let g = genesis_refs(&validators);
        vec![g; n]
    };
    let total_rounds: Round = 6;
    for r in 1..=total_rounds {
        let new_refs = one_round_all_authors(&mut validators, r, &ancestors);
        // Next round: every author's parents are the just-built layer.
        ancestors = vec![new_refs; n];
    }

    let decisions = run_direct_decide_all(&mut validators, total_rounds);
    run_linearize_all(&mut validators, &decisions);
}

// ============================================================================
// SCENARIO 2: Equivocation at a single slot (Family 1)
// ============================================================================
//
// Validator 3 (Byzantine in Trace.cfg) produces TWO blocks at round 2 with
// different ancestor sets. Different validators see the blocks in different
// orders. Direct decide must still converge on at most one Commit per slot
// (otherwise the BFT panic at base_committer.rs:108-112 fires).

#[tokio::test]
async fn tla_trace_scenario_equivocation() {
    let _ = telemetry_subscribers::init_for_testing();
    let n = 4usize;
    let byzantine_idx: u32 = 3;
    let mut validators = make_validators(n);
    let mut ancestors: Vec<Vec<BlockRef>> = {
        let g = genesis_refs(&validators);
        vec![g; n]
    };

    // Round 1: all 4 authors propose. s4 is Byzantine — emit ByzPropose for it.
    {
        let base_ts: BlockTimestampMs = 100;
        let mut new_blocks: Vec<VerifiedBlock> = Vec::new();
        for a in 0..n {
            let ts = base_ts + a as BlockTimestampMs;
            let block = build_block(1, a as u32, ancestors[a].clone(), ts);
            validators[a].dag_state.write().accept_block(block.clone());
            validators[a].last_proposed_round = 1;
            if a as u32 == byzantine_idx {
                tla_trace::emit_byz_propose(validators[a].idx, &block);
            } else {
                let (cr, gc) = clock_gc(&validators[a].dag_state);
                tla_trace::emit_propose(false, validators[a].idx, &block, cr, gc, 1);
            }
            new_blocks.push(block);
        }
        for b in 0..n {
            for block in &new_blocks {
                if block.author().value() == b {
                    continue;
                }
                validators[b].dag_state.write().accept_block(block.clone());
                let (cr2, gc2) = clock_gc(&validators[b].dag_state);
                tla_trace::emit_deliver_block(validators[b].idx, block, cr2, gc2);
            }
        }
        ancestors = vec![
            new_blocks.iter().map(|b| b.reference()).collect();
            n
        ];
    }

    // Round 2: s4 equivocates with TWO blocks. Both go to Messages via ByzPropose.
    // Split delivery: half the validators see block_a only, the other half also see block_b.
    {
        let base_ts: BlockTimestampMs = 200;
        let mut honest_blocks: Vec<VerifiedBlock> = Vec::new();
        for a in 0..n {
            if a as u32 == byzantine_idx {
                continue;
            }
            let ts = base_ts + a as BlockTimestampMs;
            let block = build_block(2, a as u32, ancestors[a].clone(), ts);
            validators[a].dag_state.write().accept_block(block.clone());
            validators[a].last_proposed_round = 2;
            let (cr, gc) = clock_gc(&validators[a].dag_state);
            tla_trace::emit_propose(false, validators[a].idx, &block, cr, gc, 2);
            honest_blocks.push(block);
        }
        // Byzantine s4 produces two blocks via ByzPropose. They are NOT accepted
        // into any dag_state via accept_block yet — they're "in flight" messages.
        // Honest validators accept them via DeliverBlock below.
        let byz_parents: Vec<BlockRef> = ancestors[byzantine_idx as usize].clone();
        let block_a = build_block(2, byzantine_idx, byz_parents.clone(), base_ts + 3);
        let block_b = build_block(2, byzantine_idx, byz_parents, base_ts + 4);
        tla_trace::emit_byz_propose(AuthorityIndex::new_for_test(byzantine_idx), &block_a);
        tla_trace::emit_byz_propose(AuthorityIndex::new_for_test(byzantine_idx), &block_b);
        // s4 itself "accepts" block_a (a Byzantine sees its own equivocation).
        validators[byzantine_idx as usize]
            .dag_state
            .write()
            .accept_block(block_a.clone());
        let (cr, gc) = clock_gc(&validators[byzantine_idx as usize].dag_state);
        tla_trace::emit_deliver_block(
            validators[byzantine_idx as usize].idx,
            &block_a,
            cr,
            gc,
        );
        // Honest validators receive the honest blocks plus a subset of Byzantine.
        for b in 0..n {
            if b as u32 == byzantine_idx {
                continue;
            }
            for block in &honest_blocks {
                if block.author().value() == b {
                    continue;
                }
                validators[b].dag_state.write().accept_block(block.clone());
                let (cr2, gc2) = clock_gc(&validators[b].dag_state);
                tla_trace::emit_deliver_block(validators[b].idx, block, cr2, gc2);
            }
            // s1, s2 see block_a; s3 sees block_b (split-brain delivery).
            let chosen = if b <= 1 { &block_a } else { &block_b };
            validators[b].dag_state.write().accept_block(chosen.clone());
            let (cr2, gc2) = clock_gc(&validators[b].dag_state);
            tla_trace::emit_deliver_block(validators[b].idx, chosen, cr2, gc2);
        }
        // Build round-3 ancestors using each validator's seen round-2 set.
        // Each validator references the round-2 blocks it actually saw.
        for v_idx in 0..n {
            let mut refs: Vec<BlockRef> = honest_blocks.iter().map(|b| b.reference()).collect();
            let chosen = if v_idx == byzantine_idx as usize || v_idx <= 1 {
                &block_a
            } else {
                &block_b
            };
            refs.push(chosen.reference());
            ancestors[v_idx] = refs;
        }
    }

    // Rounds 3..6: all honest. (Byzantine s4 keeps producing honest-looking
    // blocks but uses ByzPropose, since s4 stays in Byzantine for the cfg.)
    for r in 3..=6 {
        let base_ts = r as BlockTimestampMs * 100;
        let mut new_blocks: Vec<VerifiedBlock> = Vec::new();
        for a in 0..n {
            let ts = base_ts + a as BlockTimestampMs;
            let block = build_block(r, a as u32, ancestors[a].clone(), ts);
            validators[a].dag_state.write().accept_block(block.clone());
            validators[a].last_proposed_round = r;
            if a as u32 == byzantine_idx {
                tla_trace::emit_byz_propose(validators[a].idx, &block);
            } else {
                let (cr, gc) = clock_gc(&validators[a].dag_state);
                tla_trace::emit_propose(false, validators[a].idx, &block, cr, gc, r);
            }
            new_blocks.push(block);
        }
        for b in 0..n {
            for block in &new_blocks {
                if block.author().value() == b {
                    continue;
                }
                validators[b].dag_state.write().accept_block(block.clone());
                let (cr2, gc2) = clock_gc(&validators[b].dag_state);
                tla_trace::emit_deliver_block(validators[b].idx, block, cr2, gc2);
            }
        }
        ancestors = vec![
            new_blocks.iter().map(|b| b.reference()).collect();
            n
        ];
    }

    let decisions = run_direct_decide_all(&mut validators, 6);
    run_linearize_all(&mut validators, &decisions);
}

// ============================================================================
// SCENARIO 3: Crash + RecoverAmnesia (Family 2)
// ============================================================================
//
// Validator 1 crashes after round 2 and recovers with last_known_proposed = 0
// (the bug: f+1 amnesia threshold can underreport).

#[tokio::test]
async fn tla_trace_scenario_crash_recover() {
    let _ = telemetry_subscribers::init_for_testing();
    let n = 4usize;
    let mut validators = make_validators(n);
    let mut ancestors: Vec<Vec<BlockRef>> = {
        let g = genesis_refs(&validators);
        vec![g; n]
    };

    for r in 1..=2 {
        let new_refs = one_round_all_authors(&mut validators, r, &ancestors);
        ancestors = vec![new_refs; n];
    }

    // Crash validator 1: wipe its dag_state by replacing with a fresh one.
    let crashed_idx: usize = 1;
    tla_trace::emit_crash(validators[crashed_idx].idx);
    {
        let new_ctx = validators[crashed_idx].context.clone();
        let new_dag = Arc::new(RwLock::new(DagState::new(
            new_ctx.clone(),
            Arc::new(MemStore::new()),
        )));
        validators[crashed_idx].dag_state = new_dag.clone();
        validators[crashed_idx].committer = BaseCommitter::new(
            new_ctx.clone(),
            Arc::new(LeaderSchedule::new(
                new_ctx.clone(),
                LeaderSwapTable::default(),
            )),
            new_dag.clone(),
            BaseCommitterOptions {
                wave_length: DEFAULT_WAVE_LENGTH,
                leader_offset: 0,
                round_offset: 0,
            },
        );
        validators[crashed_idx].linearizer = Linearizer::new(new_ctx, new_dag);
        validators[crashed_idx].last_proposed_round = 0;
        validators[crashed_idx].decided.clear();
    }
    // Recover. lastKnownProposed = 0 (underreport — Family 2 bug surface).
    tla_trace::emit_recover_amnesia(validators[crashed_idx].idx, 0);

    // After recovery, re-deliver the pre-crash blocks from a peer (rounds 1..=2).
    // This mirrors the real `Synchronizer::fetch_blocks` path that backfills the
    // wiped DagState. Without it, later decide/linearize walks blow up on
    // missing ancestors. We rebuild from validator 0's DAG (peer 0 is honest).
    {
        let peer_blocks: Vec<VerifiedBlock> = {
            let g = validators[0].dag_state.read();
            // accept_block stores in recent_refs_by_authority; pull all non-genesis.
            (1u32..=2)
                .flat_map(|r| g.get_uncommitted_blocks_at_round(r))
                .collect()
        };
        for b in &peer_blocks {
            validators[crashed_idx]
                .dag_state
                .write()
                .accept_block(b.clone());
            let (cr, gc) = clock_gc(&validators[crashed_idx].dag_state);
            tla_trace::emit_deliver_block(validators[crashed_idx].idx, b, cr, gc);
        }
    }

    // Continue rounds 3..6 with the crashed validator silent.
    for r in 3..=6 {
        let new_refs = one_round_subset(&mut validators, r, &ancestors, &[crashed_idx], &[]);
        ancestors = vec![new_refs; validators.len()];
    }

    let decisions = run_direct_decide_all(&mut validators, 6);
    run_linearize_all(&mut validators, &decisions);
}

// ============================================================================
// SCENARIO 4: ForcePropose (Family 4)
// ============================================================================
//
// Validator 0 force-proposes at round 2 without waiting for a leader. We mark
// the proposal `force=true`. The block still has 2f+1 parents (so the real
// proposer assertion would pass) — Phase 3 can build a divergent variant
// that triggers the assert.

#[tokio::test]
async fn tla_trace_scenario_force_propose() {
    let _ = telemetry_subscribers::init_for_testing();
    let n = 4usize;
    let mut validators = make_validators(n);
    let mut ancestors: Vec<Vec<BlockRef>> = {
        let g = genesis_refs(&validators);
        vec![g; n]
    };

    // Round 1 honest.
    let r1_refs = one_round_all_authors(&mut validators, 1, &ancestors);
    ancestors = vec![r1_refs; n];

    // Round 2: validator 0 force-proposes; others normal.
    let r2_refs = one_round_subset(&mut validators, 2, &ancestors, &[], &[0]);
    ancestors = vec![r2_refs; n];

    for r in 3..=6 {
        let new_refs = one_round_all_authors(&mut validators, r, &ancestors);
        ancestors = vec![new_refs; n];
    }

    let decisions = run_direct_decide_all(&mut validators, 6);
    run_linearize_all(&mut validators, &decisions);
}
