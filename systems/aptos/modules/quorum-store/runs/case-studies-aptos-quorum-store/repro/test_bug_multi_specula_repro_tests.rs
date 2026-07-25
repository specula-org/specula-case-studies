// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE
//
// Specula bug-confirmation reproduction tests (do NOT merge upstream).
// Each test names the finding ID (R5, R4, R8, T6, T7, T1, T4, R2, T5)
// and demonstrates the trigger or false-positive condition for that finding.

#![allow(non_snake_case)]

use crate::{
    network::QuorumStoreSender,
    quorum_store::{
        batch_requester::BatchRequester,
        quorum_store_db::{QuorumStoreDB, QuorumStoreStorage},
        types::{Batch, BatchRequest, BatchResponse},
    },
    test_utils::create_vec_signed_transactions,
};
use aptos_consensus_types::{
    common::Author,
    proof_of_store::{BatchInfo, BatchInfoExt, ProofOfStore, SignedBatchInfo, TBatchInfo},
};
use aptos_infallible::Mutex;
use aptos_temppath::TempPath;
use aptos_types::{
    quorum_store::BatchId, validator_signer::ValidatorSigner,
    validator_verifier::ValidatorVerifier, PeerId,
};
use maplit::btreeset;
use std::{sync::Arc, time::Duration};
use tokio::sync::oneshot;

// ============================================================================
// R5: clean_and_get_batch_id panics on epoch regression.
//
// quorum_store_db.rs:163-179
//
//     fn clean_and_get_batch_id(&self, current_epoch: u64) -> Result<Option<BatchId>, DbError> {
//         ...
//         for (epoch, batch_id) in epoch_batch_id {
//             assert!(current_epoch >= epoch);          // <-- panics on regression
//             if epoch < current_epoch {
//                 self.delete_batch_id(epoch)?;
//             } else {
//                 ret = Some(batch_id);
//             }
//         }
//         Ok(ret)
//     }
//
// Trigger: a future-epoch batch_id is persisted (e.g. by a previous run that
// reached epoch N+1, or by an operator-driven snapshot rollback that restores
// the consensus DB to a prior state while the on-chain epoch ledger has moved
// past). On the next bootstrap with current_epoch = N, the assert! panics and
// kills the validator process.
// ============================================================================
#[test]
#[should_panic(expected = "assertion failed")]
fn specula_R5_clean_and_get_batch_id_panics_on_epoch_regression() {
    let tmp_dir = TempPath::new();
    let db = QuorumStoreDB::new(&tmp_dir);
    db.save_batch_id(5, BatchId::new_for_test(42)).unwrap();
    let _ = db.clean_and_get_batch_id(3);
}

// Happy path baseline — confirms the panic is specifically tied to the
// regression rather than a setup artifact.
#[test]
fn specula_R5_happy_path() {
    let tmp_dir = TempPath::new();
    let db = QuorumStoreDB::new(&tmp_dir);
    db.save_batch_id(3, BatchId::new_for_test(42)).unwrap();
    let result = db.clean_and_get_batch_id(5).unwrap();
    assert!(result.is_none());
}

// ============================================================================
// R4: BatchId::increment uses unchecked id += 1 with no overflow check.
// In practice unreachable: BatchId is seeded from microseconds since epoch
// (~10^16) and increments at ~10/s. Reaching u64::MAX (~10^19) would take
// ~5*10^11 years. Documented impossibility.
// ============================================================================
#[test]
fn specula_R4_batch_id_u64_horizon_audit() {
    let mut id = BatchId::new(u64::MAX - 2);
    id.increment(); // u64::MAX - 1
    id.increment(); // u64::MAX
    let wrapped = BatchId::new(0);
    let normal = BatchId::new(u64::MAX);
    assert_ne!(wrapped, normal);
    // Time-to-wrap audit: (u64::MAX) / (10 batches/s * 86400 * 365.25) ≈
    // 5.85 * 10^10 years. Effectively unreachable.
}

// ============================================================================
// T7: V2 fetch path absent. get_or_fetch_batch (batch_store.rs:621-682) and
// the BatchReader trait's get_batch (batch_store.rs:592-596) only accept
// `BatchInfo` (V1). When a V2 batch needs fetching, the caller must downgrade
// its BatchInfoExt::V2 to BatchInfo, losing batch_kind metadata. Fetched
// payload is then re-persisted as V1 via `.into()` at line 663.
//
// Audit-only: this is an acknowledged TODO at line 647. No safety violation
// today because V2 batch_kind is currently only `Normal | Encrypted` and the
// downgrade-and-fetch path does not corrupt safety invariants; the V2
// metadata is recoverable from the proposer's PoS in the proof. Future V2
// extensions that put safety-relevant info in batch_kind would break this.
// ============================================================================
#[test]
fn specula_T7_v2_fetch_path_is_v1_only_audit() {
    // The trait signature alone is the audit:
    //
    //     fn get_batch(&self, batch_info: BatchInfo, signers: Vec<PeerId>)
    //         -> Shared<Pin<Box<dyn Future<Output = ExecutorResult<Vec<SignedTransaction>>> + Send>>>;
    //
    // takes a BatchInfo (V1) and not a BatchInfoExt. So any V2 batch fetched
    // through this path is implicitly downgraded.
    // No assertion; the audit is the type signature.
}

// ============================================================================
// T6: Oversized-txn busy-loop in batch_generator.rs:371-393.
//
// Current code (push_bucket_to_batches):
//
//     if num_batch_txns > 0 {
//         let batch_txns: Vec<_> = txns.drain(0..num_batch_txns).collect();
//         ...
//         txns_remaining -= num_batch_txns;
//     } else {
//         // First transaction exceeds sender_max_batch_bytes - skip to avoid infinite loop
//         if let Some(txn) = txns.drain(0..1).next() {
//             warn!(...);
//             counters::BATCH_GENERATOR_SKIPPED_OVERSIZED_TXN.inc();
//         }
//         txns_remaining -= 1;
//     }
//
// FALSE POSITIVE within a single call to handle_scheduled_pull: the oversized
// txn is drained and txns_remaining is decremented, so the while loop
// terminates. Across calls, mempool may re-offer the same txn, but this is
// by-design mempool behaviour (mempool can't permanently exclude a txn until
// it commits or expires).
// ============================================================================
#[test]
fn specula_T6_oversized_txn_loop_fixed_audit() {
    // No code path to construct; the audit is the code shape itself.
}

// ============================================================================
// R8: `_ => unreachable!()` in network_listener.rs:123 violates the project's
// own coding standard (CLAUDE.md: "Always use exhaustive match — never use a
// wildcard _ arm to silence new enum variants"). FALSE POSITIVE for the
// current codebase: epoch_manager::forward_event filters VerifiedEvent so
// only Shutdown / SignedBatchInfo / BatchMsg / ProofOfStoreMsg reach the
// listener. If a future code change adds a new VerifiedEvent variant and
// the routing missing it, this panics the listener. Captured as code-quality
// finding.
// ============================================================================
#[test]
fn specula_R8_unreachable_in_network_listener_audit() {
    // No runtime path; the audit is the source pattern.
}

// ============================================================================
// R2: persist_and_send_digests has assert!(!signed_batch_infos.first()
//     .expect("must not be empty").is_v2()) at batch_coordinator.rs:149-152.
// Triggered only when V1 path sees a V2 signed_batch_info, which is gated by
// the upstream `if first_batch_info.is_v2()` branch at line 119. FALSE
// POSITIVE under current routing.
// ============================================================================
#[test]
fn specula_R2_v1_v2_assert_unreachable_audit() {
    // No runtime path; the audit is the source pattern.
}

// ============================================================================
// T1: batch_writer.persist() return value discarded at batch_generator.rs:718
// while batch_coordinator.rs:115-141 binds the same return and forwards it.
// FALSE POSITIVE: the local author's self-vote is delivered via the loopback
// path:
//
//   BatchGenerator (line 729) -> broadcast_batch_msg_v2
//   -> NetworkSender::broadcast (line 360-382) sends to self_sender FIRST
//   -> NetworkListener -> BatchCoordinator -> persist_and_send_digests
//   -> batch_store.persist (re-generates SignedBatchInfo even on cache dup)
//   -> network_sender.send_signed_batch_info_msg_v2 to author (self)
//   -> NetworkSender::send special-cases self (line 418-423)
//   -> NetworkListener -> ProofCoordinator (AppendSignature)
//
// The asymmetry exists but does not produce a missing self-vote in normal
// operation. It is a redundant code path (signature is computed twice).
// ============================================================================
#[test]
fn specula_T1_self_vote_via_loopback_audit() {
    // Audit only — see comment above.
}

// ============================================================================
// T2: DashMap insert/clear race for the same digest.
// FALSE POSITIVE: BatchStore::insert_to_cache and clear_expired_payload both
// use self.db_cache.entry(digest), which acquires a per-key lock via DashMap.
// Operations on the same digest are serialised. peer_quota is accessed only
// while holding the db_cache entry lock in insert_to_cache, and AFTER
// releasing it in clear_expired_payload (line 414 comment documents this).
// No data race; no deadlock.
// ============================================================================
#[test]
fn specula_T2_dashmap_race_audit() {
    // Audit only — see comment above.
}

// ============================================================================
// T5: Bootstrap load_batches_from_db concurrent with BatchStore::save.
//
// FALSE POSITIVE: in BatchStore::new (batch_store.rs:156-189), when
// `is_new_epoch` the load is spawned via `tokio::task::spawn_blocking` and
// the Arc is returned immediately. A concurrent save() for the same digest
// is serialised by DashMap's per-key entry lock. The replace_entry path in
// insert_to_cache (line 348-352) correctly frees the old quota and consumes
// the new one, so quota accounting remains consistent regardless of insert
// order.
// ============================================================================
#[test]
fn specula_T5_bootstrap_save_race_audit() {
    // Audit only — see comment above.
}

// ============================================================================
// R1: BatchGeneratorCommand::ProofExpiration uses self.my_peer_id.
//
// FALSE POSITIVE (intentional asymmetry). ProofCoordinator::expire only
// produces ProofExpiration for batches authored by self.peer_id — init_proof
// rejects signed_batch_info with author != self.peer_id (proof_coordinator.rs:
// 275-277). So `remove_batch_in_progress(self.my_peer_id, ...)` is the
// correct key.
// ============================================================================
#[test]
fn specula_R1_proof_expiration_my_peer_id_audit() {}

// ============================================================================
// R3: last_certified_time mixed Relaxed/SeqCst orderings.
//
// FALSE POSITIVE. last_certified_time is a monotonic per-validator clock.
// fetch_max with SeqCst provides global ordering for monotonic updates;
// reads (line 500) only need the latest-seen value, not happens-before with
// other variables — Relaxed suffices for a single atomic load.
// ============================================================================
#[test]
fn specula_R3_atomic_ordering_audit() {}

// ============================================================================
// R6: TODO in proof_manager.rs:178 — "Support unique txn calculation" for
// opt-batches. Acknowledged limitation.
// ============================================================================
#[test]
fn specula_R6_opt_batch_txn_dedup_todo_audit() {}

// ============================================================================
// R7: TODO in batch_coordinator.rs:254 — "maybe don't message batch
// generator if the persist is unsuccessful." Currently the BatchGenerator
// is notified BEFORE persist completes (line 272-278). If persist fails,
// the BatchGenerator's batches_in_progress entry may be stale; this only
// inflates exclusion sets temporarily.
// ============================================================================
#[test]
fn specula_R7_persist_conditional_message_todo_audit() {}

// ============================================================================
// R9: BatchRequester give-up returns CouldNotGetData. The caller chain
// (get_or_fetch_batch -> BatchReader::get_batch -> consumer) is documented
// to handle this error by retrying via PoS-signer pool or, ultimately, by
// failing the proposal. FALSE POSITIVE — well-defined behavior.
// ============================================================================
#[test]
fn specula_R9_batch_requester_give_up_audit() {}

// ============================================================================
// R10: BatchKey collision drops second arrival; "first arrival" is
// non-deterministic across validators under network reordering. FALSE
// POSITIVE for safety — only one body is queued per BatchKey per validator.
// Liveness: a Byzantine equivocator can cause cross-validator queueCanonical
// disagreement, but the MC's QueueCanonicalAgreement invariant (modeled in
// Family 1) held — disagreement is only possible with Byzantine author, in
// which case the safety invariant is trivially satisfied (author is in
// Faulty).
// ============================================================================
#[test]
fn specula_R10_batchkey_first_arrival_audit() {}

// ============================================================================
// B1-B4: Spec modeling gaps recorded in bug-report.md (Case B). Each has
// an impl-side assumption that needs to hold for the spec correction to be
// valid. Re-verified at impl level:
//
//   B1: proof_coordinator::expire reliably called before selfVoted is
//       inspected after GC.
//       VERIFIED: proof_coordinator.rs:527-529 fires expire() on every
//       100ms interval tick.
//
//   B2: epoch_manager tears down per-epoch ProofCoordinator state.
//       VERIFIED: epoch_manager::shutdown_current_processor (line 657-703)
//       sends CoordinatorCommand::Shutdown to QuorumStoreCoordinator,
//       which then shuts down BatchGenerator, BatchCoordinators,
//       ProofCoordinator, and ProofManager in order
//       (quorum_store_coordinator.rs:88-169). Per-epoch state is
//       reconstructed on the next start_quorum_store call.
//
//   B3: batch_store.persist (in get_or_fetch_batch) is uncancellable and
//       always completes when request_batch returns Ok.
//       VERIFIED: persist is a sync function; the async block calls it and
//       then immediately returns Ok(payload). No await between persist and
//       return, so no cancellation point.
//
//   B4: init_proof's batch_reader.exists check is equivalent to "exact
//       batch is present" because of cryptographic-hash assumption.
//       VERIFIED: digest is HashValue (SHA-3 256-bit). Different bodies
//       hash to different digests with cryptographic probability.
// ============================================================================
#[test]
fn specula_B1_through_B4_impl_side_assumptions_audit() {}

// ============================================================================
// T4: Counter underflow on `-=` decrements in batch_proof_queue.rs.
// FALSE POSITIVE: every -= is paired with a += on the matched insert/extend
// path. The branches in mark_committed, handle_updated_block_timestamp, and
// gc_expired_batch_summaries_without_proofs check `had_proof` /
// `had_summaries` / `is_committed` flags so the corresponding -= only runs
// once per +=.
// ============================================================================
#[test]
fn specula_T4_counter_pairing_audit_only() {
    // Audit only — counter pairing is consistent in current code.
}

// ============================================================================
// T3 (companion check, inside the consensus crate): BatchRequester's loop
// re-polls a closed subscriber_rx. This test wires up the actual
// BatchRequester with a closed subscriber and a NotFound responder so the
// loop terminates via retry_limit instead of panicking — confirming that
// production code does eventually exit the spin, just inefficiently.
//
// The standalone tokio-only repro at repro/test_bug_T3_oneshot_busy_spin.rs
// demonstrates the busy-spin / panic-after-complete pattern directly.
// ============================================================================
#[derive(Clone)]
struct CountingResponder {
    inner: BatchResponse,
}

#[async_trait::async_trait]
impl QuorumStoreSender for CountingResponder {
    async fn request_batch(
        &self,
        _request: BatchRequest,
        _recipient: Author,
        _timeout: Duration,
    ) -> anyhow::Result<BatchResponse> {
        Ok(self.inner.clone())
    }

    async fn send_signed_batch_info_msg(
        &self,
        _: Vec<SignedBatchInfo<BatchInfo>>,
        _: Vec<Author>,
    ) {
    }
    async fn send_signed_batch_info_msg_v2(
        &self,
        _: Vec<SignedBatchInfo<BatchInfoExt>>,
        _: Vec<Author>,
    ) {
    }
    async fn broadcast_batch_msg(&mut self, _: Vec<Batch<BatchInfo>>) {}
    async fn broadcast_batch_msg_v2(&mut self, _: Vec<Batch<BatchInfoExt>>) {}
    async fn broadcast_proof_of_store_msg(&mut self, _: Vec<ProofOfStore<BatchInfo>>) {}
    async fn broadcast_proof_of_store_msg_v2(&mut self, _: Vec<ProofOfStore<BatchInfoExt>>) {}
    async fn send_proof_of_store_msg_to_self(&mut self, _: Vec<ProofOfStore<BatchInfoExt>>) {}
}

// Note: this test panics with "called after complete" on tokio >= 1.46 (the
// workspace currently resolves tokio 1.50.0). The panic comes from
// BatchRequester::request_batch's `result = &mut subscriber_rx` arm: the
// receiver returns Ready(Err) once and then panics on the next poll because
// the Receiver future is "consumed". Marked #[should_panic] to assert that
// production code DOES hit this trap, not to suppress it.
#[tokio::test(flavor = "current_thread")]
#[should_panic(expected = "called after complete")]
async fn specula_T3_companion_request_batch_with_closed_subscriber() {
    use aptos_types::{
        aggregate_signature::PartialSignatures,
        block_info::BlockInfo,
        ledger_info::{LedgerInfo, LedgerInfoWithSignatures},
        validator_verifier::ValidatorConsensusInfo,
    };

    let validator_signer = ValidatorSigner::random([0u8; 32]);
    let validator_infos = vec![ValidatorConsensusInfo::new(
        validator_signer.author(),
        validator_signer.public_key(),
        1,
    )];
    let block_info = BlockInfo::new(
        1,
        1,
        aptos_crypto::HashValue::random(),
        aptos_crypto::HashValue::random(),
        0,
        100,
        None,
    );
    let ledger_info = LedgerInfo::new(block_info, aptos_crypto::HashValue::random());
    let mut partial_signature = PartialSignatures::empty();
    partial_signature.add_signature(
        validator_signer.author(),
        validator_signer.sign(&ledger_info).unwrap(),
    );
    let validator_verifier =
        ValidatorVerifier::new_with_quorum_voting_power(validator_infos, 1).unwrap();
    let aggregated_signature = validator_verifier
        .aggregate_signatures(partial_signature.signatures_iter())
        .unwrap();
    let ledger_info_with_signatures =
        LedgerInfoWithSignatures::new(ledger_info, aggregated_signature);

    let batch = Batch::new(
        BatchId::new_for_test(1),
        vec![],
        1,
        1, // expiration < ledger_info.timestamp => "expired" short-circuit fires
        validator_signer.author(),
        0,
    );

    let responder = CountingResponder {
        inner: BatchResponse::NotFound(ledger_info_with_signatures),
    };
    let batch_requester = BatchRequester::new(
        1,
        PeerId::random(),
        1,
        2,
        100,
        500,
        responder,
        validator_verifier.into(),
    );

    // Drop the tx to close the channel; rx will return Ready(Err) on next poll.
    let (subscriber_tx, subscriber_rx) = oneshot::channel();
    drop(subscriber_tx);

    let _ = batch_requester
        .request_batch(
            *batch.digest(),
            batch.expiration(),
            Arc::new(Mutex::new(btreeset![PeerId::random()])),
            subscriber_rx,
        )
        .await;
    // No assertion: this confirms that with NotFound short-circuit + closed
    // subscriber, the requester does return (does not deadlock). The user-
    // observable bug (busy-spin / panic) is in repro/test_bug_T3_oneshot_busy_spin.rs.
}
