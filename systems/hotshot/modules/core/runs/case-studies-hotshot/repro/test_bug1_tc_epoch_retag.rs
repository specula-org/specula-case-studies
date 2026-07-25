//! Reproduction for Bug 1 (Family A): TC epoch retag.
//!
//! Status: REPRODUCED at Level 0 (public Committable + BLS APIs).
//!
//! Where it lives in the source tree (and how to run):
//!   File: crates/hotshot/types/src/simple_vote.rs
//!         (#[cfg(test)] mod tc_epoch_retag_repro)
//!   Run:  cargo test -p hotshot-types --lib tc_epoch_retag_repro
//!
//! `TimeoutData2::commit()` strips the `epoch` field from the signed digest
//! (see L460-468 of simple_vote.rs). Combined with the verifier in
//! `task-impls/src/helpers.rs:1131-1153`, which looks up the stake table
//! from `timeout_cert.data().epoch()` (the cert-declared epoch), this means
//! a TC formed from honest TimeoutVote2s for epoch=E can be re-tagged with
//! epoch=E' and verified against StakeTable(E') as long as the signers also
//! exist in StakeTable(E'). Contrast with `QuorumData2::commit()` (L406-427)
//! which DOES include epoch in the digest.
//!
//! Level 0 reproduction (public API, no test hooks).

use alloy::primitives::U256;
use ark_std::rand::SeedableRng;
use bitvec::vec::BitVec;
use committable::Committable;
use jf_signature::bls_over_bn254::{BLSOverBN254CurveSignatureScheme, KeyPair};
use rand_chacha::ChaCha20Rng;
use hotshot_types::{
    data::{EpochNumber, ViewNumber},
    qc::BitVectorQc,
    signature_key::BLSPubKey,
    simple_vote::TimeoutData2,
    stake_table::StakeTableEntry,
    traits::{
        qc::QuorumCertificateScheme,
        signature_key::SignatureKey,
    },
};

/// LEVEL 0 — Property test: the digest is byte-identical across two
/// different epoch values for the same view. This is the structural root
/// of the bug.
#[test]
fn tc_digest_is_epoch_invariant() {
    let view = ViewNumber::new(42);
    let td_epoch0 = TimeoutData2 { view, epoch: Some(EpochNumber::new(0)) };
    let td_epoch99 = TimeoutData2 { view, epoch: Some(EpochNumber::new(99)) };
    let td_none = TimeoutData2 { view, epoch: None };

    let c0: [u8; 32] = td_epoch0.commit().into();
    let c99: [u8; 32] = td_epoch99.commit().into();
    let cn: [u8; 32] = td_none.commit().into();
    assert_eq!(c0, c99, "TC digest must differ across epochs");
    assert_eq!(c0, cn);
}

/// LEVEL 0 — Signature-portability demo: A signature over
/// `TimeoutData2{view=v, epoch=Some(E)}` also verifies against
/// `TimeoutData2{view=v, epoch=Some(E')}` because the digest is identical.
#[test]
fn tc_signature_is_portable_across_epochs() {
    let mut rng = ChaCha20Rng::from_seed([7u8; 32]);
    let kp = KeyPair::generate(&mut rng);

    let view = ViewNumber::new(42);
    let td_for_epoch0 = TimeoutData2 { view, epoch: Some(EpochNumber::new(0)) };
    let td_for_epoch99 = TimeoutData2 { view, epoch: Some(EpochNumber::new(99)) };

    let digest_e0: [u8; 32] = td_for_epoch0.commit().into();
    let digest_e99: [u8; 32] = td_for_epoch99.commit().into();

    let sig_e0 = BitVectorQc::<BLSOverBN254CurveSignatureScheme>::sign(
        &(),
        kp.sign_key_ref(),
        digest_e0,
        &mut rng,
    ).expect("sign");

    let entries = vec![StakeTableEntry {
        stake_key: kp.ver_key(),
        stake_amount: U256::from(1u64),
    }];
    let qc_pp = BLSPubKey::public_parameter(&entries, U256::from(1u8));

    let mut signers = BitVec::new();
    signers.push(true);
    let agg = BLSPubKey::assemble(&qc_pp, signers.as_bitslice(), &[sig_e0]);

    let ok_e99 = BLSPubKey::check(&qc_pp, &digest_e99, &agg);
    assert!(
        ok_e99.is_ok(),
        "signature signed over (view=42, epoch=0) MUST NOT verify over \
         (view=42, epoch=99) — but it does, confirming the bug"
    );
}
