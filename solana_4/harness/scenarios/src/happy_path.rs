//! Happy-path scenario: PreFFA -> InMigration -> ReadyToEnable -> AGEnabled -> FullAGEpoch.
//!
//! Drives three validators (`h1`, `h2`, `h3`) through the documented migration sequence.

#[path = "common.rs"]
mod common;

use common::{block, emit_config_for, genesis_cert, make_validator};

fn main() {
    emit_config_for("happy-path", &["h1", "h2", "h3"]);

    // Three honest validators, run sequentially so the trace mirrors a single observer.
    for nid in ["h1", "h2", "h3"] {
        let m = make_validator(nid);

        // PreFFA -> InMigration. With tla-trace MIGRATION_SLOT_OFFSET=5, ff_slot=0 => migration_slot=5.
        m.record_feature_activation(0);

        // Discover genesis block. (slot=2 < 5 to satisfy the spec slot < migration_slot.)
        let bid = common::bid1();
        m.set_genesis_block(block(2, bid));

        // Apply a matching certificate => InMigration -> ReadyToEnable.
        let cert = genesis_cert(2, bid);
        m.set_genesis_certificate(cert);

        // Startup pathway: PoH never started for the cluster bring-up.
        // => ReadyToEnable -> AGEnabled (NoPoH branch).
        let genesis_slot = m.enable_alpenglow_during_startup();
        assert_eq!(genesis_slot, 2);

        // AGEnabled -> FullAGEpoch on rooting a new epoch.
        m.alpenglow_rooted_new_epoch(1);
    }
}
