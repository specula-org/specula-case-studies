// Reproduction tests for aleph-bft bug-confirmation pass.
//
// This file is meant to be copied into
//   artifact/AlephBFT/consensus/src/testing/repro.rs
// and registered in artifact/AlephBFT/consensus/src/testing/mod.rs as
//   mod repro;
//
// Each test corresponds to a bug-family hypothesis from the modeling brief.
// The repro/test_bug<N>_*.sh wrappers stage this file into the repo, run
// `cargo test` against the specific test, and capture the output. After the
// run, the wrappers clean up the staging by reverting the modifications.

// ---------------------------------------------------------------------------
// Bug 1 / F1: Alerter accept-then-verify split  (Level 0)
//
// Claim (modeling brief §F1 + R1): `Handler::alert_confirmed` inserts
// `(alert.sender, forker)` into `known_rmcs` BEFORE running
// `verify_commitment`. If a byzantine sender raises an alert with a valid
// fork proof but an INVALID commitment, the dedup slot is allegedly
// occupied and would block other senders' alerts against the same forker.
//
// What we test (positive control of the fix's invariant): the dedup is
// keyed on `(sender, forker)`, so an *other* honest detector raising a
// genuine alert against the same forker MUST still be processed (Forker
// notification emitted, RMC started). If the bug were real, the second
// alert from a different sender would be blocked.
//
// Expected outcome: the honest detector's alert is processed normally
// (RmcMessage::SignedHash of the alert hash is emitted).
// If this assertion fires, the F1 bug is confirmed.

use crate::{
    alerts::{Alert, AlertMessage, ForkProof, ForkingNotification, Handler, Service},
    units::{ControlHash, FullUnit, PreUnit},
    Index, NodeCount, NodeIndex, NodeMap, Round, Signable, Signed, Terminator,
    UncheckedSigned,
};
use aleph_bft_mock::{Data, Hasher64, Keychain, PartialMultisignature, Signature};
use aleph_bft_rmc::Message as RmcMessage;
use futures::{
    channel::{mpsc, oneshot},
    FutureExt, StreamExt,
};
use futures_timer::Delay;
use std::time::Duration;

type TestMessage = AlertMessage<Hasher64, Data, Signature, PartialMultisignature>;
type TestAlert = Alert<Hasher64, Data, Signature>;
type TestForkProof = ForkProof<Hasher64, Data, Signature>;
type TestFullUnit = FullUnit<Hasher64, Data>;

fn keychains_for(n: NodeCount) -> Vec<Keychain> {
    (0..n.0).map(|i| Keychain::new(n, NodeIndex(i))).collect()
}

fn full_unit_variant(
    n: NodeCount,
    creator: NodeIndex,
    round: Round,
    variant: u32,
) -> TestFullUnit {
    FullUnit::new(
        PreUnit::new(creator, round, ControlHash::new(&NodeMap::with_size(n))),
        Some(variant),
        0,
    )
}

fn fork_proof_for(
    n: NodeCount,
    forker_keychain: &Keychain,
    round: Round,
) -> TestForkProof {
    let forker = forker_keychain.index();
    let u0 = full_unit_variant(n, forker, round, 0);
    let u1 = full_unit_variant(n, forker, round, 1);
    let s0: UncheckedSigned<TestFullUnit, Signature> =
        Signed::sign(u0, forker_keychain).into();
    let s1: UncheckedSigned<TestFullUnit, Signature> =
        Signed::sign(u1, forker_keychain).into();
    (s0, s1)
}

// ---- Bug 1 / F1 test ------------------------------------------------------
#[tokio::test(flavor = "multi_thread")]
async fn bug1_alerter_bad_commitment_does_not_block_honest_detector() {
    let n = NodeCount(7);
    let own = NodeIndex(0);
    let byz_sender = NodeIndex(5);
    let honest_alerter = NodeIndex(2);
    let forker = NodeIndex(6);
    let kc = keychains_for(n);

    // Pretend the byzantine sender first delivers an alert with a valid proof
    // but a "bad" commitment (commitment includes a unit signed by a non-forker).
    // We need the proof to pass verify_fork but the commitment to fail
    // verify_commitment. The simplest way is to insert into legit_units a unit
    // whose creator is NOT the forker.
    let fork_proof = fork_proof_for(n, &kc[forker.0], 0);
    let bogus_unit: UncheckedSigned<TestFullUnit, Signature> = Signed::sign(
        full_unit_variant(n, honest_alerter, 0, 0),
        &kc[honest_alerter.0],
    )
    .into();
    let bad_alert = Alert::new(byz_sender, fork_proof.clone(), vec![bogus_unit]);
    let signed_bad_alert: UncheckedSigned<TestAlert, Signature> =
        Signed::sign(bad_alert.clone(), &kc[byz_sender.0]).into();

    // Honest alerter's alert: same proof (well, also valid against the forker),
    // empty commitment is valid.
    let honest_alert = Alert::new(honest_alerter, fork_proof.clone(), vec![]);
    let honest_alert_hash = Signable::hash(&honest_alert);
    let signed_honest_alert: UncheckedSigned<TestAlert, Signature> =
        Signed::sign(honest_alert.clone(), &kc[honest_alerter.0]).into();

    // Wire up a Service for our own node.
    let (messages_for_network, mut messages_from_alerter) = mpsc::unbounded();
    let (messages_for_alerter, messages_from_network) = mpsc::unbounded();
    let (notifications_for_units, mut notifications_from_alerter) = mpsc::unbounded();
    let (_alerts_for_alerter, alerts_from_units) = mpsc::unbounded();
    let (exit_tx, exit_rx) = oneshot::channel();

    let handler = Handler::new(kc[own.0], 0);
    let mut service = Service::new(
        kc[own.0],
        crate::alerts::IO {
            messages_for_network,
            messages_from_network,
            notifications_for_units,
            alerts_from_units,
        },
        handler,
    );
    let task = tokio::spawn(async move {
        service
            .run(Terminator::create_root(exit_rx, "bug1-alerter"))
            .await;
    });

    // 1. Byzantine bad-commitment alert arrives first.
    messages_for_alerter
        .unbounded_send(AlertMessage::ForkAlert(signed_bad_alert))
        .expect("send bad alert");

    // 2. Honest detector's valid alert arrives.
    messages_for_alerter
        .unbounded_send(AlertMessage::ForkAlert(signed_honest_alert.clone()))
        .expect("send honest alert");

    // The honest alert MUST cause a ForkingNotification::Forker (because the
    // service hadn't yet learned about this forker — the byz alert was the
    // first to bring news, and on_network_alert returns Some(Forker(proof))
    // when the forker is new). After this, the honest alert from a DIFFERENT
    // sender must NOT be blocked by dedup; both byz and honest should populate
    // their own (sender,forker) slots in known_rmcs.
    //
    // We assert: at least one ForkingNotification::Forker is emitted AND an
    // RmcMessage::SignedHash carrying the honest alert hash is emitted.
    let mut saw_forker_notification = false;
    let mut saw_honest_rmc = false;
    let mut timeout = Delay::new(Duration::from_millis(1500)).fuse();

    loop {
        futures::select! {
            msg = messages_from_alerter.next().fuse() => {
                if let Some((m, _)) = msg {
                    match m {
                        AlertMessage::RmcMessage(_, RmcMessage::SignedHash(s)) => {
                            // Compare against the honest alert hash.
                            let hash: <Hasher64 as crate::Hasher>::Hash = honest_alert_hash;
                            if s.as_signable().as_signable() == &hash {
                                saw_honest_rmc = true;
                            }
                        }
                        _ => {}
                    }
                }
            }
            note = notifications_from_alerter.next().fuse() => {
                if let Some(n) = note {
                    if matches!(n, ForkingNotification::Forker(_)) {
                        saw_forker_notification = true;
                    }
                }
            }
            _ = timeout => break,
        }
        if saw_forker_notification && saw_honest_rmc {
            break;
        }
    }

    let _ = exit_tx.send(());
    let _ = task.await;

    assert!(
        saw_forker_notification,
        "FORKER notification was not emitted — byz alert's bad commitment may have suppressed the honest detector's alert (F1 bug TRIGGERED)"
    );
    assert!(
        saw_honest_rmc,
        "honest detector's RMC did NOT start — the dedup slot from the byz alert blocked the honest sender's alert (F1 bug TRIGGERED)"
    );
}

// ---------------------------------------------------------------------------
// Bug 5 / R5: Reconstruction::add_parents silently retains orphan on hash
// mismatch. The internal `dag::reconstruction::Reconstruction` is private
// and the in-tree test `dag::reconstruction::test::handles_bad_hash`
// already documents this behavior. The repro script for bug 5 invokes
// that existing test rather than duplicating the logic here.

// ---------------------------------------------------------------------------
// Bug 7 / F7: generate_salt non-cryptographic randomness.
//
// Claim: collection/mod.rs `generate_salt()` uses DefaultHasher hashing
// `Instant::now()`. The salt is supposed to uniquely identify a collection
// instance and prevent replay. Statistical: under tight loops the salt
// could collide.
//
// Test: call generate_salt many times in rapid succession and verify all
// salts are distinct (Instant::now() is monotonic with nanosecond res, so
// in practice they ARE distinct, but cryptographically weak).

use std::collections::HashSet;
use std::hash::{Hash, Hasher as _};
use std::collections::hash_map::DefaultHasher;

fn generate_salt_local() -> u64 {
    // Replicates collection::generate_salt() because it's a private function.
    let mut hasher = DefaultHasher::new();
    std::time::Instant::now().hash(&mut hasher);
    hasher.finish()
}

#[tokio::test]
async fn bug7_generate_salt_uniqueness() {
    // Although non-crypto, the practical question is collision rate.
    // 10000 calls in a tight loop — count distinct values.
    let mut salts = HashSet::new();
    let n = 10_000usize;
    for _ in 0..n {
        salts.insert(generate_salt_local());
    }
    let unique = salts.len();
    let collision_rate = (n - unique) as f64 / n as f64;
    println!("salt collision rate over {} calls: {:.4}% ({} dupes)",
             n, collision_rate * 100.0, n - unique);
    // We accept this as "documentation hazard, not safety bug" if collision
    // rate is low. Production usage is bounded by network rate, not tight
    // loops. The MC report's F7 says "Hardening issue; current usage is safe".
    // Fire if collision rate exceeds 1% — that would indicate a real exposure.
    assert!(collision_rate < 0.01,
        "salt collision rate too high: {:.4}%; F7 bug TRIGGERED", collision_rate * 100.0);
}

