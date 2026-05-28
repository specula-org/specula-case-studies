//! Shared helpers for the scenario binaries.

use agave_votor_messages::{
    consensus_message::{Block, Certificate, CertificateType},
    migration::MigrationStatus,
    tla_trace,
};
use solana_bls_signatures::{BLS_SIGNATURE_AFFINE_SIZE, Signature as BLSSignature};
use solana_hash::Hash;
use std::sync::Arc;

/// Build a Genesis certificate over `(slot, bid)`.
pub fn genesis_cert(slot: u64, bid: Hash) -> Arc<Certificate> {
    Arc::new(Certificate {
        cert_type: CertificateType::Genesis(slot, bid),
        signature: BLSSignature([0; BLS_SIGNATURE_AFFINE_SIZE]),
        bitmap: vec![],
    })
}

/// Emit a `config` line that declares the validator topology.
pub fn emit_config_for(scenario: &str, validators: &[&str]) {
    let vals = validators
        .iter()
        .map(|v| format!(r#""{}""#, v))
        .collect::<Vec<_>>()
        .join(",");
    let inner = format!(
        r#""scenario":"{}","servers":[{}],"MigrationSlot":5,"FeatureSlot":0"#,
        scenario, vals
    );
    tla_trace::emit_config(&inner);
}

/// Build a fresh MigrationStatus tagged with a spec-friendly nid.
pub fn make_validator(nid: &str) -> MigrationStatus {
    let m = MigrationStatus::default();
    m.set_trace_nid(nid);
    m
}

/// Concrete Hash used as bid1 across scenarios.
pub fn bid1() -> Hash {
    Hash::new_from_array([0xab; 32])
}

/// Second concrete Hash for equivocation paths.
#[allow(dead_code)]
pub fn bid2() -> Hash {
    Hash::new_from_array([0xcd; 32])
}

/// Helper that constructs a `Block` aligned with the spec helpers.
pub fn block(slot: u64, bid: Hash) -> Block {
    (slot, bid)
}
