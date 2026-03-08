// Copyright (c) Specula Project
// TLA+ trace validation scenario for Aptos BFT.
//
// This test exercises a basic consensus flow (3 nodes, 4 rounds)
// and emits NDJSON trace events compatible with the Trace.tla spec.
//
// NOTE: This file is placed into consensus/src/round_manager_tests/
// by the harness apply script.

use crate::{
    block_storage::BlockReader,
    round_manager::round_manager_tests::{NodeSetup, ProposalMsgType},
    test_utils::{consensus_runtime, timed_block_on},
    tla_trace,
};
use aptos_consensus_types::common::Round;
use aptos_logger::prelude::info;
use futures::StreamExt;
use serde_json::json;
use std::collections::HashMap;
use std::env;

/// Helper: capture the full TLA+ state snapshot for a node.
fn capture_state(node: &mut NodeSetup) -> serde_json::Value {
    // Safety data from safety_rules
    let mut cs = node
        .safety_rules_manager
        .client()
        .consensus_state()
        .expect("Failed to get consensus state");
    let sd = cs.safety_data();

    // Round and cert state from block_store
    let si = node.block_store.sync_info();
    let current_round = node.round_manager.round_state.current_round();
    let highest_qc_round = si.highest_quorum_cert().certified_block().round();
    let highest_ordered_round = si.highest_ordered_round();
    let committed_round = node.block_store.commit_root().round();

    json!({
        "lastVotedRound": sd.last_voted_round,
        "preferredRound": sd.preferred_round,
        "oneChainRound": sd.one_chain_round,
        "highestTimeoutRound": sd.highest_timeout_round,
        "currentRound": current_round,
        "highestQCRound": highest_qc_round,
        "highestOrderedRound": highest_ordered_round,
        "committedRound": committed_round,
    })
}

/// Helper: get the TLA+ nid for a node.
fn node_nid(node: &NodeSetup) -> String {
    let hex = format!("{:x}", node.signer.author());
    tla_trace::nid(&hex)
}

/// Drive one round of consensus across all nodes.
/// Returns the round number that was processed.
fn drive_round(
    runtime: &tokio::runtime::Runtime,
    nodes: &mut Vec<NodeSetup>,
    expected_round: Round,
    num_nodes: usize,
) {
    info!(
        "=== Driving round {} with {} nodes ===",
        expected_round, num_nodes
    );

    // Phase 1: Each node receives the proposal and votes.
    // The proposer node already generated and broadcast the proposal
    // during process_new_round_event (triggered by QC/TC processing).
    for node_idx in 0..num_nodes {
        let node = &mut nodes[node_idx];
        let proposal_msg_type =
            timed_block_on(runtime, node.next_opt_or_normal_proposal());

        match proposal_msg_type {
            ProposalMsgType::Normal(proposal_msg) => {
                let proposer = proposal_msg
                    .proposal()
                    .author()
                    .expect("proposal has author");
                let proposer_hex = format!("{:x}", proposer);
                let proposer_nid = tla_trace::nid(&proposer_hex);
                let proposal_round = proposal_msg.proposal().round();
                let proposal_id = format!("{:x}", proposal_msg.proposal().id());

                // Emit Propose event (only for the proposer, first time we see this round)
                if node.signer.author() == proposer && tla_trace::is_active() {
                    let nid = node_nid(node);
                    let epoch = proposal_msg.proposal().epoch();
                    tla_trace::emit_event(
                        "Propose",
                        &nid,
                        proposal_round,
                        epoch,
                        json!({"proposalValue": proposal_id}),
                        None,
                    );
                }

                // Process proposal (internally: insert block + vote)
                timed_block_on(
                    runtime,
                    node.round_manager.process_proposal_msg(proposal_msg),
                )
                .unwrap();

                // Emit ReceiveProposal event
                if tla_trace::is_active() {
                    let nid = node_nid(node);
                    let state = capture_state(node);
                    tla_trace::emit_event(
                        "ReceiveProposal",
                        &nid,
                        proposal_round,
                        1, // epoch
                        state.clone(),
                        Some(json!({
                            "source": proposer_nid,
                            "round": proposal_round,
                        })),
                    );
                }

                // Emit CastVote event
                if tla_trace::is_active() {
                    let nid = node_nid(node);
                    let state = capture_state(node);
                    tla_trace::emit_event(
                        "CastVote",
                        &nid,
                        proposal_round,
                        1, // epoch
                        state,
                        None,
                    );
                }
            },
            ProposalMsgType::Optimistic(opt_proposal_msg) => {
                let proposer = opt_proposal_msg.proposer();
                let proposer_hex = format!("{:x}", proposer);
                let proposer_nid = tla_trace::nid(&proposer_hex);
                let proposal_round = opt_proposal_msg.round();
                let proposal_epoch = opt_proposal_msg.epoch();

                // Emit Propose event (only for the proposer)
                if node.signer.author() == proposer && tla_trace::is_active() {
                    let nid = node_nid(node);
                    tla_trace::emit_event(
                        "Propose",
                        &nid,
                        proposal_round,
                        proposal_epoch,
                        json!({"proposalValue": format!("opt_{}", proposal_round)}),
                        None,
                    );
                }

                // Process optimistic proposal (two-step)
                timed_block_on(
                    runtime,
                    node.round_manager.process_opt_proposal_msg(opt_proposal_msg),
                )
                .unwrap();

                let opt_block_data = timed_block_on(
                    runtime,
                    node.processed_opt_proposal_rx.next(),
                )
                .unwrap();

                timed_block_on(
                    runtime,
                    node.round_manager.process_opt_proposal(opt_block_data),
                )
                .unwrap();

                // Emit ReceiveProposal event
                if tla_trace::is_active() {
                    let nid = node_nid(node);
                    let state = capture_state(node);
                    tla_trace::emit_event(
                        "ReceiveProposal",
                        &nid,
                        proposal_round,
                        proposal_epoch,
                        state.clone(),
                        Some(json!({
                            "source": proposer_nid,
                            "round": proposal_round,
                        })),
                    );
                }

                // Emit CastVote event
                if tla_trace::is_active() {
                    let nid = node_nid(node);
                    let state = capture_state(node);
                    tla_trace::emit_event(
                        "CastVote",
                        &nid,
                        proposal_round,
                        proposal_epoch,
                        state,
                        None,
                    );
                }
            },
        }
    }

    // Phase 2: Each node collects and processes votes from all other nodes.
    for node_idx in 0..num_nodes {
        let node = &mut nodes[node_idx];
        let nid = node_nid(node);
        let node_author = node.signer.author();

        let mut votes = Vec::new();
        for _ in 0..num_nodes {
            votes.push(timed_block_on(runtime, node.next_vote()));
        }

        for vote_msg in votes {
            let vote_author = vote_msg.vote().author();
            let vote_round = vote_msg.vote().vote_data().proposed().round();

            // Emit ReceiveVote (skip self-votes)
            if vote_author != node_author && tla_trace::is_active() {
                let vote_author_hex = format!("{:x}", vote_author);
                let vote_nid = tla_trace::nid(&vote_author_hex);
                tla_trace::emit_event(
                    "ReceiveVote",
                    &nid,
                    vote_round,
                    1, // epoch
                    json!({}),
                    Some(json!({
                        "source": vote_nid,
                        "round": vote_round,
                    })),
                );
            }

            let pre_qc_round = node
                .block_store
                .sync_info()
                .highest_quorum_cert()
                .certified_block()
                .round();

            timed_block_on(
                runtime,
                node.round_manager.process_vote_msg(vote_msg),
            )
            .unwrap();

            // Check if QC was formed
            let post_qc_round = node
                .block_store
                .sync_info()
                .highest_quorum_cert()
                .certified_block()
                .round();

            if post_qc_round > pre_qc_round && tla_trace::is_active() {
                let state = capture_state(node);
                tla_trace::emit_event(
                    "FormQC",
                    &nid,
                    post_qc_round,
                    1, // epoch
                    json!({
                        "highestQCRound": state["highestQCRound"],
                        "highestOrderedRound": state["highestOrderedRound"],
                    }),
                    None,
                );
            }
        }
    }
}

#[test]
fn tla_trace_basic_consensus() {
    // Check if tracing is requested
    let trace_file = env::var("TLA_TRACE_FILE")
        .unwrap_or_else(|_| "../traces/trace.ndjson".to_string());

    let runtime = consensus_runtime();
    let mut playground =
        crate::network_tests::NetworkPlayground::new(runtime.handle().clone());

    let num_nodes = 3;

    // Create nodes with default config (order votes disabled for simplicity)
    let mut nodes = NodeSetup::create_nodes(
        &mut playground,
        runtime.handle().clone(),
        num_nodes,
        None,  // all are proposers (rotating)
        None,  // default onchain config
        None,  // no block filter
        None,  // default local config
        None,  // default randomness config
        None,  // default jwk config
        false, // no quorum store payloads
    );

    // Start the network playground to route messages between nodes
    runtime.spawn(playground.start());

    // Build server mapping: PeerId hex → "s1", "s2", "s3"
    let mut server_map = HashMap::new();
    for (i, node) in nodes.iter().enumerate() {
        let hex = format!("{:x}", node.signer.author());
        let sid = format!("s{}", i + 1);
        info!("Server mapping: {} → {}", hex, sid);
        server_map.insert(hex, sid);
    }

    // Initialize tracing
    tla_trace::init(&trace_file, server_map);
    info!("TLA+ trace file: {}", trace_file);

    // Drive 4 rounds of consensus.
    // With rotating proposer and 3 nodes:
    //   Round 1: node[0] proposes
    //   Round 2: node[1] proposes
    //   Round 3: node[2] proposes
    //   Round 4: node[0] proposes
    for round in 1..=4u64 {
        drive_round(&runtime, &mut nodes, round, num_nodes);
    }

    info!("TLA+ trace scenario completed successfully");
}
