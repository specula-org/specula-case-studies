// Copyright (c) 2024 Espresso Systems
// HotShot trace-harness test — produced by Specula harness-generation.
//
// This test exercises the HotShot consensus task code in a controlled,
// deterministic fashion to produce a trace for TLA+ validation.
//
// Strategy
// --------
// We use `TestViewGenerator` (from `hotshot-testing`) to produce realistic,
// fully-signed proposals/votes. We then call task handlers
// (`QuorumProposalRecvTaskState::handle`, `QuorumProposalTaskState::handle`)
// directly on those events instead of using the panic-on-extra-output
// `run_test!` macro. The instrumented production code emits NDJSON trace
// lines to the file set via `tla_trace::set_path`.
//
// One test per scenario, each producing its own NDJSON file under
// `${TLA_TRACE_DIR}/<scenario>.ndjson`.

#![allow(unused_imports)]
#![allow(dead_code)]

use std::{sync::Arc, time::Duration};

use async_broadcast::broadcast;
use committable::Committable;
use futures::StreamExt;
use hotshot::tasks::task_state::CreateTaskState;
use hotshot_example_types::{
    block_types::TestMetadata,
    node_types::{MemoryImpl, TEST_VERSIONS, TestTypes, TestVersions},
    state_types::TestValidatedState,
};
use hotshot_task_impls::{
    events::HotShotEvent::{self, *},
    quorum_proposal::QuorumProposalTaskState,
    quorum_proposal_recv::QuorumProposalRecvTaskState,
    tla_trace,
};
use hotshot_testing::{
    helpers::{build_payload_commitment, build_system_handle},
    view_generator::TestViewGenerator,
};
use hotshot_types::{
    data::{EpochNumber, Leaf2, ViewNumber, null_block},
    traits::{
        consensus_api::ConsensusApi, election::Membership, node_implementation::NodeType,
        signature_key::SignatureKey,
    },
    utils::BuilderCommitment,
};
use sha2::Digest;
use vec1::vec1;

/// Resolve the trace file path. Uses TLA_TRACE_DIR env var if set, otherwise
/// falls back to a path relative to the testing crate's CARGO_MANIFEST_DIR.
fn trace_path(name: &str) -> String {
    let base = std::env::var("TLA_TRACE_DIR").unwrap_or_else(|_| {
        // CARGO_MANIFEST_DIR = .../crates/hotshot/testing
        format!(
            "{}/../../../../.specula-output/traces",
            env!("CARGO_MANIFEST_DIR")
        )
    });
    std::fs::create_dir_all(&base).ok();
    format!("{base}/{name}.ndjson")
}

/// Open a fresh trace file for this scenario via `tla_trace::set_path`.
/// The OnceLock writer is mutable (Mutex<Option<File>>), so re-opening is safe.
fn init_trace(name: &str) -> String {
    let path = trace_path(name);
    tla_trace::set_path(&path);
    eprintln!("TLA_TRACE_FILE={path}");
    path
}

// --------------------------------------------------------------------------
// Scenario A: HandleQuorumProposalRecv pipeline.
//
// Generate 3 successive views and feed proposal #2 into a
// QuorumProposalRecvTaskState. The instrumented `handle_quorum_proposal_recv`
// emits a HandleQuorumProposalRecv event.
// --------------------------------------------------------------------------
#[cfg(test)]
#[test_log::test(tokio::test(flavor = "multi_thread"))]
async fn tla_trace_handle_quorum_proposal_recv() {
    init_trace("handle_quorum_proposal_recv");

    let node_id = 2u64;
    let (handle, _, _, node_key_map) = build_system_handle::<TestTypes, MemoryImpl>(node_id).await;

    let membership = handle.hotshot.membership_coordinator.clone();
    let consensus = handle.hotshot.consensus();
    let mut consensus_writer = consensus.write().await;

    let mut generator =
        TestViewGenerator::generate(membership.clone(), node_key_map, TEST_VERSIONS.test);

    let mut proposals = Vec::new();
    let mut leaders = Vec::new();
    for view in (&mut generator).take(2).collect::<Vec<_>>().await {
        proposals.push(view.quorum_proposal.clone());
        leaders.push(view.leader_public_key);

        consensus_writer
            .update_leaf(
                Leaf2::from_quorum_proposal(&view.quorum_proposal.data),
                Arc::new(TestValidatedState::default()),
                None,
            )
            .unwrap();
    }
    drop(consensus_writer);

    let mut task =
        QuorumProposalRecvTaskState::<TestTypes, MemoryImpl>::create_from(&handle).await;
    let (event_sender, event_receiver) = broadcast(1024);

    let event = Arc::new(QuorumProposalRecv(proposals[1].clone(), leaders[1]));
    // Allow up to 5s for the async handler to complete. The handler may emit
    // more events (QuorumProposalValidated, ViewChange) — we discard them.
    let _ = tokio::time::timeout(
        Duration::from_secs(5),
        task.handle(event, event_sender.clone(), event_receiver.clone()),
    )
    .await;

    eprintln!("Scenario A complete");
}

// --------------------------------------------------------------------------
// Scenario B: ProposeLeader pipeline.
//
// Drive a QuorumProposalTaskState into proposing view 1 from genesis.
// The instrumented `publish_proposal` emits a ProposeLeader event.
// --------------------------------------------------------------------------
#[cfg(test)]
#[test_log::test(tokio::test(flavor = "multi_thread"))]
async fn tla_trace_propose_leader() {
    init_trace("propose_leader");

    let node_id = 1u64;
    let (handle, _, _, node_key_map) = build_system_handle::<TestTypes, MemoryImpl>(node_id).await;

    let membership = handle.hotshot.membership_coordinator.clone();
    let epoch_1_mem = match membership.membership_for_epoch(Some(EpochNumber::new(1))) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("epoch_1_mem unavailable: {e:?}");
            return;
        }
    };
    let version = handle
        .hotshot
        .upgrade_lock
        .version_infallible(ViewNumber::new(node_id));

    let payload_commitment =
        build_payload_commitment::<TestTypes>(&epoch_1_mem, ViewNumber::new(node_id), version)
            .await;

    let mut generator =
        TestViewGenerator::generate(membership.clone(), node_key_map, TEST_VERSIONS.test);

    let mut proposals = Vec::new();
    let mut vid_dispersals = Vec::new();
    let consensus = handle.hotshot.consensus();
    let mut consensus_writer = consensus.write().await;
    for view in (&mut generator).take(2).collect::<Vec<_>>().await {
        proposals.push(view.quorum_proposal.clone());
        vid_dispersals.push(view.vid_disperse.clone());

        consensus_writer
            .update_leaf(
                Leaf2::from_quorum_proposal(&view.quorum_proposal.data),
                Arc::new(TestValidatedState::default()),
                None,
            )
            .unwrap();
    }

    let num_storage_node = epoch_1_mem.total_nodes();
    let genesis_cert = proposals[0].data.justify_qc().clone();
    let builder_commitment = BuilderCommitment::from_raw_digest(sha2::Sha256::new().finalize());
    let builder_fee = match null_block::builder_fee::<TestTypes>(
        num_storage_node,
        TEST_VERSIONS.test.base,
    ) {
        Some(f) => f,
        None => {
            eprintln!("builder_fee unavailable; aborting scenario B");
            return;
        }
    };
    drop(consensus_writer);

    let mut task =
        QuorumProposalTaskState::<TestTypes, MemoryImpl>::create_from(&handle).await;
    let (event_sender, event_receiver) = broadcast(1024);

    // Step 1: feed VidDisperseSend.
    let evt1 = Arc::new(VidDisperseSend(
        vid_dispersals[0].clone(),
        handle.public_key(),
    ));
    let _ = tokio::time::timeout(
        Duration::from_secs(3),
        task.handle(evt1, event_receiver.clone(), event_sender.clone()),
    )
    .await;

    // Step 2: feed Qc2Formed (genesis cert) to trigger publish_proposal.
    let evt2 = Arc::new(Qc2Formed(either::Left(genesis_cert.clone())));
    let _ = tokio::time::timeout(
        Duration::from_secs(3),
        task.handle(evt2, event_receiver.clone(), event_sender.clone()),
    )
    .await;

    // Step 3: feed payload commitment which gates the proposal dependency.
    let evt3 = Arc::new(SendPayloadCommitmentAndMetadata(
        payload_commitment,
        builder_commitment,
        TestMetadata {
            num_transactions: 0,
        },
        ViewNumber::new(1),
        vec1![builder_fee.clone()],
    ));
    let _ = tokio::time::timeout(
        Duration::from_secs(5),
        task.handle(evt3, event_receiver.clone(), event_sender.clone()),
    )
    .await;

    // Drain the broadcast so any spawned futures complete and emit traces.
    tokio::time::sleep(Duration::from_millis(500)).await;

    eprintln!("Scenario B complete");
}

// --------------------------------------------------------------------------
// Scenario C: Crash and Recover (harness-side actions).
//
// These are emitted directly via the `tla_trace` API since the spec defines
// them as harness-controlled actions with no corresponding production code
// path. We synthesize one Crash and one Recover for node s1.
// --------------------------------------------------------------------------
#[cfg(test)]
#[test_log::test(tokio::test(flavor = "multi_thread"))]
async fn tla_trace_crash_recover() {
    init_trace("crash_recover");

    let nid = tla_trace::nid(0);

    let state_crashed = tla_trace::state_obj(1, 0, 0, 0, 0, 0, 0, true);
    tla_trace::emit("Crash", &nid, 1, 0, state_crashed, serde_json::json!({}));

    let state_recovered = tla_trace::state_obj(1, 0, 0, 0, 0, 0, 0, false);
    tla_trace::emit("Recover", &nid, 1, 0, state_recovered, serde_json::json!({}));

    eprintln!("Scenario C complete");
}
