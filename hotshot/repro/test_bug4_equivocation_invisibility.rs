//! Reproduction for Bug 4 (Family B): Equivocation invisibility & non-durable
//! vote-cast.
//!
//! Two distinct findings, both in `crates/hotshot/types/src/consensus.rs`:
//!
//! 1. `update_high_qc` (L1325-1338) silently rejects a second QC at the same
//!    view with a different leaf — only a `debug!` is emitted; no
//!    equivocation evidence is produced.
//! 2. `update_locked_view` (L1205-1212) is monotonic only, and callers at
//!    `quorum_vote/handlers.rs:185-187` discard the `Result` with `let _ = ...`.
//!
//! Level 0 reproduction: build two QuorumCertificate2 for the SAME view but
//! DIFFERENT leaves, drive both through `Consensus::update_high_qc`, observe
//! the second is silently dropped (no event emitted, no panic, no error
//! propagated to a caller that does `let _ = ...`).
use std::marker::PhantomData;

use committable::{Commitment, Committable};
use hotshot_example_types::node_types::{MemoryImpl, TestTypes};
use hotshot_testing::helpers::build_system_handle;
use hotshot_types::{
    data::ViewNumber,
    simple_certificate::QuorumCertificate2,
    simple_vote::QuorumData2,
    vote::HasViewNumber,
};

/// Build a `QuorumCertificate2` for `view` with a unique `leaf_commit` derived
/// from `marker`. We use `Commitment::from_raw([marker; 32])` to produce a
/// distinct leaf_commit per marker without dragging in real Leaf2 plumbing.
/// `signatures: None` is fine — `update_high_qc` only checks the view number,
/// not signatures.
fn make_qc(view: ViewNumber, marker: u8) -> QuorumCertificate2<TestTypes> {
    let leaf_commit = Commitment::from_raw([marker; 32]);
    let data = QuorumData2 {
        leaf_commit,
        epoch: None,
        block_number: None,
    };
    let vote_commitment_bytes: [u8; 32] = data.commit().into();
    QuorumCertificate2::<TestTypes>::new(
        data,
        Commitment::from_raw(vote_commitment_bytes),
        view,
        None,
        PhantomData,
    )
}

#[cfg(test)]
#[test_log::test(tokio::test(flavor = "multi_thread"))]
async fn update_high_qc_silently_drops_same_view_different_leaf() {
    let node_id = 1u64;
    let (handle, _, _, _) = build_system_handle::<TestTypes, MemoryImpl>(node_id).await;
    let consensus = handle.hotshot.consensus().clone();

    let view = ViewNumber::new(5);
    let qc_a = make_qc(view, 1);
    let qc_b = make_qc(view, 2);

    assert_ne!(
        qc_a.data.leaf_commit, qc_b.data.leaf_commit,
        "test setup: the two QCs must commit to different leaves"
    );
    assert_eq!(
        qc_a.view_number(), qc_b.view_number(),
        "test setup: the two QCs must be for the SAME view"
    );

    // 1) First update_high_qc succeeds — bumps from genesis to view 5.
    {
        let mut w = consensus.write().await;
        w.update_high_qc(qc_a.clone())
            .expect("first update_high_qc should succeed");
        assert_eq!(
            w.high_qc().data.leaf_commit, qc_a.data.leaf_commit,
            "high QC must be qc_a after first update"
        );
    }

    // 2) Second update_high_qc with a DIFFERENT QC at the SAME view is
    //    silently rejected. No equivocation evidence is emitted.
    {
        let mut w = consensus.write().await;
        let res = w.update_high_qc(qc_b.clone());
        assert!(
            res.is_err(),
            "BUG WITNESS: update_high_qc should return Err for \
             same-view-different-leaf, observed: {:?}",
            res
        );
        // The buggy behavior: the in-memory high_qc remains qc_a; the
        // equivocation evidence (qc_a vs qc_b) is silently discarded.
        assert_eq!(
            w.high_qc().data.leaf_commit, qc_a.data.leaf_commit,
            "high QC remains qc_a — qc_b is silently swallowed without any \
             equivocation report"
        );
    }

    // 3) Demonstrate the call site at quorum_vote/handlers.rs:186 swallows
    //    the error: simulate exactly that pattern.
    {
        let mut w = consensus.write().await;
        // This is the exact pattern from quorum_vote/handlers.rs:186 for
        // update_locked_view, mirrored here for update_high_qc:
        let _ = w.update_high_qc(qc_b.clone());
        // No assertion fires because the Err is dropped — but importantly,
        // nothing is logged at warn/error level, and no slashing-evidence
        // event is broadcast. The same-view conflict is invisible to the
        // rest of the system.
    }
}

#[cfg(test)]
#[test_log::test(tokio::test(flavor = "multi_thread"))]
async fn update_locked_view_silently_rejects_non_monotonic() {
    let node_id = 1u64;
    let (handle, _, _, _) = build_system_handle::<TestTypes, MemoryImpl>(node_id).await;
    let consensus = handle.hotshot.consensus().clone();

    let mut w = consensus.write().await;
    let initial = w.locked_view();
    let bumped = ViewNumber::new(*initial + 10);

    // Move forward: succeeds.
    w.update_locked_view(bumped).expect("forward bump");

    // Move backward (or stay): the function returns Err but callers do
    // `let _ = ...`, hiding the failure.
    let stale = ViewNumber::new(*bumped); // equal, not strictly greater
    let res = w.update_locked_view(stale);
    assert!(
        res.is_err(),
        "update_locked_view returns Err on non-strict bump, callers ignore it"
    );
    // The lock_view stays at `bumped`.
    assert_eq!(w.locked_view(), bumped);
}
