//! Reproduction for Bug 3 (Family C): parallel-relay view-sync produces
//! multiple finalize certs per view.
//!
//! Status: REPRODUCED at Level 0 (BLS sign/verify on actual
//! `ViewSyncFinalizeData2`).
//!
//! Where it lives in the source tree (and how to run):
//!   File: crates/hotshot/types/src/simple_vote.rs
//!         (#[cfg(test)] mod view_sync_parallel_relay_repro)
//!   Run:  cargo test -p hotshot-types --lib view_sync_parallel_relay_repro
//!
//! `ViewSyncTaskState` (task-impls/src/view_sync.rs:91-101) keeps three
//! per-relay accumulator maps keyed by `(epoch, view, relay)` with no
//! cross-relay constraint. Two relays for the same `(epoch, view)` can each
//! reach threshold independently and emit valid finalize certs.
//!
//! The replica side (`view_sync.rs:683-685`) opportunistically lifts
//! `self.relay` if a higher-relay cert arrives, but DOES NOT reject a
//! lower-relay cert it has already accepted.
//!
//! Level 0 reproduction: construct two valid certs (different relays, same
//! view) using public BLS APIs and the actual ViewSyncFinalizeData2 type.

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
    simple_vote::ViewSyncFinalizeData2,
    stake_table::StakeTableEntry,
    traits::{qc::QuorumCertificateScheme, signature_key::SignatureKey},
};

#[test]
fn two_finalize_certs_same_view_different_relay() {
    let mut rng = ChaCha20Rng::from_seed([2u8; 32]);
    let keys: Vec<KeyPair> = (0..4).map(|_| KeyPair::generate(&mut rng)).collect();

    let view = ViewNumber::new(2);
    let epoch = Some(EpochNumber::new(0));
    let threshold = U256::from(3u64); // 3-of-4

    let entries: Vec<StakeTableEntry<BLSPubKey>> = keys
        .iter()
        .map(|kp| StakeTableEntry {
            stake_key: kp.ver_key(),
            stake_amount: U256::from(1u64),
        })
        .collect();
    let qc_pp = BLSPubKey::public_parameter(&entries, threshold);

    // Relay 1: signers s0, s1, s2
    let data_r1 = ViewSyncFinalizeData2 { relay: 1, round: view, epoch };
    let digest_r1: [u8; 32] = data_r1.commit().into();
    let mut sigs_r1 = Vec::new();
    let mut bv_r1 = BitVec::repeat(false, keys.len());
    let mut rng_r1 = ChaCha20Rng::from_seed([10u8; 32]);
    for i in 0..3 {
        let sig = BitVectorQc::<BLSOverBN254CurveSignatureScheme>::sign(
            &(), keys[i].sign_key_ref(), digest_r1, &mut rng_r1,
        ).expect("sign");
        sigs_r1.push(sig);
        bv_r1.set(i, true);
    }
    let agg_r1 = BLSPubKey::assemble(&qc_pp, bv_r1.as_bitslice(), &sigs_r1);
    BLSPubKey::check(&qc_pp, &digest_r1, &agg_r1)
        .expect("relay 1 cert valid (3-of-4)");

    // Relay 2: signers s1, s2, s3 (different subset, same view)
    let data_r2 = ViewSyncFinalizeData2 { relay: 2, round: view, epoch };
    let digest_r2: [u8; 32] = data_r2.commit().into();
    let mut sigs_r2 = Vec::new();
    let mut bv_r2 = BitVec::repeat(false, keys.len());
    let mut rng_r2 = ChaCha20Rng::from_seed([20u8; 32]);
    for i in 1..4 {
        let sig = BitVectorQc::<BLSOverBN254CurveSignatureScheme>::sign(
            &(), keys[i].sign_key_ref(), digest_r2, &mut rng_r2,
        ).expect("sign");
        sigs_r2.push(sig);
        bv_r2.set(i, true);
    }
    let agg_r2 = BLSPubKey::assemble(&qc_pp, bv_r2.as_bitslice(), &sigs_r2);
    BLSPubKey::check(&qc_pp, &digest_r2, &agg_r2)
        .expect("relay 2 cert valid (3-of-4)");

    assert_ne!(digest_r1, digest_r2,
        "relay is part of ViewSyncFinalizeData2 digest");
    // Two distinct certs for view=2, epoch=0 both verify under the same
    // 4-validator stake table.
}
