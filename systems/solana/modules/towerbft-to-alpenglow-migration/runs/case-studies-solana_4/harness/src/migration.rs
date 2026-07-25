//! Logic detailing the migration from TowerBFT to Alpenglow
//!
//! INSTRUMENTED VERSION FOR TLA+ TRACE VALIDATION.
//! Insertions are clearly marked with `// >>> TLA_TRACE ...` and `// <<< TLA_TRACE`.
//!
//! When the env var `TLA_TRACE_FILE` is unset, every emit is a cheap no-op so the
//! observable behaviour matches the upstream code other than the small bookkeeping
//! for the shadow fields (`ff_activation_slot_shadow`, `panicked`, `nid`).
#![allow(missing_docs)]
use {
    crate::{
        consensus_message::{Block, Certificate, CertificateType},
        fraction::Fraction,
        tla_trace::{self, EventBuilder, StateSnapshot},
    },
    log::*,
    solana_address::Address,
    solana_clock::{Epoch, Slot},
    solana_epoch_schedule::EpochSchedule,
    solana_pubkey::Pubkey,
    std::{
        sync::{
            Arc, Condvar, LazyLock, Mutex, RwLock,
            atomic::{AtomicBool, AtomicU64, Ordering},
        },
        time::Duration,
    },
};
#[cfg(feature = "dev-context-only-utils")]
use {
    solana_bls_signatures::{BLS_SIGNATURE_AFFINE_SIZE, Signature as BLSSignature},
    solana_hash::Hash,
};

// >>> TLA_TRACE: tunable offset for trace harness. Set to 5 to match Trace.cfg MigrationSlot=5.
#[cfg(feature = "tla-trace")]
pub const MIGRATION_SLOT_OFFSET: Slot = 5;
// <<< TLA_TRACE

/// The slot offset post feature flag activation to begin the migration.
#[cfg(all(not(feature = "tla-trace"), not(feature = "dev-context-only-utils")))]
pub const MIGRATION_SLOT_OFFSET: Slot = 5000;

/// Small offset for tests
#[cfg(all(not(feature = "tla-trace"), feature = "dev-context-only-utils"))]
pub const MIGRATION_SLOT_OFFSET: Slot = 32;

pub const MIGRATION_MALICIOUS_THRESHOLD: f64 = 20.0 / 100.0;
pub const GENESIS_VOTE_THRESHOLD: Fraction = Fraction::from_percentage(82);
pub const GENESIS_VOTE_REFRESH: Duration = Duration::from_millis(400);

pub static GENESIS_CERTIFICATE_ACCOUNT: LazyLock<Address> = LazyLock::new(|| {
    let (address, _) =
        Address::find_program_address(&[b"carlgration"], &agave_feature_set::alpenglow::id());
    address
});

#[derive(Debug, Clone)]
enum MigrationPhase {
    PreFeatureActivation,
    Migration {
        migration_slot: Slot,
        genesis_block: Option<Block>,
        genesis_cert: Option<Arc<Certificate>>,
    },
    ReadyToEnable {
        genesis_cert: Arc<Certificate>,
    },
    AlpenglowEnabled {
        genesis_cert: Arc<Certificate>,
    },
    FullAlpenglowEpoch {
        #[allow(dead_code)]
        full_alpenglow_epoch: Epoch,
        genesis_cert: Arc<Certificate>,
    },
}

impl MigrationPhase {
    fn is_pre_feature_activation(&self) -> bool {
        matches!(self, MigrationPhase::PreFeatureActivation)
    }
    fn is_in_migration(&self) -> bool {
        matches!(self, MigrationPhase::Migration { .. })
    }
    fn is_ready_to_enable(&self) -> bool {
        matches!(self, MigrationPhase::ReadyToEnable { .. })
    }
    fn is_alpenglow_enabled(&self) -> bool {
        matches!(
            self,
            Self::AlpenglowEnabled { .. } | Self::FullAlpenglowEpoch { .. }
        )
    }
    fn is_full_alpenglow_epoch(&self) -> bool {
        matches!(self, MigrationPhase::FullAlpenglowEpoch { .. })
    }
    fn is_alpenglow_block(&self, slot: Slot) -> bool {
        match self {
            MigrationPhase::PreFeatureActivation
            | MigrationPhase::Migration { .. }
            | MigrationPhase::ReadyToEnable { .. } => false,
            MigrationPhase::AlpenglowEnabled { genesis_cert } => {
                slot > genesis_cert.cert_type.slot()
            }
            MigrationPhase::FullAlpenglowEpoch { .. } => true,
        }
    }
    fn qualifies_for_genesis_discovery(&self, slot: Slot) -> bool {
        match self {
            MigrationPhase::Migration {
                migration_slot,
                genesis_block,
                ..
            } => genesis_block.is_none() && slot > *migration_slot,
            MigrationPhase::PreFeatureActivation
            | MigrationPhase::ReadyToEnable { .. }
            | MigrationPhase::AlpenglowEnabled { .. }
            | MigrationPhase::FullAlpenglowEpoch { .. } => false,
        }
    }
    fn should_bank_be_vote_only(&self, bank_slot: Slot) -> bool {
        match self {
            MigrationPhase::PreFeatureActivation => false,
            MigrationPhase::Migration { migration_slot, .. } => bank_slot >= *migration_slot,
            MigrationPhase::ReadyToEnable { .. } => true,
            MigrationPhase::AlpenglowEnabled { .. } | MigrationPhase::FullAlpenglowEpoch { .. } => {
                false
            }
        }
    }
    fn should_report_commitment_or_root(&self, slot: Slot) -> bool {
        match self {
            MigrationPhase::PreFeatureActivation => true,
            MigrationPhase::Migration { migration_slot, .. } => slot < *migration_slot,
            MigrationPhase::ReadyToEnable { .. }
            | MigrationPhase::AlpenglowEnabled { .. }
            | MigrationPhase::FullAlpenglowEpoch { .. } => false,
        }
    }
    fn should_root_during_startup(&self, slot: Slot) -> bool {
        match self {
            MigrationPhase::PreFeatureActivation => true,
            MigrationPhase::Migration { migration_slot, .. } => slot < *migration_slot,
            MigrationPhase::ReadyToEnable { .. }
            | MigrationPhase::AlpenglowEnabled { .. }
            | MigrationPhase::FullAlpenglowEpoch { .. } => true,
        }
    }
    fn should_publish_epoch_slots(&self, slot: Slot) -> bool {
        match self {
            MigrationPhase::PreFeatureActivation
            | MigrationPhase::Migration { .. }
            | MigrationPhase::ReadyToEnable { .. } => true,
            MigrationPhase::AlpenglowEnabled { genesis_cert } => {
                slot <= genesis_cert.cert_type.slot()
            }
            MigrationPhase::FullAlpenglowEpoch { .. } => false,
        }
    }
    fn should_send_votor_event(&self, slot: Slot) -> bool {
        self.is_alpenglow_block(slot)
    }
    fn should_respond_to_ancestor_hashes_requests(&self, slot: Slot) -> bool {
        self.should_publish_epoch_slots(slot)
    }
    fn should_have_alpenglow_ticks(&self, slot: Slot) -> bool {
        self.is_alpenglow_block(slot)
    }
    fn should_allow_block_markers(&self, slot: Slot) -> bool {
        self.is_alpenglow_block(slot)
    }
    fn should_use_double_merkle_block_id(&self, slot: Slot) -> bool {
        self.is_alpenglow_block(slot)
    }
    fn should_allow_fast_leader_handover(&self, slot: Slot) -> bool {
        self.is_alpenglow_block(slot)
    }

    // >>> TLA_TRACE: spec-friendly tag for the current phase.
    fn spec_tag(&self) -> &'static str {
        match self {
            MigrationPhase::PreFeatureActivation => "PreFFA",
            MigrationPhase::Migration { .. } => "InMigration",
            MigrationPhase::ReadyToEnable { .. } => "ReadyToEnable",
            MigrationPhase::AlpenglowEnabled { .. } => "AGEnabled",
            MigrationPhase::FullAlpenglowEpoch { .. } => "FullAGEpoch",
        }
    }
    // <<< TLA_TRACE
}

/// Keeps track of the current migration status
#[derive(Debug)]
pub struct MigrationStatus {
    my_pubkey: RwLock<Pubkey>,
    pub shutdown_poh: AtomicBool,
    poh_service_started: AtomicBool,
    phase: RwLock<MigrationPhase>,
    migration_wait: (Mutex<bool>, Condvar),

    // >>> TLA_TRACE: shadow fields used purely for trace emission.
    nid: RwLock<Option<String>>,
    ff_activation_slot_shadow: AtomicU64,
    panicked: AtomicBool,
    // <<< TLA_TRACE
}

impl Default for MigrationStatus {
    fn default() -> Self {
        Self::new(MigrationPhase::PreFeatureActivation)
    }
}

macro_rules! dispatch {
    ($vis:vis fn $name:ident(&self $(, $arg:ident : $ty:ty)*) $(-> $out:ty)?) => {
        #[inline]
        $vis fn $name(&self $(, $arg:$ty)*) $(-> $out)? {
            self.phase.read().unwrap().$name($($arg,)*)
        }
    };
}

// >>> TLA_TRACE: enumerates the 5 documented paths through `set_genesis_block`
// and the 4 paths through `set_genesis_certificate` so we can emit a clean
// `path` field on each event.
#[derive(Debug)]
enum SetGenesisBlockOutcome {
    PreFFA,
    PostMigration,
    AlreadySetSame,
    AlreadySetMismatch,
    SlotTooLarge,
    FirstTimeNoCert,
    FirstTimeCertMatch,
    FirstTimeCertMismatch,
}

#[derive(Debug)]
enum SetGenesisCertOutcome {
    PreFFA,
    PostMigration,
    SlotTooLarge,
    FirstTimeNoBlock,
    FirstTimeBlockMatch,
    FirstTimeBlockMismatch,
}
// <<< TLA_TRACE

impl MigrationStatus {
    fn new(phase: MigrationPhase) -> Self {
        let is_alpenglow_enabled = phase.is_alpenglow_enabled();
        let ff_shadow = match &phase {
            MigrationPhase::Migration { migration_slot, .. } => {
                migration_slot.saturating_sub(MIGRATION_SLOT_OFFSET)
            }
            _ => u64::MAX,
        };
        Self {
            my_pubkey: RwLock::default(),
            shutdown_poh: AtomicBool::new(is_alpenglow_enabled),
            poh_service_started: AtomicBool::new(false),
            phase: RwLock::new(phase),
            migration_wait: (Mutex::new(is_alpenglow_enabled), Condvar::new()),
            nid: RwLock::new(None),
            ff_activation_slot_shadow: AtomicU64::new(ff_shadow),
            panicked: AtomicBool::new(false),
        }
    }

    #[cfg(feature = "dev-context-only-utils")]
    pub fn post_migration_status() -> Self {
        let genesis_certificate = Certificate {
            cert_type: CertificateType::Genesis(0, Hash::default()),
            signature: BLSSignature([0; BLS_SIGNATURE_AFFINE_SIZE]),
            bitmap: vec![],
        };
        Self::new(MigrationPhase::AlpenglowEnabled {
            genesis_cert: Arc::new(genesis_certificate),
        })
    }

    #[cfg(feature = "dev-context-only-utils")]
    pub fn enable_alpenglow_for_tests(&self) {
        let genesis_block = (0, Hash::new_unique());
        self.record_feature_activation(0);
        self.set_genesis_block(genesis_block);
        self.set_genesis_certificate(Arc::new(Certificate {
            cert_type: CertificateType::Genesis(genesis_block.0, genesis_block.1),
            signature: BLSSignature([0; BLS_SIGNATURE_AFFINE_SIZE]),
            bitmap: vec![],
        }));
        assert_eq!(self.enable_alpenglow_during_startup(), genesis_block.0);
    }

    pub fn initialize(
        root_epoch: Epoch,
        ff_activation_slot: Option<Slot>,
        genesis_cert: Option<Certificate>,
        epoch_schedule: &EpochSchedule,
    ) -> Self {
        let phase = match (genesis_cert, ff_activation_slot) {
            (None, None) => MigrationPhase::PreFeatureActivation,
            (None, Some(activation_slot)) => MigrationPhase::Migration {
                migration_slot: activation_slot.saturating_add(MIGRATION_SLOT_OFFSET),
                genesis_block: None,
                genesis_cert: None,
            },
            (Some(cert), Some(activation_slot)) => {
                let migration_epoch = epoch_schedule.get_epoch(activation_slot);
                if root_epoch > migration_epoch {
                    MigrationPhase::FullAlpenglowEpoch {
                        full_alpenglow_epoch: migration_epoch.saturating_add(1),
                        genesis_cert: Arc::new(cert),
                    }
                } else {
                    MigrationPhase::AlpenglowEnabled {
                        genesis_cert: Arc::new(cert),
                    }
                }
            }
            (Some(_), None) => {
                unreachable!("Cannot have reached alpenglow genesis pre FF activation")
            }
        };

        warn!("Pre startup initializing alpenglow migration from root bank: {phase:?}");
        let s = Self::new(phase);
        if let Some(slot) = ff_activation_slot {
            s.ff_activation_slot_shadow.store(slot, Ordering::Release);
        }
        s
    }

    pub fn set_pubkey(&self, my_pubkey: Pubkey) {
        *self.my_pubkey.write().unwrap() = my_pubkey;
    }

    pub fn my_pubkey(&self) -> Pubkey {
        *self.my_pubkey.read().unwrap()
    }

    pub fn log_phase(&self) {
        let my_pubkey = self.my_pubkey();
        let phase = self.phase.read().unwrap();
        warn!("{my_pubkey}: Alpenglow migration phase {phase:?}");
    }

    // >>> TLA_TRACE
    pub fn set_trace_nid(&self, nid: impl Into<String>) {
        *self.nid.write().unwrap() = Some(nid.into());
    }

    fn trace_nid(&self) -> String {
        self.nid
            .read()
            .ok()
            .and_then(|g| g.clone())
            .unwrap_or_else(|| self.my_pubkey().to_string())
    }

    fn ff_slot_opt(&self) -> Option<u64> {
        match self.ff_activation_slot_shadow.load(Ordering::Acquire) {
            u64::MAX => None,
            v => Some(v),
        }
    }

    fn migration_slot_opt(&self) -> Option<u64> {
        // After leaving Migration phase the implementation drops the original
        // `migration_slot` field, but the spec preserves `migrationSlotV`
        // as a shadow value. Derive it from the persisted ff_activation_slot.
        self.ff_slot_opt()
            .map(|s| s.saturating_add(MIGRATION_SLOT_OFFSET))
    }

    fn genesis_block_opt(&self) -> Option<(u64, String)> {
        let phase = self.phase.read().unwrap();
        match &*phase {
            MigrationPhase::Migration { genesis_block, .. } => {
                genesis_block.as_ref().map(|(s, h)| (*s, h.to_string()))
            }
            MigrationPhase::ReadyToEnable { genesis_cert }
            | MigrationPhase::AlpenglowEnabled { genesis_cert }
            | MigrationPhase::FullAlpenglowEpoch { genesis_cert, .. } => {
                let CertificateType::Genesis(s, h) = genesis_cert.cert_type else {
                    return None;
                };
                Some((s, h.to_string()))
            }
            MigrationPhase::PreFeatureActivation => None,
        }
    }

    fn genesis_cert_opt(&self) -> Option<(u64, String)> {
        let phase = self.phase.read().unwrap();
        match &*phase {
            MigrationPhase::Migration { genesis_cert, .. } => {
                let cert = genesis_cert.as_ref()?;
                let CertificateType::Genesis(s, h) = cert.cert_type else {
                    return None;
                };
                Some((s, h.to_string()))
            }
            MigrationPhase::ReadyToEnable { genesis_cert }
            | MigrationPhase::AlpenglowEnabled { genesis_cert }
            | MigrationPhase::FullAlpenglowEpoch { genesis_cert, .. } => {
                let CertificateType::Genesis(s, h) = genesis_cert.cert_type else {
                    return None;
                };
                Some((s, h.to_string()))
            }
            MigrationPhase::PreFeatureActivation => None,
        }
    }

    pub fn snapshot(&self) -> StateSnapshot {
        let phase_tag = self.phase.read().unwrap().spec_tag();
        StateSnapshot {
            phase: phase_tag,
            ff_activation_slot: self.ff_slot_opt(),
            migration_slot: self.migration_slot_opt(),
            genesis_block: self.genesis_block_opt(),
            genesis_cert: self.genesis_cert_opt(),
            poh_service_started: self.poh_service_started.load(Ordering::Acquire),
            shutdown_poh: self.shutdown_poh.load(Ordering::Acquire),
            panicked: self.panicked.load(Ordering::Acquire),
        }
    }

    pub fn mark_panicked(&self) {
        self.panicked.store(true, Ordering::Release);
    }

    fn emit(&self, name: &str, extra: Vec<(String, String)>) {
        let snap = self.snapshot();
        let mut b = EventBuilder::new(name, &self.trace_nid())
            .field_raw("state", &snap.to_json());
        for (k, v) in extra {
            b = b.field_raw(&k, &v);
        }
        b.emit();
    }
    // <<< TLA_TRACE

    dispatch!(pub fn is_pre_feature_activation(&self) -> bool);
    dispatch!(pub fn is_in_migration(&self) -> bool);
    dispatch!(pub fn is_ready_to_enable(&self) -> bool);
    dispatch!(pub fn is_alpenglow_enabled(&self) -> bool);
    dispatch!(pub fn is_full_alpenglow_epoch(&self) -> bool);

    dispatch!(pub fn qualifies_for_genesis_discovery(&self, slot: Slot) -> bool);
    dispatch!(pub fn should_bank_be_vote_only(&self, bank_slot: Slot) -> bool);
    dispatch!(pub fn should_report_commitment_or_root(&self, slot: Slot) -> bool);
    dispatch!(pub fn should_root_during_startup(&self, slot: Slot) -> bool);
    dispatch!(pub fn should_publish_epoch_slots(&self, slot: Slot) -> bool);
    dispatch!(pub fn should_send_votor_event(&self, slot: Slot) -> bool);
    dispatch!(pub fn should_respond_to_ancestor_hashes_requests(&self, slot: Slot) -> bool);
    dispatch!(pub fn should_have_alpenglow_ticks(&self, slot: Slot) -> bool);
    dispatch!(pub fn should_allow_block_markers(&self, slot: Slot) -> bool);
    dispatch!(pub fn should_allow_fast_leader_handover(&self, slot: Slot) -> bool);
    dispatch!(pub fn should_use_double_merkle_block_id(&self, slot: Slot) -> bool);

    pub fn set_poh_service_started(&self) {
        self.poh_service_started.store(true, Ordering::Release);
        // >>> TLA_TRACE
        self.emit("SetPohServiceStarted", vec![]);
        // <<< TLA_TRACE
    }

    pub fn record_feature_activation(&self, slot: Slot) -> Slot {
        let migration_slot = slot.saturating_add(MIGRATION_SLOT_OFFSET);
        // >>> TLA_TRACE: detect if phase isn't PreFFA — set panicked, but still emit then assert.
        let was_pre_ffa;
        {
            let mut phase = self.phase.write().unwrap();
            was_pre_ffa = matches!(*phase, MigrationPhase::PreFeatureActivation);
            if was_pre_ffa {
                *phase = MigrationPhase::Migration {
                    migration_slot,
                    genesis_block: None,
                    genesis_cert: None,
                };
            }
        }
        if !was_pre_ffa {
            self.panicked.store(true, Ordering::Release);
            self.emit(
                "RecordFeatureActivation",
                vec![("slot".to_string(), format!("{}", slot))],
            );
        }
        assert!(was_pre_ffa, "record_feature_activation called from non-PreFFA phase");

        self.ff_activation_slot_shadow.store(slot, Ordering::Release);
        self.emit(
            "RecordFeatureActivation",
            vec![("slot".to_string(), format!("{}", slot))],
        );
        // <<< TLA_TRACE

        warn!(
            "{}: Alpenglow feature flag was activated in {slot}, migration will start at \
             {migration_slot}",
            self.my_pubkey()
        );

        migration_slot
    }

    pub fn migration_slot(&self) -> Option<Slot> {
        let MigrationPhase::Migration { migration_slot, .. } = &*self.phase.read().unwrap() else {
            return None;
        };
        Some(*migration_slot)
    }

    pub fn eligible_genesis_block(&self) -> Option<Block> {
        let phase = self.phase.read().unwrap();
        let MigrationPhase::Migration { genesis_block, .. } = &*phase else {
            return None;
        };
        *genesis_block
    }

    /// Set our view of the genesis block.
    pub fn set_genesis_block(&self, discovered_genesis_block @ (slot, _bid): Block) {
        // >>> TLA_TRACE: classify outcome under the lock, then drop and emit.
        let outcome: SetGenesisBlockOutcome;
        {
            let mut phase = self.phase.write().unwrap();
            outcome = match &mut *phase {
                MigrationPhase::PreFeatureActivation => SetGenesisBlockOutcome::PreFFA,
                MigrationPhase::Migration {
                    migration_slot,
                    genesis_block,
                    genesis_cert,
                } => {
                    if let Some(prev) = *genesis_block {
                        if prev == discovered_genesis_block {
                            SetGenesisBlockOutcome::AlreadySetSame
                        } else {
                            SetGenesisBlockOutcome::AlreadySetMismatch
                        }
                    } else if slot >= *migration_slot {
                        SetGenesisBlockOutcome::SlotTooLarge
                    } else {
                        // Commit the genesis_block field.
                        *genesis_block = Some(discovered_genesis_block);
                        match genesis_cert {
                            None => SetGenesisBlockOutcome::FirstTimeNoCert,
                            Some(cert) => {
                                let CertificateType::Genesis(cs, cb) = cert.cert_type else {
                                    unreachable!("Programmer error invalid genesis certificate");
                                };
                                if cs == discovered_genesis_block.0
                                    && cb == discovered_genesis_block.1
                                {
                                    let cert = cert.clone();
                                    *phase = MigrationPhase::ReadyToEnable { genesis_cert: cert };
                                    SetGenesisBlockOutcome::FirstTimeCertMatch
                                } else {
                                    SetGenesisBlockOutcome::FirstTimeCertMismatch
                                }
                            }
                        }
                    }
                }
                MigrationPhase::ReadyToEnable { .. }
                | MigrationPhase::AlpenglowEnabled { .. }
                | MigrationPhase::FullAlpenglowEpoch { .. } => {
                    SetGenesisBlockOutcome::PostMigration
                }
            };
        }
        // Determine path string + panic intent.
        let (path, do_panic) = match outcome {
            SetGenesisBlockOutcome::PreFFA => ("PreFFA", true),
            SetGenesisBlockOutcome::PostMigration => ("PostMigration", false),
            SetGenesisBlockOutcome::AlreadySetSame => ("AlreadySet", false),
            SetGenesisBlockOutcome::AlreadySetMismatch => ("AlreadySet", true),
            SetGenesisBlockOutcome::SlotTooLarge => ("SlotTooLarge", true),
            SetGenesisBlockOutcome::FirstTimeNoCert => ("InMigration_FirstTime", false),
            SetGenesisBlockOutcome::FirstTimeCertMatch => ("InMigration_FirstTime", false),
            SetGenesisBlockOutcome::FirstTimeCertMismatch => ("InMigration_FirstTime", true),
        };
        if do_panic {
            self.panicked.store(true, Ordering::Release);
        }
        self.emit_set_genesis_block(path, discovered_genesis_block);
        if do_panic {
            match path {
                "PreFFA" => unreachable!(
                    "{}: Programmer error, attempting to set genesis cert while pre migration",
                    self.my_pubkey()
                ),
                "AlreadySet" => panic!(
                    "We have discovered two different alpenglow genesis blocks. Something is wrong"
                ),
                "SlotTooLarge" => panic!(
                    "Attempting to set a genesis block that is past the migration start"
                ),
                "InMigration_FirstTime" => panic!(
                    "{}: Genesis cert mismatch detected, two distinct forks reached threshold.",
                    self.my_pubkey()
                ),
                _ => unreachable!(),
            }
        }
        warn!(
            "{} Setting genesis block {discovered_genesis_block:?}",
            self.my_pubkey()
        );
        // <<< TLA_TRACE
    }

    // >>> TLA_TRACE: helper for set_genesis_block events.
    fn emit_set_genesis_block(&self, path: &str, block: Block) {
        let block_json = format!(
            r#"{{"slot":{},"bid":"{}"}}"#,
            block.0,
            tla_trace_escape(&block.1.to_string())
        );
        self.emit(
            "SetGenesisBlock",
            vec![
                ("block".to_string(), block_json),
                ("path".to_string(), format!(r#""{}""#, path)),
            ],
        );
    }
    // <<< TLA_TRACE

    /// Set the genesis certificate.
    pub fn set_genesis_certificate(&self, cert: Arc<Certificate>) {
        // >>> TLA_TRACE: classify outcome under the lock.
        let outcome: SetGenesisCertOutcome;
        let cert_slot;
        let cert_bid;
        {
            let mut phase = self.phase.write().unwrap();
            let CertificateType::Genesis(s, h) = cert.cert_type else {
                unreachable!("Programmer error adding invalid genesis certificate");
            };
            cert_slot = s;
            cert_bid = h;

            outcome = match &mut *phase {
                MigrationPhase::PreFeatureActivation => SetGenesisCertOutcome::PreFFA,
                MigrationPhase::Migration {
                    migration_slot,
                    genesis_block,
                    genesis_cert,
                } => {
                    if s >= *migration_slot {
                        SetGenesisCertOutcome::SlotTooLarge
                    } else {
                        *genesis_cert = Some(cert.clone());
                        match genesis_block {
                            None => SetGenesisCertOutcome::FirstTimeNoBlock,
                            Some(gb) => {
                                if gb.0 == s && gb.1 == h {
                                    *phase = MigrationPhase::ReadyToEnable {
                                        genesis_cert: cert.clone(),
                                    };
                                    SetGenesisCertOutcome::FirstTimeBlockMatch
                                } else {
                                    SetGenesisCertOutcome::FirstTimeBlockMismatch
                                }
                            }
                        }
                    }
                }
                MigrationPhase::ReadyToEnable { .. }
                | MigrationPhase::AlpenglowEnabled { .. }
                | MigrationPhase::FullAlpenglowEpoch { .. } => {
                    SetGenesisCertOutcome::PostMigration
                }
            };
        }
        let (path, do_panic) = match outcome {
            SetGenesisCertOutcome::PreFFA => ("PreFFA", true),
            SetGenesisCertOutcome::PostMigration => ("PostMigration", false),
            SetGenesisCertOutcome::SlotTooLarge => ("SlotTooLarge", true),
            SetGenesisCertOutcome::FirstTimeNoBlock => ("InMigration_FirstTime", false),
            SetGenesisCertOutcome::FirstTimeBlockMatch => ("InMigration_FirstTime", false),
            SetGenesisCertOutcome::FirstTimeBlockMismatch => ("InMigration_FirstTime", true),
        };
        if do_panic {
            self.panicked.store(true, Ordering::Release);
        }
        self.emit_set_genesis_certificate_inline(path, cert_slot, &cert_bid.to_string());
        if do_panic {
            match path {
                "PreFFA" => unreachable!(
                    "{}: Programmer error, attempting to set genesis cert while pre migration",
                    self.my_pubkey()
                ),
                "SlotTooLarge" => panic!(
                    "Attempting to set a genesis certificate past the migration start"
                ),
                "InMigration_FirstTime" => panic!(
                    "{}: Genesis cert/block mismatch — two distinct forks reached threshold.",
                    self.my_pubkey()
                ),
                _ => unreachable!(),
            }
        }
        warn!(
            "{} Setting genesis cert for ({cert_slot},{cert_bid:?})",
            self.my_pubkey()
        );
        // <<< TLA_TRACE
    }

    // >>> TLA_TRACE: helper for set_genesis_certificate events.
    fn emit_set_genesis_certificate_inline(&self, path: &str, slot: Slot, bid: &str) {
        let cert_json = format!(
            r#"{{"slot":{},"block_id":"{}"}}"#,
            slot,
            tla_trace_escape(bid)
        );
        self.emit(
            "SetGenesisCertificate",
            vec![
                ("cert".to_string(), cert_json),
                ("path".to_string(), format!(r#""{}""#, path)),
            ],
        );
    }
    // <<< TLA_TRACE

    pub fn enable_alpenglow(&self, exit: &AtomicBool) {
        let ready = self.phase.read().unwrap().is_ready_to_enable();
        if !ready {
            self.panicked.store(true, Ordering::Release);
            self.emit_enable_alpenglow();
            assert!(false, "enable_alpenglow called from non-ReadyToEnable phase");
        }

        self.shutdown_poh.store(true, Ordering::Release);
        self.wait_for_migration_or_exit(exit);

        if exit.load(Ordering::Relaxed) {
            warn!(
                "{}: Validator shutdown before Alpenglow could be enabled",
                self.my_pubkey()
            );
            self.emit_enable_alpenglow();
            return;
        }

        warn!("{}: Alpenglow enabled!", self.my_pubkey());
        // >>> TLA_TRACE: suppress when nested inside enable_alpenglow_during_startup
        // so the trace does not record EnableAlpenglow + EnableAlpenglowDuringStartup
        // for the same logical transition.
        self.emit_enable_alpenglow();
        // <<< TLA_TRACE
    }

    // >>> TLA_TRACE: thread-local suppression flag for the PoH-startup nested call.
    fn emit_enable_alpenglow(&self) {
        if SUPPRESS_ENABLE_ALPENGLOW.with(|c| c.get()) {
            return;
        }
        self.emit("EnableAlpenglow", vec![]);
    }
    // <<< TLA_TRACE

    pub fn poh_service_is_shutting_down(&self) {
        let phase_clone = self.phase.read().unwrap().clone();
        let MigrationPhase::ReadyToEnable { genesis_cert } = phase_clone else {
            // >>> TLA_TRACE
            self.panicked.store(true, Ordering::Release);
            // <<< TLA_TRACE
            unreachable!(
                "{}: Programmer error, PohService is shutting down before we are ReadyToEnable",
                self.my_pubkey()
            );
        };

        *self.phase.write().unwrap() = MigrationPhase::AlpenglowEnabled { genesis_cert };
        let (is_alpenglow_enabled, condvar) = &self.migration_wait;
        *is_alpenglow_enabled.lock().unwrap() = true;
        condvar.notify_all();
    }

    pub fn enable_alpenglow_during_startup(&self) -> Slot {
        warn!("{}: Enabling alpenglow during startup", self.my_pubkey());
        let phase_clone = self.phase.read().unwrap().clone();
        let MigrationPhase::ReadyToEnable { genesis_cert } = phase_clone else {
            // >>> TLA_TRACE
            self.panicked.store(true, Ordering::Release);
            self.emit("EnableAlpenglowDuringStartup", vec![]);
            // <<< TLA_TRACE
            unreachable!(
                "{}: Programmer error, Attempting to enable alpenglow during startup without \
                 being ReadyToEnable",
                self.my_pubkey()
            );
        };

        let genesis_slot = genesis_cert.cert_type.slot();
        if self.poh_service_started.load(Ordering::Acquire) {
            let exit = AtomicBool::new(false);
            // >>> TLA_TRACE: suppress nested EnableAlpenglow emit; this caller
            // owns the EnableAlpenglowDuringStartup event for the transition.
            {
                let _g = SuppressGuard::new();
                self.enable_alpenglow(&exit);
            }
            // <<< TLA_TRACE
            // >>> TLA_TRACE: PoH branch — emit after we exit enable_alpenglow.
            self.emit("EnableAlpenglowDuringStartup", vec![]);
            // <<< TLA_TRACE
            return genesis_slot;
        }

        self.shutdown_poh.store(true, Ordering::Release);
        *self.phase.write().unwrap() = MigrationPhase::AlpenglowEnabled { genesis_cert };
        let (is_alpenglow_enabled, _condvar) = &self.migration_wait;
        *is_alpenglow_enabled.lock().unwrap() = true;
        warn!(
            "{}: Alpenglow enabled during startup! Genesis slot {genesis_slot}",
            self.my_pubkey()
        );
        // >>> TLA_TRACE: NoPoH branch.
        self.emit("EnableAlpenglowDuringStartup", vec![]);
        // <<< TLA_TRACE
        genesis_slot
    }

    pub fn alpenglow_rooted_new_epoch(&self, full_alpenglow_epoch: Epoch) {
        let outcome: bool;
        {
            let mut phase = self.phase.write().unwrap();
            outcome = matches!(*phase, MigrationPhase::AlpenglowEnabled { .. });
            if outcome {
                let cert = match &*phase {
                    MigrationPhase::AlpenglowEnabled { genesis_cert } => genesis_cert.clone(),
                    _ => unreachable!(),
                };
                *phase = MigrationPhase::FullAlpenglowEpoch {
                    genesis_cert: cert,
                    full_alpenglow_epoch,
                };
            }
        }
        if !outcome {
            // >>> TLA_TRACE: panic path.
            self.panicked.store(true, Ordering::Release);
            self.emit(
                "AlpenglowRootedNewEpoch",
                vec![("epoch".to_string(), format!("{}", full_alpenglow_epoch))],
            );
            // <<< TLA_TRACE
            unreachable!(
                "{}: Programmer error, Alpenglow rooted a block before it was enabled",
                self.my_pubkey()
            );
        }

        warn!(
            "{}: Migration epoch has concluded, entering full alpenglow epoch {}!",
            self.my_pubkey(),
            full_alpenglow_epoch
        );
        // >>> TLA_TRACE
        self.emit(
            "AlpenglowRootedNewEpoch",
            vec![("epoch".to_string(), format!("{}", full_alpenglow_epoch))],
        );
        // <<< TLA_TRACE
    }

    pub fn genesis_block(&self) -> Option<Block> {
        self.genesis_certificate().map(|cert| {
            cert.cert_type
                .to_block()
                .expect("Must be a genesis certificate")
        })
    }

    pub fn genesis_certificate(&self) -> Option<Arc<Certificate>> {
        let phase = self.phase.read().unwrap();
        match &*phase {
            MigrationPhase::PreFeatureActivation | MigrationPhase::Migration { .. } => None,
            MigrationPhase::ReadyToEnable {
                genesis_cert: certificate,
            }
            | MigrationPhase::AlpenglowEnabled {
                genesis_cert: certificate,
            }
            | MigrationPhase::FullAlpenglowEpoch {
                genesis_cert: certificate,
                ..
            } => Some(certificate.clone()),
        }
    }

    pub fn wait_for_migration_or_exit(&self, exit: &AtomicBool) -> Option<Block> {
        let (is_alpenglow_enabled, cvar) = &self.migration_wait;
        loop {
            if exit.load(Ordering::Relaxed) {
                return None;
            }
            let (enabled, _) = cvar
                .wait_timeout_while(
                    is_alpenglow_enabled.lock().unwrap(),
                    Duration::from_secs(5),
                    |is_alpenglow_enabled| !*is_alpenglow_enabled,
                )
                .unwrap();

            if *enabled {
                return Some(self.genesis_block().expect("Alpenglow is enabled"));
            }
        }
    }
}

// >>> TLA_TRACE: thread-local flag set while inside enable_alpenglow_during_startup
// so the nested enable_alpenglow does NOT emit its own EnableAlpenglow event.
thread_local! {
    static SUPPRESS_ENABLE_ALPENGLOW: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

struct SuppressGuard;
impl SuppressGuard {
    fn new() -> Self {
        SUPPRESS_ENABLE_ALPENGLOW.with(|c| c.set(true));
        SuppressGuard
    }
}
impl Drop for SuppressGuard {
    fn drop(&mut self) {
        SUPPRESS_ENABLE_ALPENGLOW.with(|c| c.set(false));
    }
}
// <<< TLA_TRACE

// >>> TLA_TRACE: simple JSON escape duplicated here to avoid a public dependency.
fn tla_trace_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c => out.push(c),
        }
    }
    out
}
// <<< TLA_TRACE
