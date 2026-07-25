/// TLA+ Trace collection tests for Autobahn BFT.
///
/// These tests drive the consensus protocol through Core by injecting messages
/// via channels, exercising the 3-phase flow (Prepare → Confirm → Commit)
/// and the view-change (timeout → TC → new Prepare) paths.
///
/// Set TLA_TRACE_FILE env var before running to enable trace output.

use super::*;
use crate::common::{
    certificate, committee_with_base_port, header_from_cert, headers, keys,
};
use config::Parameters;
use crypto::Hash;
use std::{fs, time::Duration};
use tokio::{sync::mpsc::channel, time::timeout};
use serial_test::serial;

/// Create votes for a header with consensus votes for a specific slot.
fn votes_for_slot(header: &Header, consensus_digests: Vec<Digest>, slot: u64) -> Vec<Vote> {
    keys()
        .into_iter()
        .map(|(author, secret)| {
            let vote = Vote {
                id: header.id.clone(),
                height: header.height,
                origin: header.author,
                author,
                signature: Signature::default(),
                consensus_votes: consensus_digests
                    .iter()
                    .map(|x| (slot, x.clone(), Signature::new(x, &secret)))
                    .collect(),
            };
            Vote {
                signature: Signature::new(&vote.digest(), &secret),
                ..vote
            }
        })
        .collect()
}

/// Create a header carrying consensus messages, using a parent certificate.
fn make_header(parent_cert: Certificate, consensus_messages: HashMap<Digest, ConsensusMessage>) -> Header {
    let (author, secret) = keys().pop().unwrap();
    let header = Header {
        author,
        height: parent_cert.height + 1,
        parent_cert,
        consensus_messages,
        ..Header::default()
    };
    Header {
        id: header.digest(),
        signature: Signature::new(&header.digest(), &secret),
        ..header
    }
}

/// Helper: spawn a Core node with the given parameters.
async fn spawn_core(
    base_port: u16,
    params: Parameters,
) -> (
    tokio::sync::mpsc::Sender<PrimaryMessage>,
    tokio::sync::mpsc::Sender<Header>,
    tokio::sync::mpsc::Receiver<Certificate>,
    tokio::sync::mpsc::Receiver<ConsensusMessage>,
    tokio::sync::mpsc::Receiver<ConsensusMessage>,
    PublicKey,
    config::Committee,
    &'static str,
) {
    let mut all_keys = keys();
    let _ = all_keys.pop().unwrap(); // Skip key[3]
    let (name, secret) = all_keys.pop().unwrap();
    let signature_service = SignatureService::new(secret);
    let committee = committee_with_base_port(base_port);

    let (tx_sync_headers, _) = channel(1);
    let (tx_sync_certificates, _) = channel(1);
    let (tx_primary_messages, rx_primary_messages) = channel(10);
    let (_, rx_headers_loopback) = channel(1);
    let (tx_headers, rx_headers) = channel(10);
    let (tx_parents, rx_parents) = channel(10);
    let (tx_committer, rx_committer) = channel(10);
    let (_, rx_request_header_sync) = channel(1);
    let (tx_info, rx_info) = channel(10);
    let (_, rx_header_waiter_instances) = channel(1);

    let db_path: &'static str = match base_port {
        18_000 => ".db_test_tla_trace_consensus",
        19_000 => ".db_test_tla_trace_timeout",
        20_000 => ".db_test_tla_trace_multi",
        23_000 => ".db_test_tla_leader_prepare",
        24_000 => ".db_test_tla_vc_leader",
        _ => ".db_test_tla_trace_other",
    };
    let _ = fs::remove_dir_all(db_path);
    let store = Store::new(db_path).unwrap();

    let synchronizer = Synchronizer::new(
        name,
        &committee,
        store.clone(),
        tx_sync_headers,
        tx_sync_certificates,
    );
    let leader_elector = LeaderElector::new(committee.clone());

    Core::spawn(
        name,
        committee.clone(),
        store.clone(),
        synchronizer,
        signature_service,
        Arc::new(AtomicU64::new(0)),
        50,
        rx_primary_messages,
        rx_headers_loopback,
        rx_header_waiter_instances,
        rx_headers,
        tx_committer,
        tx_parents,
        rx_request_header_sync,
        tx_info,
        leader_elector,
        params.timeout_delay,
        params.use_optimistic_tips,
        params.use_parallel_proposals,
        params.k,
        params.use_fast_path,
        params.fast_path_timeout,
        params.use_ride_share,
        params.car_timeout,
        false,
        0,
        0,
    );

    tokio::time::sleep(Duration::from_millis(100)).await;

    (tx_primary_messages, tx_headers, rx_parents, rx_committer, rx_info, name, committee, db_path)
}

/// Drive one full slot through the 3-phase consensus.
/// Returns the last header used (for chaining into the next slot).
async fn drive_slot(
    slot: u64,
    proposals: &HashMap<PublicKey, Proposal>,
    parent_header: &Header,
    tx_msgs: &tokio::sync::mpsc::Sender<PrimaryMessage>,
    tx_headers: &tokio::sync::mpsc::Sender<Header>,
    rx_info: &mut tokio::sync::mpsc::Receiver<ConsensusMessage>,
    rx_committer: &mut tokio::sync::mpsc::Receiver<ConsensusMessage>,
) -> Option<Header> {
    // Create Prepare
    let prepare_msg = ConsensusMessage::Prepare {
        slot,
        view: 1,
        tc: None,
        qc_ticket: None,
        proposals: proposals.clone(),
    };

    let mut consensus_messages: HashMap<Digest, ConsensusMessage> = HashMap::new();
    consensus_messages.insert(prepare_msg.digest(), prepare_msg.clone());

    let parent_cert = certificate(parent_header);
    let prepare_header = make_header(parent_cert, consensus_messages.clone());
    let prepare_digests = vec![prepare_msg.digest()];

    tx_headers.send(prepare_header.clone()).await.unwrap();
    tokio::time::sleep(Duration::from_millis(200)).await;

    // Send votes for Prepare
    for vote in votes_for_slot(&prepare_header, prepare_digests, slot) {
        tx_msgs.send(PrimaryMessage::Vote(vote)).await.unwrap();
    }

    // Wait for Confirm
    let confirm_result = timeout(Duration::from_millis(3000), rx_info.recv()).await;
    let confirm_msg = match confirm_result {
        Ok(Some(msg)) => msg,
        _ => {
            eprintln!("[drive_slot] No Confirm for slot {} (timeout)", slot);
            return None;
        }
    };

    match &confirm_msg {
        ConsensusMessage::Confirm { slot: s, view: v, .. } => {
            eprintln!("[drive_slot] Slot {} Confirm view {}", s, v);
        }
        other => {
            eprintln!("[drive_slot] Expected Confirm, got {:?} for slot {}", std::mem::discriminant(other), slot);
            return None;
        }
    }

    // Build Confirm header and send votes
    consensus_messages.clear();
    consensus_messages.insert(confirm_msg.digest(), confirm_msg.clone());
    let confirm_parent_cert = certificate(&prepare_header);
    let confirm_header = make_header(confirm_parent_cert, consensus_messages.clone());
    let confirm_digests = vec![confirm_msg.digest()];

    tx_headers.send(confirm_header.clone()).await.unwrap();
    tokio::time::sleep(Duration::from_millis(500)).await;

    for vote in votes_for_slot(&confirm_header, confirm_digests, slot) {
        tx_msgs.send(PrimaryMessage::Vote(vote)).await.unwrap();
    }

    // Wait for Commit
    let commit_result = timeout(Duration::from_millis(3000), rx_info.recv()).await;
    let commit_msg = match commit_result {
        Ok(Some(msg)) => msg,
        _ => {
            eprintln!("[drive_slot] No Commit for slot {} (timeout)", slot);
            return None;
        }
    };

    match &commit_msg {
        ConsensusMessage::Commit { slot: s, view: v, .. } => {
            eprintln!("[drive_slot] Slot {} Commit view {}", s, v);
        }
        _ => {
            eprintln!("[drive_slot] Expected Commit for slot {}", slot);
            return None;
        }
    }

    // Deliver Commit
    consensus_messages.clear();
    consensus_messages.insert(commit_msg.digest(), commit_msg.clone());
    let commit_parent_cert = certificate(&confirm_header);
    let commit_header = make_header(commit_parent_cert, consensus_messages);

    tx_headers.send(commit_header.clone()).await.unwrap();
    let _ = timeout(Duration::from_millis(3000), rx_committer.recv()).await;
    eprintln!("[drive_slot] Slot {} committed!", slot);

    Some(commit_header)
}

/// Full 3-phase consensus: Prepare → Confirm → Commit for slot 1.
/// Exercises: ReceivePrepare, SendConfirm, ReceiveConfirm, SendCommitSlow, ReceiveCommit
#[tokio::test]
#[serial]
async fn tla_trace_consensus() {
    let mut params = Parameters::default();
    params.k = 1;
    params.use_fast_path = false;
    params.timeout_delay = 30_000; // Long timeout to avoid spurious timeouts

    let (tx_msgs, tx_headers, mut rx_parents, mut rx_committer, mut rx_info, _name, _committee, db_path) =
        spawn_core(18_000, params).await;

    // Drain genesis cert
    let _ = timeout(Duration::from_millis(500), rx_parents.recv()).await;

    // Send headers from all nodes so proposals are available
    let header_list = headers();
    for h in &header_list {
        tx_msgs
            .send(PrimaryMessage::Header(h.clone(), false))
            .await
            .unwrap();
    }
    tokio::time::sleep(Duration::from_millis(200)).await;

    // Build proposals
    let mut proposals: HashMap<PublicKey, Proposal> = HashMap::new();
    for h in &header_list {
        proposals.insert(
            h.author,
            Proposal {
                header_digest: h.digest(),
                height: h.height(),
            },
        );
    }

    // Drive slot 1
    let last = drive_slot(1, &proposals, &header_list[0], &tx_msgs, &tx_headers, &mut rx_info, &mut rx_committer).await;

    tokio::time::sleep(Duration::from_millis(200)).await;
    let _ = fs::remove_dir_all(db_path);
}

/// Timeout scenario: node times out and sends Timeout.
/// Exercises: SendTimeout, AdvanceView paths.
#[tokio::test]
#[serial]
async fn tla_trace_timeout() {
    let mut params = Parameters::default();
    params.timeout_delay = 500; // Short timeout for quick trace

    let (_tx_msgs, _tx_headers, mut rx_parents, _rx_committer, _rx_info, _name, _committee, db_path) =
        spawn_core(19_000, params).await;

    // Wait for timeout to fire
    tokio::time::sleep(Duration::from_millis(800)).await;
    let _ = timeout(Duration::from_millis(200), rx_parents.recv()).await;

    // Wait for second timeout
    tokio::time::sleep(Duration::from_millis(800)).await;

    eprintln!("[tla_trace_test] Timeout scenario completed");
    let _ = fs::remove_dir_all(db_path);
}

/// Multi-slot scenario: commit slots 1 through 5 sequentially.
/// Each slot produces ~5 events, giving 25+ total.
/// Exercises: ReceivePrepare, SendConfirm, ReceiveConfirm, SendCommitSlow, ReceiveCommit across slots.
#[tokio::test]
#[serial]
async fn tla_trace_multi_slot() {
    let mut params = Parameters::default();
    params.k = 1; // Sequential slots (k=1 avoids overflow for low slot numbers)
    params.use_fast_path = false;
    params.timeout_delay = 30_000; // Long timeout to avoid spurious timeouts

    let (tx_msgs, tx_headers, mut rx_parents, mut rx_committer, mut rx_info, _name, _committee, db_path) =
        spawn_core(20_000, params).await;

    let _ = timeout(Duration::from_millis(500), rx_parents.recv()).await;

    let header_list = headers();
    for h in &header_list {
        tx_msgs
            .send(PrimaryMessage::Header(h.clone(), false))
            .await
            .unwrap();
    }
    tokio::time::sleep(Duration::from_millis(200)).await;

    let mut proposals: HashMap<PublicKey, Proposal> = HashMap::new();
    for h in &header_list {
        proposals.insert(
            h.author,
            Proposal {
                header_digest: h.digest(),
                height: h.height(),
            },
        );
    }

    // Drive slots 1 through 5
    let mut last_header = header_list[0].clone();
    for slot in 1..=5 {
        eprintln!("[multi_slot] === Starting slot {} ===", slot);
        match drive_slot(slot, &proposals, &last_header, &tx_msgs, &tx_headers, &mut rx_info, &mut rx_committer).await {
            Some(h) => last_header = h,
            None => {
                eprintln!("[multi_slot] Slot {} failed, stopping", slot);
                break;
            }
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }

    tokio::time::sleep(Duration::from_millis(200)).await;
    let _ = fs::remove_dir_all(db_path);
}

/// Fast-path scenario: Prepare → Commit (skipping Confirm).
/// Exercises: ReceivePrepare, SendCommitFast, ReceiveCommit
#[tokio::test]
#[serial]
async fn tla_trace_fast_path() {
    let mut params = Parameters::default();
    params.k = 1;
    params.use_fast_path = true;
    params.fast_path_timeout = 30_000; // Long fast-path timeout
    params.timeout_delay = 30_000;

    let (tx_msgs, tx_headers, mut rx_parents, mut rx_committer, mut rx_info, _name, _committee, db_path) =
        spawn_core(21_000, params).await;

    let _ = timeout(Duration::from_millis(500), rx_parents.recv()).await;

    let header_list = headers();
    for h in &header_list {
        tx_msgs
            .send(PrimaryMessage::Header(h.clone(), false))
            .await
            .unwrap();
    }
    tokio::time::sleep(Duration::from_millis(200)).await;

    let mut proposals: HashMap<PublicKey, Proposal> = HashMap::new();
    for h in &header_list {
        proposals.insert(
            h.author,
            Proposal {
                header_digest: h.digest(),
                height: h.height(),
            },
        );
    }

    // Create Prepare for slot 1
    let prepare_msg = ConsensusMessage::Prepare {
        slot: 1,
        view: 1,
        tc: None,
        qc_ticket: None,
        proposals: proposals.clone(),
    };

    let mut consensus_messages: HashMap<Digest, ConsensusMessage> = HashMap::new();
    consensus_messages.insert(prepare_msg.digest(), prepare_msg.clone());

    let parent_cert = certificate(&header_list[0]);
    let prepare_header = make_header(parent_cert, consensus_messages.clone());
    let prepare_digests = vec![prepare_msg.digest()];

    tx_headers.send(prepare_header.clone()).await.unwrap();
    tokio::time::sleep(Duration::from_millis(200)).await;

    // Send ALL 4 votes to meet fast threshold (3f+1=4)
    for vote in votes_for_slot(&prepare_header, prepare_digests, 1) {
        tx_msgs.send(PrimaryMessage::Vote(vote)).await.unwrap();
    }

    // Expect Commit directly (fast path skips Confirm)
    let result = timeout(Duration::from_millis(3000), rx_info.recv()).await;
    match result {
        Ok(Some(msg)) => {
            eprintln!("[fast_path] Got message: {:?}", std::mem::discriminant(&msg));
        }
        _ => eprintln!("[fast_path] No response within timeout"),
    }

    // Try to get ReceiveCommit by delivering the commit
    let commit_result = timeout(Duration::from_millis(3000), rx_info.recv()).await;
    if let Ok(Some(commit_msg)) = commit_result {
        consensus_messages.clear();
        consensus_messages.insert(commit_msg.digest(), commit_msg);
        let commit_parent_cert = certificate(&prepare_header);
        let commit_header = make_header(commit_parent_cert, consensus_messages);
        tx_headers.send(commit_header).await.unwrap();
        let _ = timeout(Duration::from_millis(3000), rx_committer.recv()).await;
        eprintln!("[fast_path] Committed!");
    }

    tokio::time::sleep(Duration::from_millis(200)).await;
    let _ = fs::remove_dir_all(db_path);
}

/// View change scenario: inject timeouts from other nodes to form TC.
/// Exercises: SendTimeout, AdvanceView, GeneratePrepareFromTC
#[tokio::test]
#[serial]
async fn tla_trace_view_change() {
    let mut params = Parameters::default();
    params.timeout_delay = 300; // Short timeout
    params.k = 1;
    params.use_fast_path = false;

    let (tx_msgs, tx_headers, mut rx_parents, mut rx_committer, mut rx_info, name, committee, db_path) =
        spawn_core(22_000, params).await;

    let _ = timeout(Duration::from_millis(500), rx_parents.recv()).await;

    // Wait for the node's own timeout to fire for slot 1, view 1
    tokio::time::sleep(Duration::from_millis(600)).await;

    // Inject timeouts from other nodes to reach 2f+1=3 total (including our own)
    let all_keys = keys();
    for (pk, sk) in &all_keys {
        if *pk == name {
            continue; // Skip our own node (already sent its timeout)
        }
        let timeout_msg = Timeout::new_from_key(
            None,
            None,
            1, // slot
            1, // view
            *pk,
            sk,
        );
        tx_msgs.send(PrimaryMessage::Timeout(timeout_msg)).await.unwrap();
    }

    // Wait for TC formation + possible new prepare
    tokio::time::sleep(Duration::from_millis(500)).await;

    // Try to receive any output
    let _ = timeout(Duration::from_millis(1000), rx_info.recv()).await;

    eprintln!("[view_change] View change scenario completed");
    let _ = fs::remove_dir_all(db_path);
}

/// Leader-prepare scenario: Core acts as leader and emits SendPrepare.
/// The test node (n2) is leader for slot 4 at view 1.
/// After committing slots 1-3, send fresh headers to satisfy coverage,
/// then wait for the Core to autonomously propose slot 4.
/// Exercises: SendPrepare (+ ReceivePrepare, SendConfirm, etc. for earlier slots)
#[tokio::test]
#[serial]
async fn tla_trace_leader_prepare() {
    let mut params = Parameters::default();
    params.k = 1;
    params.use_fast_path = false;
    params.timeout_delay = 30_000;

    let (tx_msgs, tx_headers, mut rx_parents, mut rx_committer, mut rx_info, _name, _committee, db_path) =
        spawn_core(23_000, params).await;

    let _ = timeout(Duration::from_millis(500), rx_parents.recv()).await;

    let header_list = headers();
    for h in &header_list {
        tx_msgs
            .send(PrimaryMessage::Header(h.clone(), false))
            .await
            .unwrap();
    }
    tokio::time::sleep(Duration::from_millis(200)).await;

    let mut proposals: HashMap<PublicKey, Proposal> = HashMap::new();
    for h in &header_list {
        proposals.insert(
            h.author,
            Proposal {
                header_digest: h.digest(),
                height: h.height(),
            },
        );
    }

    // Drive slots 1-3 as follower (commit all)
    let mut last_header = header_list[0].clone();
    for slot in 1..=3 {
        eprintln!("[leader_prepare] === Driving slot {} ===", slot);
        match drive_slot(slot, &proposals, &last_header, &tx_msgs, &tx_headers, &mut rx_info, &mut rx_committer).await {
            Some(h) => last_header = h,
            None => {
                eprintln!("[leader_prepare] Slot {} failed, stopping", slot);
                break;
            }
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }

    // Send fresh headers from multiple keys to satisfy coverage check.
    // The Core (n2) is leader for slot 4 at view 1 and has a buffered
    // prepare ticket. After receiving higher-height headers, the coverage
    // check passes and SendPrepare is emitted.
    for h in header_list.iter().take(3) {
        let cert = certificate(h);
        let h2 = header_from_cert(&cert);
        tx_msgs.send(PrimaryMessage::Header(h2, false)).await.unwrap();
    }
    tokio::time::sleep(Duration::from_millis(500)).await;

    // Check if Core produced a Prepare (output on rx_info)
    let result = timeout(Duration::from_millis(2000), rx_info.recv()).await;
    match result {
        Ok(Some(msg)) => {
            eprintln!("[leader_prepare] Got output: {:?}", std::mem::discriminant(&msg));
        }
        _ => eprintln!("[leader_prepare] No output (SendPrepare may still be in trace)"),
    }

    tokio::time::sleep(Duration::from_millis(200)).await;
    let _ = fs::remove_dir_all(db_path);
}

/// View-change leader scenario: Core becomes leader after timeout certificate.
/// The test node (n2) is leader for (slot=3, view=2).
/// After committing slots 1-2 (activating slot 3), let slot 3 timeout,
/// then inject external timeouts to form TC. Core emits GeneratePrepareFromTC.
/// Exercises: GeneratePrepareFromTC, AdvanceView, SendTimeout
#[tokio::test]
#[serial]
async fn tla_trace_vc_leader() {
    let mut params = Parameters::default();
    params.k = 1;
    params.use_fast_path = false;
    params.timeout_delay = 300; // Short timeout for slot 3

    let (tx_msgs, tx_headers, mut rx_parents, mut rx_committer, mut rx_info, name, _committee, db_path) =
        spawn_core(24_000, params).await;

    let _ = timeout(Duration::from_millis(500), rx_parents.recv()).await;

    let header_list = headers();
    for h in &header_list {
        tx_msgs
            .send(PrimaryMessage::Header(h.clone(), false))
            .await
            .unwrap();
    }
    tokio::time::sleep(Duration::from_millis(200)).await;

    let mut proposals: HashMap<PublicKey, Proposal> = HashMap::new();
    for h in &header_list {
        proposals.insert(
            h.author,
            Proposal {
                header_digest: h.digest(),
                height: h.height(),
            },
        );
    }

    // Drive slots 1-2 (commit both, activating slot 3)
    let mut last_header = header_list[0].clone();
    for slot in 1..=2 {
        eprintln!("[vc_leader] === Driving slot {} ===", slot);
        match drive_slot(slot, &proposals, &last_header, &tx_msgs, &tx_headers, &mut rx_info, &mut rx_committer).await {
            Some(h) => last_header = h,
            None => {
                eprintln!("[vc_leader] Slot {} failed, stopping", slot);
                break;
            }
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }

    // Slot 3 is now active. Wait for timeout to fire.
    eprintln!("[vc_leader] Waiting for slot 3 timeout...");
    tokio::time::sleep(Duration::from_millis(600)).await;

    // Inject timeouts from other nodes for (slot=3, view=1)
    let all_keys = keys();
    for (pk, sk) in &all_keys {
        if *pk == name {
            continue;
        }
        let timeout_msg = Timeout::new_from_key(None, None, 3, 1, *pk, sk);
        tx_msgs.send(PrimaryMessage::Timeout(timeout_msg)).await.unwrap();
    }

    // Wait for TC formation + GeneratePrepareFromTC
    tokio::time::sleep(Duration::from_millis(500)).await;

    let result = timeout(Duration::from_millis(2000), rx_info.recv()).await;
    match result {
        Ok(Some(msg)) => {
            eprintln!("[vc_leader] Got output: {:?}", std::mem::discriminant(&msg));
        }
        _ => eprintln!("[vc_leader] No output from view change leader path"),
    }

    eprintln!("[vc_leader] View change leader scenario completed");
    let _ = fs::remove_dir_all(db_path);
}
