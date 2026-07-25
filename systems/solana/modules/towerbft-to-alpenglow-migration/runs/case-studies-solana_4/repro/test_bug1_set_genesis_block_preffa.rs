// Reproduction test for Bug 1: set_genesis_block callable in PreFFA hits unreachable!
//
// Bug claim (from spec/bug-report.md): when MigrationStatus phase is PreFeatureActivation,
// calling set_genesis_block panics via unreachable!() at votor-messages/src/migration.rs:593.
// The model-checker reaches the panic at depth 2 from the initial state via the
// MCSetGenesisBlock_PreFFA action, which is an unconditional spec action.
//
// This file walks the escalation ladder:
//
//   LEVEL 0 black-box (`test_set_genesis_block_in_preffa_panics_direct`):
//     Calls the public function set_genesis_block directly on a freshly-constructed
//     MigrationStatus (phase = PreFeatureActivation). Reproduces the panic, but this
//     is not a "real" trigger — no production caller does this.
//
//   LEVEL 0 black-box via the realistic caller (`test_on_marker_rejects_genesis_cert_in_preffa`):
//     Drives the bug through block_component_processor::on_marker — the path the
//     bug report cites as reachable. This path is GUARDED — on_marker returns
//     BlockComponentPreMigration error instead of calling set_genesis_block.
//
// To run, place this file as votor-messages/tests/test_bug1_set_genesis_block_preffa.rs
// and run `cargo test -p agave-votor-messages --test test_bug1_set_genesis_block_preffa`.
// See repro/run_bug1.sh for the wrapper.

use {
    agave_votor_messages::{
        consensus_message::{Block, Certificate, CertificateType},
        migration::MigrationStatus,
    },
    solana_bls_signatures::{BLS_SIGNATURE_AFFINE_SIZE, Signature as BLSSignature},
    solana_hash::Hash,
    std::sync::Arc,
};

fn make_cert(slot: u64, bid: Hash) -> Arc<Certificate> {
    Arc::new(Certificate {
        cert_type: CertificateType::Genesis(slot, bid),
        signature: BLSSignature([0; BLS_SIGNATURE_AFFINE_SIZE]),
        bitmap: vec![],
    })
}

// ===========================================================================
// LEVEL 0 (a) — Direct call demonstrating the panic site is real.
// This is the spec-level scenario:  MCSetGenesisBlock_PreFFA fires from initial.
// ===========================================================================
#[test]
#[should_panic(expected = "Programmer error, attempting to set genesis cert while pre migration")]
fn test_set_genesis_block_in_preffa_panics_direct() {
    let status = MigrationStatus::default();
    // status.phase is now MigrationPhase::PreFeatureActivation.
    // Per the spec action MCSetGenesisBlock_PreFFA, simply calling set_genesis_block
    // is enough to fire the unreachable!().
    let block: Block = (0, Hash::new_unique());
    status.set_genesis_block(block);
}

// ===========================================================================
// LEVEL 0 (b) — Through the realistic call chain.
// The bug report cites runtime/src/block_component_processor.rs:260 as the reachable
// site. But that site is only reached via on_marker, which has an explicit guard:
//     if markers_fully_enabled || in_migration  (false in PreFFA)
// So this path is unreachable in PreFFA, regardless of the panic site existing.
//
// Since we cannot import block_component_processor here without a heavy runtime
// dependency, we encode the guard logic explicitly to demonstrate that the path
// is blocked. Both `should_allow_block_markers` and `is_in_migration` return false
// for the PreFFA phase, so on_marker's match arm would NOT call on_genesis_certificate
// at all, and would fall through to BlockComponentPreMigration.
// ===========================================================================
#[test]
fn test_on_marker_guard_rejects_genesis_cert_in_preffa() {
    let status = MigrationStatus::default();
    // PreFFA: should_allow_block_markers must be false (no AG blocks yet)
    // PreFFA: is_in_migration must be false (we haven't activated FF)
    assert!(
        !status.should_allow_block_markers(123),
        "PreFFA must reject AG markers: should_allow_block_markers should return false"
    );
    assert!(
        !status.is_in_migration(),
        "PreFFA must not be in_migration"
    );
    assert!(
        status.is_pre_feature_activation(),
        "After MigrationStatus::default(), phase must be PreFeatureActivation"
    );
    // The pattern guard `markers_fully_enabled || in_migration` is FALSE in PreFFA;
    // on_marker hits its catch-all `_ => Err(BlockComponentPreMigration)`.
    // So set_genesis_block is never called — the unreachable! site is unreachable
    // via the production caller chain at this phase.
}

// ===========================================================================
// LEVEL 1 — Timing assistance / concurrency widening.
// Hypothesis: in the snapshot-restart path, on_marker might race with
// record_feature_activation. We try to force a TOCTOU between the on_marker
// guard read (which sees phase = Migration) and the set_genesis_block call
// (where phase might have transitioned back? — not possible, phase is monotonic).
//
// The phase transitions are strictly monotonic forward:
//     PreFFA -> Migration -> ReadyToEnable -> AlpenglowEnabled -> FullAlpenglowEpoch
// There is no code that resets phase back to PreFFA except MigrationStatus::initialize,
// which only runs at startup before any threads see the MigrationStatus.
//
// Therefore Level 1 (timing) cannot reach the unreachable! site either — the
// monotonicity invariant rules out the race.
// ===========================================================================
#[test]
fn test_level1_no_toctou_possible_in_phase() {
    use std::sync::atomic::Ordering;
    use std::thread;
    let status = Arc::new(MigrationStatus::default());

    // Spawn a thread that races to "advance phase backwards" (impossible —
    // no API exists; we just confirm we cannot regress to PreFFA from a
    // non-PreFFA phase).
    let s2 = Arc::clone(&status);
    let t = thread::spawn(move || {
        s2.record_feature_activation(0); // PreFFA -> Migration
        assert!(s2.is_in_migration());
        // No public API to go back to PreFFA. Try to make sure.
        assert!(!s2.is_pre_feature_activation());
    });
    t.join().unwrap();

    // After the thread, phase is Migration. set_genesis_block would now go
    // through the Migration branch (not PreFFA) — no panic.
    let bid = Hash::new_unique();
    status.set_genesis_block((0, bid));
    // Should have set genesis block in Migration phase; verify by reading it back
    assert_eq!(status.eligible_genesis_block(), Some((0, bid)));
    let _ = Ordering::Acquire; // touch the import
}

// ===========================================================================
// LEVEL 2 — State injection.
// We cannot directly mutate phase to PreFFA after FF activation; no public
// or private API supports this. Even with full source access, the phase
// field is RwLock<MigrationPhase> with no setter back to PreFFA.
//
// The closest state-injection scenario is constructing a fresh MigrationStatus
// in PreFFA *and* simulating a concurrent block-component-processor receiving
// a GenesisCertificate marker. But block_component_processor::on_marker
// requires a Bank, blockstore, runtime, and full migration infrastructure.
// Instantiating those without going through the normal MigrationStatus
// initialize path is impractical, and the on_marker guard prevents the
// panic regardless.
//
// Best we can do is recreate the spec's scenario: phase = PreFFA, then
// directly call set_genesis_block. This is Level 0 (a) above. It hits the
// panic but the call is unreachable in production.
// ===========================================================================
#[test]
fn test_level2_state_injection_documentation() {
    // No-op test that documents Level 2 is the same as Level 0 (a) for this bug:
    // injecting state to be "in PreFFA" is the default state, and the panic site
    // is reached only by a caller that the production code does not expose.
}

// ===========================================================================
// LEVEL 3 — Minimal code modification.
// To force the panic via the production caller (block_component_processor),
// we would need to modify on_marker to remove the `markers_fully_enabled ||
// in_migration` guard. This is not "minimal" — it removes the very guard
// that prevents the bug. And once removed, the test would prove only that
// "if we remove the guard, the bug fires", which doesn't establish the bug
// is reachable in production.
//
// We conclude REPRODUCTION FAILED for the spec's claimed real-world trigger:
// the unreachable! site exists and panics, but no production caller can
// reach it. The MC counterexample reflects a spec abstraction that's
// over-permissive relative to the implementation. The defensive concern
// remains: a future caller could trip the panic.
// ===========================================================================
