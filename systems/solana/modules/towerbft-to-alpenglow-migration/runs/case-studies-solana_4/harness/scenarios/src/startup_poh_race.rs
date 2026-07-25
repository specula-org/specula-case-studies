//! Startup PoH race: covers both PoH-already-started and not-started branches of
//! `enable_alpenglow_during_startup`. Captures the TOCTOU window described in
//! Finding A6.
//!
//! We drive each validator past `ReadyToEnable`, then either skip or call
//! `set_poh_service_started` before enabling Alpenglow.

#[path = "common.rs"]
mod common;

use common::{block, emit_config_for, genesis_cert, make_validator};
use std::sync::atomic::Ordering;

fn drive_to_ready_to_enable(nid: &str) -> agave_votor_messages::migration::MigrationStatus {
    let m = make_validator(nid);
    m.record_feature_activation(0);
    let bid = common::bid1();
    m.set_genesis_block(block(2, bid));
    m.set_genesis_certificate(genesis_cert(2, bid));
    m
}

fn main() {
    emit_config_for("startup-poh-race", &["h1", "h2"]);

    // h1: PoH service NOT started (NoPoH branch).
    let h1 = drive_to_ready_to_enable("h1");
    assert!(!h1.shutdown_poh.load(Ordering::Acquire));
    let s1 = h1.enable_alpenglow_during_startup();
    assert_eq!(s1, 2);

    // h2: PoH service started BEFORE enable_alpenglow_during_startup (PoH branch).
    let h2 = drive_to_ready_to_enable("h2");
    // This emits SetPohServiceStarted.
    h2.set_poh_service_started();
    // Background notifier: enable_alpenglow waits for poh_service_is_shutting_down
    // before transitioning. The PoH branch internally calls enable_alpenglow which
    // would block on the condvar; spawn a thread to satisfy it.
    let h2 = std::sync::Arc::new(h2);
    let h2c = h2.clone();
    let join = std::thread::spawn(move || {
        // Wait briefly so enable_alpenglow has a chance to start waiting.
        std::thread::sleep(std::time::Duration::from_millis(50));
        h2c.poh_service_is_shutting_down();
    });
    let s2 = h2.enable_alpenglow_during_startup();
    assert_eq!(s2, 2);
    join.join().unwrap();
}
