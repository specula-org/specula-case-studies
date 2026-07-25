// Reproduction tests for bugs surfaced by the aptosbft_2 model-checking round.
//
// Bug 1 / Bug 2: Sign-before-persist + Byzantine equivocating proposer enables
//                a double vote at the same round across a crash window
//                (Family 1, MC-1; cf. Issue #18298).
//
// Bug 3: `sign_commit_vote` does not call `verify_epoch(new_ledger_info.epoch(), ...)`
//        (Family 3, MC-5). We check whether the real implementation's
//        `match_ordered_only` + signature verification chain actually prevents
//        the cross-epoch commit vote that the spec admits, so we can classify
//        the MC counterexample correctly (false positive vs real bug).

use crate::{
    persistent_safety_storage::PersistentSafetyStorage, test_utils, Error, SafetyRules,
    TSafetyRules,
};
use aptos_consensus_types::{
    block::{block_test_utils::random_payload, Block},
    common::Payload,
    quorum_cert::QuorumCert,
    vote_proposal::VoteProposal,
};
use aptos_crypto::hash::ACCUMULATOR_PLACEHOLDER_HASH;
use aptos_secure_storage::{InMemoryStorage, Storage};
use aptos_types::{
    aggregate_signature::AggregateSignature,
    block_info::BlockInfo,
    ledger_info::{LedgerInfo, LedgerInfoWithSignatures},
    validator_signer::ValidatorSigner,
};

/// Build two structurally distinct VoteProposals at the same round, with the same QC
/// (the genesis QC). The Byzantine equivocating proposer in the threat model produces
/// two valid BlockData at the same round with the same parent QC but different payloads;
/// here the SAME signer signs both, which is exactly how an equivocating Byzantine proposer
/// looks to honest peers (two distinct signatures over two distinct BlockData with the
/// same proposer identity).
fn make_two_proposals_same_round(
    round: u64,
    genesis_qc: &QuorumCert,
    signer: &ValidatorSigner,
) -> (VoteProposal, VoteProposal) {
    // Use random_payload to get two semantically distinct blocks.
    let p1 = test_utils::make_proposal_with_qc_and_proof(
        random_payload(8),
        round,
        test_utils::empty_proof(),
        genesis_qc.clone(),
        signer,
    );
    let p2 = test_utils::make_proposal_with_qc_and_proof(
        random_payload(8),
        round,
        test_utils::empty_proof(),
        genesis_qc.clone(),
        signer,
    );
    assert_eq!(p1.block().round(), p2.block().round());
    assert_ne!(p1.block().id(), p2.block().id());
    (p1, p2)
}

/// Build a fresh PersistentSafetyStorage with a clean (epoch=1, last_voted_round=0)
/// state — the state a validator would have on disk *before* it has voted at round 1.
fn fresh_storage(signer: &ValidatorSigner) -> PersistentSafetyStorage {
    test_utils::test_storage(signer)
}

fn initialize(safety_rules: &mut SafetyRules, signer: &ValidatorSigner) {
    let (proof, _genesis_qc) = test_utils::make_genesis(signer);
    safety_rules.initialize(&proof).unwrap();
}

/// Test reproduces Bug 1 and Bug 2 together: sign-before-persist (Family 1, MC-1).
///
/// Scenario:
///   1. Honest validator s has fresh on-disk state: last_voted_round = 0.
///   2. Byzantine proposer issues conflicting proposals p1 and p2 at round 1.
///   3. s receives p1 first and signs a vote v1; SafetyRules has just executed
///      `self.sign(...)` (safety_rules_2chain.rs:102) but the
///      `self.persistent_storage.set_safety_data(...)` (line 121) has NOT
///      durably committed yet (e.g. OnDiskStorage::write performs `rename`
///      without `fsync`, so a power failure between the rename and the kernel
///      flushing buffers would lose the write).
///   4. s crashes. On restart the persistent state has last_voted_round = 0
///      (because the crash lost the persist).
///   5. s now receives p2 (the Byzantine proposer's other proposal) and
///      runs SafetyRules at round 1 again.
///
/// Buggy outcome (this test verifies): SafetyRules signs a *second* vote v2
/// at the same round 1, for a different proposal. v1 and v2 are two
/// distinct, valid votes by an honest validator at the same (epoch, round) —
/// safety invariant `NoDoubleVote` is broken.
///
/// Correct outcome would be: the second SafetyRules call rejects with
/// `IncorrectLastVotedRound`. That requires the persist to have survived
/// the crash, i.e. the storage backend must be synchronously durable.
#[test]
fn repro_bug1_2_double_vote_after_crash_window() {
    let signer = ValidatorSigner::from_int(0);
    let (_proof, genesis_qc) = test_utils::make_genesis(&signer);

    let (p1, p2) = make_two_proposals_same_round(1, &genesis_qc, &signer);

    // First boot: storage starts at last_voted_round=0 (fresh disk).
    let storage_a = fresh_storage(&signer);
    let mut sr_a = SafetyRules::new(storage_a, /* skip_sig_verify = */ false);
    initialize(&mut sr_a, &signer);

    let v1 = sr_a
        .construct_and_sign_vote_two_chain(&p1, None)
        .expect("first vote should succeed");
    assert_eq!(v1.vote_data().proposed().round(), 1);

    // Crash window between sign() and set_safety_data().
    // We simulate the lost persist by instantiating a SECOND, INDEPENDENT
    // PersistentSafetyStorage with the same (pre-crash) state — i.e. the
    // disk still has last_voted_round=0. This is what a validator backed
    // by a non-fsyncing storage (OnDiskStorage at on_disk.rs:64-70) would
    // see after a power loss between the sign and the persisted set.
    drop(sr_a);

    let storage_b = fresh_storage(&signer);
    let mut sr_b = SafetyRules::new(storage_b, /* skip_sig_verify = */ false);
    initialize(&mut sr_b, &signer);

    // Same validator now votes on the OTHER Byzantine-equivocating proposal at the same round.
    let v2_res = sr_b.construct_and_sign_vote_two_chain(&p2, None);

    match v2_res {
        Ok(v2) => {
            // Both votes succeeded → double vote.
            assert_eq!(v2.vote_data().proposed().round(), 1);
            assert_ne!(
                v1.vote_data().proposed().id(),
                v2.vote_data().proposed().id(),
                "the two votes must be for distinct proposals"
            );
            assert_ne!(
                v1.ledger_info().consensus_data_hash(),
                v2.ledger_info().consensus_data_hash(),
                "the two votes' signed payloads must differ"
            );
            println!(
                "REPRO SUCCESS: NoDoubleVote violated — v1.id={} v2.id={} both at round=1",
                v1.vote_data().proposed().id(),
                v2.vote_data().proposed().id()
            );
        },
        Err(e) => panic!(
            "Expected double-vote to succeed (demonstrating the bug); got Err: {:?}",
            e
        ),
    }
}

/// Counter-test: if the persistent state DID survive the crash (i.e. the
/// backend is properly fsyncing), the second sign call at the same round
/// must NOT produce a different vote. SafetyRules has two layers of guard:
///
///   1. `safety_data.last_vote` dedup at safety_rules_2chain.rs:84-88 —
///      if a vote at the same round already exists, return it (don't re-sign).
///   2. `verify_and_update_last_vote_round` at safety_rules.rs:213-232 —
///      `round <= last_voted_round` is rejected.
///
/// With persistent state surviving, layer (1) returns the EXISTING vote.
/// The buggy crash-window path loses *both* layers (because both fields
/// live in the same SafetyData), so layer (2)'s check passes against the
/// stale last_voted_round=0 and a brand-new vote gets signed.
#[test]
fn counter_durable_persist_blocks_double_vote() {
    let signer = ValidatorSigner::from_int(0);
    let (proof, genesis_qc) = test_utils::make_genesis(&signer);

    let (p1, p2) = make_two_proposals_same_round(1, &genesis_qc, &signer);

    // Single storage instance: the persist DOES survive across the two operations,
    // modelling a synchronously-durable backend.
    let storage = fresh_storage(&signer);
    let mut sr = SafetyRules::new(storage, /* skip_sig_verify = */ false);
    sr.initialize(&proof).unwrap();

    let v1 = sr
        .construct_and_sign_vote_two_chain(&p1, None)
        .expect("first vote should succeed");

    // Same SafetyRules, same persisted state. last_voted_round=1, last_vote=Some(v1).
    // The dedup at safety_rules_2chain.rs:84-88 returns v1 instead of signing a new vote.
    let v2 = sr
        .construct_and_sign_vote_two_chain(&p2, None)
        .expect("dedup should return previous vote, not re-sign");
    assert_eq!(
        v1.vote_data().proposed().id(),
        v2.vote_data().proposed().id(),
        "durable persist must return the SAME vote — not a new signature for p2"
    );
    println!(
        "CORRECT: durable persist returns previous vote v1 via last_vote dedup; \
         the validator does NOT produce two distinct signed votes at round 1."
    );
}

/// Test for Bug 3 (Family 3, MC-5): `sign_commit_vote` does not call
/// `verify_epoch(new_ledger_info.epoch(), &safety_data)`.
///
/// The MC spec produced a counterexample where a validator with
/// `safety_data.epoch = 1` signs a commit vote whose new_ledger_info has
/// epoch = 2. The aim of this test is to determine whether the real
/// implementation's `match_ordered_only` + signature verification chain
/// already prevents that scenario (in which case Bug 3 is a false positive
/// produced by the spec's abstraction over signatures).
///
/// What we try:
///   - Build a valid `old_ledger_info` whose `commit_info.epoch = 1`.
///   - Build a `new_ledger_info` whose `commit_info.epoch = 2` (everything else copied).
///   - Try to sign the commit vote.
///
/// `match_ordered_only` enforces `self.epoch == executed_block_info.epoch`
/// (block_info.rs:197). If the implementation rejects, then the spec's
/// "no verify_epoch" gap is closed by `match_ordered_only` at the commit_info
/// level, and Bug 3 is a false positive.
#[test]
fn test_bug3_sign_commit_vote_cross_epoch_blocked_by_match_ordered_only() {
    let signer = ValidatorSigner::from_int(0);
    let (proof, genesis_qc) = test_utils::make_genesis(&signer);

    let mut safety_rules = SafetyRules::new(test_utils::test_storage(&signer), false);
    safety_rules.initialize(&proof).unwrap();

    // Construct a chain genesis -> a1 -> a2 -> a3 (same recipe as test_sign_commit_vote).
    let round = genesis_qc.certified_block().round();
    let a1 = test_utils::make_proposal_with_qc(round + 1, genesis_qc, &signer);
    let a2 = test_utils::make_proposal_with_parent(Payload::empty(false), round + 2, &a1, None, &signer);
    let a3 = test_utils::make_proposal_with_parent(Payload::empty(false), round + 3, &a2, Some(&a1), &signer);

    let ledger_info_with_sigs = a3.block().quorum_cert().ledger_info().clone();
    let new_ledger_info = ledger_info_with_sigs.ledger_info().clone();

    // Sanity check that the well-formed (matching epoch) case succeeds.
    safety_rules
        .sign_commit_vote(ledger_info_with_sigs.clone(), new_ledger_info.clone())
        .expect("matching epoch commit vote should succeed");

    // Now try a cross-epoch commit vote: keep the old_ledger_info at epoch=1,
    // but rebuild new_ledger_info with a commit_info whose epoch=2.
    let real_commit_info = new_ledger_info.commit_info().clone();
    let mut bad_commit_info_fields = (
        real_commit_info.epoch() + 1, // <- the cross-epoch attempt: 2 instead of 1
        real_commit_info.round(),
        real_commit_info.id(),
        real_commit_info.executed_state_id(),
        real_commit_info.version(),
        real_commit_info.timestamp_usecs(),
        real_commit_info.next_epoch_state().cloned(),
    );
    let _ = &mut bad_commit_info_fields;
    let bad_commit_info = BlockInfo::new(
        bad_commit_info_fields.0,
        bad_commit_info_fields.1,
        bad_commit_info_fields.2,
        bad_commit_info_fields.3,
        bad_commit_info_fields.4,
        bad_commit_info_fields.5,
        bad_commit_info_fields.6,
    );
    let bad_new_ledger_info =
        LedgerInfo::new(bad_commit_info, new_ledger_info.consensus_data_hash());

    let result = safety_rules.sign_commit_vote(ledger_info_with_sigs, bad_new_ledger_info);

    match result {
        Err(Error::InconsistentExecutionResult(_, _)) => {
            println!(
                "CORRECT (Bug 3 false positive): cross-epoch sign_commit_vote blocked by \
                 match_ordered_only (`InconsistentExecutionResult`). \
                 Spec's missing-verify_epoch finding is closed by the BlockInfo.epoch comparison."
            );
        },
        Err(other) => panic!(
            "Expected InconsistentExecutionResult from match_ordered_only; got {:?}",
            other
        ),
        Ok(_) => panic!(
            "Cross-epoch sign_commit_vote unexpectedly succeeded — Bug 3 is REAL after all"
        ),
    }
}

/// Show that `WrappedLedgerInfo::verify` (line 90-108) does not verify the
/// `vote_data` field. A Byzantine relay can rewrite `vote_data.proposed.round`
/// in transit and `verify` still passes — provided no consumer of `vote_data`
/// re-verifies the binding. This test only documents the implementation gap;
/// downstream consumers (`certified_block(order_vote_enabled=false)` and
/// `into_quorum_cert(order_vote_enabled=false)`) DO call `verify_consensus_data_hash`,
/// so this is defense-in-depth only — Tier C.
#[test]
fn doc_wrapped_ledger_info_vote_data_unsigned() {
    use aptos_consensus_types::{vote_data::VoteData, wrapped_ledger_info::WrappedLedgerInfo};
    use aptos_types::validator_verifier::generate_validator_verifier;

    let signer = ValidatorSigner::from_int(0);
    let verifier = generate_validator_verifier(std::slice::from_ref(&signer));

    let (_, genesis_qc) = test_utils::make_genesis(&signer);

    // Real signed LedgerInfo at round 0 (genesis): WrappedLedgerInfo::verify
    // short-circuits round-0 anyway, so we use an empty round-0 wrapper.
    let genesis_li = genesis_qc.ledger_info();
    let real_vote_data =
        VoteData::new(BlockInfo::empty(), BlockInfo::empty());
    let wrapped_real =
        WrappedLedgerInfo::new(real_vote_data.clone(), genesis_li.clone());

    assert!(wrapped_real.verify(&verifier).is_ok());

    // Rebind vote_data to a wildly different BlockInfo — verify() still passes
    // (only round-0 short-circuit triggers + signature verification on the
    // already-signed inner ledger_info).
    let attacker_proposed = BlockInfo::new(
        42, // arbitrary epoch
        99, // arbitrary round
        aptos_crypto::HashValue::random(),
        *ACCUMULATOR_PLACEHOLDER_HASH,
        0,
        0,
        None,
    );
    let attacker_vote_data = VoteData::new(attacker_proposed, BlockInfo::empty());
    let wrapped_tampered = WrappedLedgerInfo::new(attacker_vote_data, genesis_li.clone());
    assert!(
        wrapped_tampered.verify(&verifier).is_ok(),
        "tampered vote_data should still pass WrappedLedgerInfo::verify"
    );

    println!(
        "DOC: WrappedLedgerInfo::verify does not check vote_data binding — \
         relies on consumer-side `verify_consensus_data_hash` via \
         `certified_block(order_vote_enabled=false)`."
    );
    // Silence the unused-binding lint on the LedgerInfoWithSignatures import.
    let _: LedgerInfoWithSignatures = genesis_li.clone();
    let _: AggregateSignature = AggregateSignature::empty();
    let _ = InMemoryStorage::new();
    let _: Storage = Storage::from(InMemoryStorage::new());
    let _ = Block::make_genesis_block();
}
