//! Panic-path scenario: exercises every documented panic site in migration.rs.
//!
//! Each case uses a fresh validator (h1..h7, b1) so the spec's `panicked`
//! flag carried forward from a previous panic never blocks the next case.

#[path = "common.rs"]
mod common;

use common::{block, emit_config_for, genesis_cert, make_validator};
use std::panic::AssertUnwindSafe;
use std::sync::Arc;
use std::thread;

fn run<F: FnOnce() + Send + 'static>(name: &'static str, f: F) {
    eprintln!("--- panic case: {name} ---");
    let _ = thread::spawn(move || {
        let _ = std::panic::catch_unwind(AssertUnwindSafe(f));
    })
    .join();
}

fn main() {
    emit_config_for(
        "panic-paths",
        &["h1", "h2", "h3", "h4", "h5", "h6", "h7", "b1"],
    );

    // --- (1) SetGenesisBlock_PreFFA: unreachable!() panic when phase==PreFFA. ---
    run("set_genesis_block_pre_ffa", || {
        let m = make_validator("h1");
        m.set_genesis_block(block(0, common::bid1()));
    });

    // --- (2) SetGenesisBlock_SlotTooLarge: slot >= migration_slot. ---
    run("set_genesis_block_slot_too_large", || {
        let m = make_validator("h2");
        m.record_feature_activation(0);
        m.set_genesis_block(block(5, common::bid1()));
    });

    // --- (3) SetGenesisBlock_AlreadySet mismatch: re-call with a different block. ---
    run("set_genesis_block_already_set_mismatch", || {
        let m = make_validator("h3");
        m.record_feature_activation(0);
        m.set_genesis_block(block(2, common::bid1()));
        m.set_genesis_block(block(2, common::bid2()));
    });

    // --- (4) SetGenesisCertificate_PreFFA: unreachable!() panic when phase==PreFFA. ---
    run("set_genesis_certificate_pre_ffa", || {
        let m = make_validator("h4");
        m.set_genesis_certificate(genesis_cert(0, common::bid1()));
    });

    // --- (5) SetGenesisCertificate_SlotTooLarge. ---
    run("set_genesis_certificate_slot_too_large", || {
        let m = make_validator("h5");
        m.record_feature_activation(0);
        m.set_genesis_certificate(genesis_cert(5, common::bid1()));
    });

    // --- (6) SetGenesisBlock then mismatched SetGenesisCertificate: panic. ---
    run("set_genesis_certificate_mismatch", || {
        let m = make_validator("h6");
        m.record_feature_activation(0);
        m.set_genesis_block(block(2, common::bid1()));
        m.set_genesis_certificate(genesis_cert(3, common::bid2()));
    });

    // --- (7) (REMOVED) AlpenglowRootedNewEpoch from wrong phase. The base spec
    //         does not model this panic path — the AlpenglowRootedNewEpoch
    //         action is simply disabled outside `AGEnabled`. Re-add once Phase 3
    //         introduces a panic wrapper for it.

    // --- (8) PostMigration set_genesis_block / set_genesis_certificate: silent no-op. ---
    {
        let m = Arc::new(make_validator("b1"));
        m.record_feature_activation(0);
        m.set_genesis_block(block(2, common::bid1()));
        m.set_genesis_certificate(genesis_cert(2, common::bid1()));
        // Now in ReadyToEnable. Call set_genesis_block again -> PostMigration path, silent.
        m.set_genesis_block(block(2, common::bid1()));
        // Same for set_genesis_certificate.
        m.set_genesis_certificate(genesis_cert(2, common::bid1()));
    }
}
