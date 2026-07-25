//! Reproduction for Bug 5 (Family D): Non-atomic in-memory vs persistent
//! updates in `handle_eqc_formed`.
//!
//! The buggy sequence at
//! `crates/hotshot/task-impls/src/quorum_proposal/handlers.rs:931-942`:
//!
//! ```text
//! let mut consensus_writer = task_state.consensus.write().await;
//! let _ = consensus_writer.update_high_qc(current_epoch_qc_clone.clone()); // L932 — IN-MEM
//! let _ = consensus_writer.update_next_epoch_high_qc(next_epoch_qc.clone()); // L933 — IN-MEM
//! drop(consensus_writer);  // L934 — LOCK DROPPED
//!
//! if let Err(e) = task_state                                                   // L936-942
//!     .storage
//!     .update_eqc(current_epoch_qc.clone(), next_epoch_qc.clone())             // L938 — PERSIST
//!     .await
//! {
//!     tracing::error!("Failed to store EQC: {}", e);  // ERROR LOGGED, NO RECOVERY
//! }
//! ```
//!
//! In-memory commits first, storage second, and they are not transactional.
//! If the await at L938 fails (or a crash occurs after L934 before L938
//! completes), in-memory state is ahead of persisted state. On restart,
//! recovery loads `qc_old` from storage; the in-mem advance is lost. But
//! `ExtendedQc2Formed` events may have been broadcast in the meantime, and
//! peers may have made decisions based on `qc_new`.
//!
//! Level 2 reproduction: state injection via `TestStorage.should_return_err`
//! to make the storage write fail (simulating either a storage error or the
//! durable-write-window of a real crash). Then observe the divergence between
//! `consensus.high_qc()` (in-mem) and `storage.high_qc_cloned()` (persisted).

use std::marker::PhantomData;
use std::sync::atomic::Ordering;

use committable::{Commitment, Committable};
use hotshot_example_types::node_types::{MemoryImpl, TestTypes};
use hotshot_testing::helpers::build_system_handle;
use hotshot_types::{
    data::ViewNumber,
    simple_certificate::{NextEpochQuorumCertificate2, QuorumCertificate2},
    simple_vote::{NextEpochQuorumData2, QuorumData2},
    traits::storage::Storage,
    vote::HasViewNumber,
};

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

fn make_next_epoch_qc(
    view: ViewNumber,
    marker: u8,
) -> NextEpochQuorumCertificate2<TestTypes> {
    let leaf_commit = Commitment::from_raw([marker; 32]);
    let inner = QuorumData2 {
        leaf_commit,
        epoch: None,
        block_number: None,
    };
    let data: NextEpochQuorumData2<TestTypes> = inner.into();
    let vote_commitment_bytes: [u8; 32] = data.commit().into();
    NextEpochQuorumCertificate2::<TestTypes>::new(
        data,
        Commitment::from_raw(vote_commitment_bytes),
        view,
        None,
        PhantomData,
    )
}

#[cfg(test)]
#[test_log::test(tokio::test(flavor = "multi_thread"))]
async fn handle_eqc_formed_breaks_atomicity_under_storage_failure() {
    let node_id = 1u64;
    let (handle, _, _, _) = build_system_handle::<TestTypes, MemoryImpl>(node_id).await;
    let consensus = handle.hotshot.consensus().clone();
    let storage = handle.storage();

    // Set up: arrange storage to fail any update_* call from now on — this
    // simulates either a real storage error or, equivalently, the durable-
    // write window of a crash.
    storage.should_return_err.store(true, Ordering::Relaxed);

    // Mirror the eQC-formed sequence exactly.
    let view = ViewNumber::new(5);
    let qc_v5 = make_qc(view, 0x11);
    let next_epoch_qc_v5 = make_next_epoch_qc(view, 0x11);

    // L932 - in-memory update first. The `let _ = ...` mirrors the source.
    {
        let mut w = consensus.write().await;
        let _ = w.update_high_qc(qc_v5.clone());
        let _ = w.update_next_epoch_high_qc(next_epoch_qc_v5.clone());
        // L934 - drop the lock.
    }

    // L938 - try to persist. Fails because should_return_err is set.
    let persist_res = storage.update_eqc(qc_v5.clone(), next_epoch_qc_v5.clone()).await;
    assert!(
        persist_res.is_err(),
        "test setup: storage failure mode must trigger"
    );

    // BUG WITNESS — in-memory has the new eQC, but storage still does NOT.
    // This is the atomicity gap. A crash here would leave the node believing
    // it has committed eQC{view 5} while the persisted state thinks it hasn't.
    let in_mem_view = consensus.read().await.high_qc().view_number();
    let persisted = storage.high_qc_cloned().await;

    assert_eq!(
        in_mem_view, view,
        "in-memory high_qc must reflect the new eQC at view 5"
    );
    assert!(
        persisted.is_none() || persisted.as_ref().unwrap().view_number() < view,
        "BUG WITNESS: storage is BEHIND in-memory after the failed eqc-store. \
         In-mem view: {:?}, persisted view: {:?}",
        in_mem_view,
        persisted.as_ref().map(|q| q.view_number())
    );

    // Demonstrate post-restart regression: simulate restart by reading
    // recovery state from storage. The in-mem-only eQC is *lost*.
    let recovered_view = match persisted {
        Some(qc) => qc.view_number(),
        None => ViewNumber::genesis(),
    };
    assert!(
        recovered_view < view,
        "post-restart regression: would recover with high_qc < {} (the eQC \
         the node already believed it had committed in memory)",
        *view
    );
}
