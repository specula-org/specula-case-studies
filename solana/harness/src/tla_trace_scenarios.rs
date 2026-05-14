//! TLA+ trace generation scenarios for Solana Tower BFT.
//!
//! Each `#[test]` drives the real Tower BFT code paths (`Tower::record_bank_vote`,
//! `FileTowerStorage::store`, `Tower::restore`) and emits NDJSON trace events
//! that the `Trace.tla` validator consumes.
//!
//! Trace destination: the file named by `SOLANA_TLA_TRACE_FILE`.  `run.sh`
//! sets a distinct value per scenario so the NDJSON outputs do not interleave.
//!
//! Hash labels: the spec's `CanonicalSlotHash` constant fixes
//!   slot 1 -> hA, slot 2 -> hA (main fork), slot 3 -> hB (alt fork).
//! Real bank hashes are unique per slot, so we never emit them verbatim --
//! the harness maps every emitted vote to the spec's canonical label for
//! that slot.  The fork-tree shape used in the harness must therefore match
//! `Trace.cfg`'s ParentOfSlot / CanonicalSlotHash defaults.

#![cfg(feature = "dev-context-only-utils")]

use {
    solana_clock::Slot,
    solana_core::{
        consensus::{
            Tower,
            tower_storage::{FileTowerStorage, SavedTower, SavedTowerVersions, TowerStorage},
        },
        vote_simulator::VoteSimulator,
    },
    solana_pubkey::Pubkey,
    solana_signer::Signer,
    std::{collections::HashMap, fs::OpenOptions, io::Write, sync::Mutex},
    tempfile::TempDir,
    trees::tr,
};

// ---------- inlined trace emission module ----------
// Trace destination is selected at first-emit time from the
// `SOLANA_TLA_TRACE_FILE` env variable; missing/empty -> no-op.

struct TraceWriter {
    file: Option<std::fs::File>,
}

impl TraceWriter {
    fn open() -> Self {
        let path = std::env::var("SOLANA_TLA_TRACE_FILE").unwrap_or_default();
        if path.is_empty() {
            return Self { file: None };
        }
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .ok();
        Self { file }
    }
}

fn writer() -> std::sync::MutexGuard<'static, TraceWriter> {
    static W: std::sync::OnceLock<Mutex<TraceWriter>> = std::sync::OnceLock::new();
    W.get_or_init(|| Mutex::new(TraceWriter::open()))
        .lock()
        .unwrap_or_else(|p| p.into_inner())
}

fn ts_ns() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0)
}

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

enum JsonValue {
    Str(String),
    UInt(u64),
    Bool(bool),
}

impl JsonValue {
    fn render(&self) -> String {
        match self {
            JsonValue::Str(s) => format!("\"{}\"", json_escape(s)),
            JsonValue::UInt(u) => u.to_string(),
            JsonValue::Bool(b) => b.to_string(),
        }
    }
}

fn s<T: ToString>(v: T) -> JsonValue {
    JsonValue::Str(v.to_string())
}
fn u(v: u64) -> JsonValue {
    JsonValue::UInt(v)
}
fn b(v: bool) -> JsonValue {
    JsonValue::Bool(v)
}

struct Event {
    parts: Vec<String>,
}

impl Event {
    fn new(name: &str) -> Self {
        Self {
            parts: vec![format!("\"name\":\"{}\"", json_escape(name))],
        }
    }
    fn nid(mut self, v: &str) -> Self {
        self.parts.push(format!("\"nid\":\"{}\"", json_escape(v)));
        self
    }
    fn slot(mut self, sl: u64) -> Self {
        self.parts.push(format!("\"slot\":{}", sl));
        self
    }
    fn hash(mut self, h: &str) -> Self {
        self.parts.push(format!("\"hash\":\"{}\"", json_escape(h)));
        self
    }
    fn state(mut self, fields: &[(&str, JsonValue)]) -> Self {
        let body = fields
            .iter()
            .map(|(k, v)| format!("\"{}\":{}", json_escape(k), v.render()))
            .collect::<Vec<_>>()
            .join(",");
        self.parts.push(format!("\"state\":{{{}}}", body));
        self
    }
    fn msg(mut self, fields: &[(&str, JsonValue)]) -> Self {
        let body = fields
            .iter()
            .map(|(k, v)| format!("\"{}\":{}", json_escape(k), v.render()))
            .collect::<Vec<_>>()
            .join(",");
        self.parts.push(format!("\"msg\":{{{}}}", body));
        self
    }
    fn emit(self) {
        let mut w = writer();
        let Some(file) = w.file.as_mut() else { return };
        let line = format!(
            "{{\"tag\":\"trace\",\"ts_ns\":{},\"event\":{{{}}}}}\n",
            ts_ns(),
            self.parts.join(",")
        );
        let _ = file.write_all(line.as_bytes());
        let _ = file.flush();
    }
}

fn emit_config(servers: &[&str], max_slot: u64, hashes: &[&str]) {
    let mut w = writer();
    let Some(file) = w.file.as_mut() else { return };
    let join = |xs: &[&str]| -> String {
        xs.iter()
            .map(|s| format!("\"{}\"", json_escape(s)))
            .collect::<Vec<_>>()
            .join(",")
    };
    let line = format!(
        "{{\"tag\":\"config\",\"ts_ns\":{},\"config\":{{\"servers\":[{}],\"max_slot\":{},\"hashes\":[{}]}}}}\n",
        ts_ns(),
        join(servers),
        max_slot,
        join(hashes),
    );
    let _ = file.write_all(line.as_bytes());
    let _ = file.flush();
}

// ---------- end inlined trace emission module ----------

/// `CanonicalSlotHash[s]` per the spec's default `Trace.cfg`.  Each slot
/// always maps to the same label, so a vote on slot N emits `hash = hX`
/// regardless of the real bank hash.
fn canonical_hash_label(slot: Slot) -> &'static str {
    match slot {
        1 => "hA",
        2 => "hA",
        3 => "hB",
        _ => "hA",
    }
}

struct Harness {
    sim: VoteSimulator,
    tower_storage: FileTowerStorage,
    _tower_dir: TempDir,
    nid: HashMap<Pubkey, String>,
    ordered_pubkeys: Vec<Pubkey>,
}

impl Harness {
    fn new(num_validators: usize) -> Self {
        let sim = VoteSimulator::new(num_validators);
        let tower_dir = TempDir::new().expect("temp dir");
        let tower_storage = FileTowerStorage::new(tower_dir.path().to_path_buf());
        let mut keys: Vec<Pubkey> = sim.node_pubkeys.clone();
        keys.sort();
        let mut nid = HashMap::new();
        for (idx, pk) in keys.iter().enumerate() {
            nid.insert(*pk, format!("v{}", idx + 1));
        }
        Self {
            sim,
            tower_storage,
            _tower_dir: tower_dir,
            nid,
            ordered_pubkeys: keys,
        }
    }

    fn nid(&self, pk: &Pubkey) -> &str {
        self.nid.get(pk).expect("validator not registered").as_str()
    }

    fn emit_config_line(&self, max_slot: u64) {
        let servers_owned: Vec<String> = self
            .ordered_pubkeys
            .iter()
            .map(|p| self.nid(p).to_string())
            .collect();
        let servers: Vec<&str> = servers_owned.iter().map(|s| s.as_str()).collect();
        emit_config(&servers, max_slot, &["hA", "hB"]);
    }

    fn tower_vote_count(tower: &Tower) -> u64 {
        // The `last_vote` VoteTransaction holds the per-vote lockouts the
        // validator committed to when it last cast a vote.  This matches the
        // spec's Len(tower[v].votes) after record_bank_vote_and_update_lockouts.
        tower.last_vote().len() as u64
    }

    fn emit_record_vote(&self, voter: &Pubkey, tower: &Tower, slot: Slot) {
        let last_slot = tower.last_voted_slot().unwrap_or(0);
        let last_hash = canonical_hash_label(last_slot);
        let count = Self::tower_vote_count(tower);
        let root = tower.root();
        Event::new("RecordVote")
            .nid(self.nid(voter))
            .slot(slot)
            .hash(canonical_hash_label(slot))
            .state(&[
                ("lastVotedSlot", u(last_slot)),
                ("lastVotedHash", s(last_hash)),
                ("towerVoteCount", u(count)),
                ("rootSlot", u(root)),
                ("alive", b(true)),
                ("panicked", b(false)),
            ])
            .emit();
    }

    fn persist_and_emit(&self, voter: &Pubkey, tower: &Tower) {
        let keypair = self
            .sim
            .validator_keypairs
            .get(voter)
            .expect("keypair")
            .node_keypair
            .insecure_clone();
        let mut local = tower.clone();
        local.node_pubkey = keypair.pubkey();
        let saved = SavedTower::new(&local, &keypair).expect("SavedTower::new");
        let versions = SavedTowerVersions::from(saved);
        self.tower_storage
            .store(&versions)
            .expect("tower store should succeed");
        let persisted_slot = tower.last_voted_slot().unwrap_or(0);
        let persisted_root = tower.root();
        Event::new("PersistTower")
            .nid(self.nid(voter))
            .state(&[
                ("persistedLastVotedSlot", u(persisted_slot)),
                ("persistedRootSlot", u(persisted_root)),
                ("alive", b(true)),
                ("panicked", b(false)),
            ])
            .emit();
    }

    fn emit_broadcast_vote(&self, voter: &Pubkey, tower: &Tower) {
        let last_slot = tower.last_voted_slot().unwrap_or(0);
        let hash_label = canonical_hash_label(last_slot);
        Event::new("BroadcastVote")
            .nid(self.nid(voter))
            .state(&[
                ("lastVotedSlot", u(last_slot)),
                ("lastVotedHash", s(hash_label)),
                ("alive", b(true)),
                ("panicked", b(false)),
            ])
            .emit();
    }

    /// Drive a single record-persist-broadcast cycle by calling the real
    /// `Tower::record_bank_vote` (which runs `record_bank_vote_and_update_lockouts`
    /// internally) followed by the real `FileTowerStorage::store`.
    fn record_persist_broadcast(&self, voter: &Pubkey, tower: &mut Tower, vote_slot: Slot) {
        let bank = self
            .sim
            .bank_forks
            .read()
            .unwrap()
            .get(vote_slot)
            .expect("bank for vote_slot exists");
        let _ = tower.record_bank_vote(&bank);
        self.emit_record_vote(voter, tower, vote_slot);
        self.persist_and_emit(voter, tower);
        self.emit_broadcast_vote(voter, tower);
    }

    fn emit_crash(&self, voter: &Pubkey) {
        Event::new("Crash")
            .nid(self.nid(voter))
            .state(&[("alive", b(false)), ("panicked", b(false))])
            .emit();
    }

    fn emit_crash_before_fsync(&self, voter: &Pubkey) {
        Event::new("CrashBeforeFsync")
            .nid(self.nid(voter))
            .state(&[("alive", b(false)), ("panicked", b(false))])
            .emit();
    }

    fn restart_and_emit(&self, voter: &Pubkey) -> Tower {
        let pk = self
            .sim
            .validator_keypairs
            .get(voter)
            .expect("keypair")
            .node_keypair
            .pubkey();
        let tower =
            Tower::restore(&self.tower_storage, &pk).unwrap_or_else(|_| Tower::default());
        let last_slot = tower.last_voted_slot().unwrap_or(0);
        let hash_label = canonical_hash_label(last_slot);
        let count = Self::tower_vote_count(&tower);
        let root = tower.root();
        Event::new("Restart")
            .nid(self.nid(voter))
            .state(&[
                ("alive", b(true)),
                ("panicked", b(false)),
                ("lastVotedSlot", u(last_slot)),
                ("lastVotedHash", s(hash_label)),
                ("towerVoteCount", u(count)),
                ("rootSlot", u(root)),
            ])
            .emit();
        tower
    }

    fn emit_receive_vote(&self, receiver: &Pubkey, source: &Pubkey, last_slot: Slot, kind: &str) {
        let nid_str = self.nid(receiver).to_string();
        let source_str = self.nid(source).to_string();
        let hash_label = canonical_hash_label(last_slot).to_string();
        Event::new("ReceiveVote")
            .nid(&nid_str)
            .msg(&[
                ("source", s(source_str)),
                ("last_slot", u(last_slot)),
                ("last_hash", s(hash_label)),
                ("kind", s(kind.to_string())),
            ])
            .state(&[("alive", b(true)), ("panicked", b(false))])
            .emit();
    }

    fn emit_reach_oc(&self, slot: Slot) {
        Event::new("ReachOC")
            .slot(slot)
            .hash(canonical_hash_label(slot))
            .emit();
    }

    fn emit_purge_unconfirmed_slot(&self, voter: &Pubkey, slot: Slot) {
        Event::new("PurgeUnconfirmedSlot")
            .nid(self.nid(voter))
            .slot(slot)
            .state(&[("alive", b(true)), ("panicked", b(false))])
            .emit();
    }

    fn emit_process_duplicate_confirmed(&self, voter: &Pubkey, slot: Slot, panicked: bool) {
        let alive = !panicked;
        Event::new("ProcessDuplicateConfirmedSignal")
            .nid(self.nid(voter))
            .slot(slot)
            .hash(canonical_hash_label(slot))
            .state(&[("alive", b(alive)), ("panicked", b(panicked))])
            .emit();
    }
}

// -----------------------------------------------------------------------------
// SCENARIO 1: Basic vote pipeline + crash + restart on a single fork.
// Exercises: RecordVote, PersistTower, BroadcastVote, Crash, Restart.
// Fork tree: 0 -> 1 -> 2 (single chain).  Votes: slot 1, slot 2 by v1.
// -----------------------------------------------------------------------------
#[test]
fn scenario_basic_voting_pipeline() {
    let harness = Harness::new(2);
    harness.emit_config_line(3);

    let voter = harness.ordered_pubkeys[0];
    let mut tower = Tower::default();
    tower.node_pubkey = harness
        .sim
        .validator_keypairs
        .get(&voter)
        .unwrap()
        .node_keypair
        .pubkey();

    let forks = tr(0) / (tr(1) / tr(2));
    let mut cluster_votes: HashMap<Pubkey, Vec<u64>> = HashMap::new();
    cluster_votes.insert(voter, vec![1, 2]);
    let mut h = harness;
    h.sim.fill_bank_forks(forks, &cluster_votes, true);

    for slot in [1u64, 2] {
        h.record_persist_broadcast(&voter, &mut tower, slot);
    }

    h.emit_crash(&voter);
    let restored = h.restart_and_emit(&voter);
    assert_eq!(restored.last_voted_slot(), Some(2));
}

// -----------------------------------------------------------------------------
// SCENARIO 2: Crash between PersistTower and BroadcastVote (the window the
// spec's CrashBeforeFsync action models: pendingVoteOp /= Nil, stored = TRUE).
// In the spec, both tower and persistedTower regress to EmptyTower on this
// fault — the harness wipes the tower file before Restart so the real
// `Tower::restore` reproduces that behavior.
// Exercises: RecordVote, PersistTower, CrashBeforeFsync, Restart.
// -----------------------------------------------------------------------------
#[test]
fn scenario_crash_before_fsync() {
    let harness = Harness::new(2);
    harness.emit_config_line(3);

    let voter = harness.ordered_pubkeys[0];
    let mut tower = Tower::default();
    tower.node_pubkey = harness
        .sim
        .validator_keypairs
        .get(&voter)
        .unwrap()
        .node_keypair
        .pubkey();

    let forks = tr(0) / tr(1);
    let mut cluster_votes: HashMap<Pubkey, Vec<u64>> = HashMap::new();
    cluster_votes.insert(voter, vec![1]);
    let mut h = harness;
    h.sim.fill_bank_forks(forks, &cluster_votes, true);

    // record + persist, NO broadcast (so the spec's pendingVoteOp.stored=true
    // window is preserved when CrashBeforeFsync fires).
    let bank = h
        .sim
        .bank_forks
        .read()
        .unwrap()
        .get(1)
        .expect("bank for vote_slot 1");
    let _ = tower.record_bank_vote(&bank);
    h.emit_record_vote(&voter, &tower, 1);
    h.persist_and_emit(&voter, &tower);

    // Wipe the persisted tower file to model the spec's "EmptyTower on disk"
    // post-condition.  Then emit CrashBeforeFsync; Restart returns an empty
    // tower because the file is gone.
    let pk = h
        .sim
        .validator_keypairs
        .get(&voter)
        .unwrap()
        .node_keypair
        .pubkey();
    let tower_path = h.tower_storage.filename(&pk);
    std::fs::remove_file(&tower_path).ok();
    h.emit_crash_before_fsync(&voter);
    let restored = h.restart_and_emit(&voter);
    assert_eq!(restored.last_voted_slot(), None);
}

// -----------------------------------------------------------------------------
// SCENARIO 3: 4-validator vote pipeline + cross-validator vote receipt.
// Exercises: RecordVote, PersistTower, BroadcastVote, ReceiveVote.
// Demonstrates the per-(slot,hash) OC accumulator picking up stake-weight
// from 4 distinct validators on slot 1.
// -----------------------------------------------------------------------------
#[test]
fn scenario_oc_threshold_slot1() {
    let harness = Harness::new(4);
    harness.emit_config_line(3);

    let forks = tr(0) / tr(1);
    let voters: Vec<Pubkey> = harness.ordered_pubkeys.clone();
    let mut cluster_votes: HashMap<Pubkey, Vec<u64>> = HashMap::new();
    for v in &voters {
        cluster_votes.insert(*v, vec![1]);
    }
    let mut h = harness;
    h.sim.fill_bank_forks(forks, &cluster_votes, true);

    let mut towers: HashMap<Pubkey, Tower> = HashMap::new();
    for v in &voters {
        let mut tower = Tower::default();
        tower.node_pubkey = h
            .sim
            .validator_keypairs
            .get(v)
            .unwrap()
            .node_keypair
            .pubkey();
        h.record_persist_broadcast(v, &mut tower, 1);
        towers.insert(*v, tower);
    }

    // All 4 broadcast votes are received by v1.  In the spec, ReceiveVote
    // updates `ocStake[slot][hash]`; once the bucket holds enough stake, a
    // `SilentReachOC` action can fire — but only when the *next* event needs
    // it, so we do not emit ReachOC here.
    let receiver = voters[0];
    for src in voters.iter() {
        h.emit_receive_vote(&receiver, src, 1, "replay");
    }
}

// -----------------------------------------------------------------------------
// SCENARIO 4: Three-stage vote pipeline on the two-fork shape, then a crash
// and successful restart from the persisted tower.  This exercises the same
// events as scenario 1 but with the alternate slot-3 fork bank populated in
// the fork tree (so the trace fixes both `hA` and `hB` slots in the spec's
// MaxSlot=3 world).
// Exercises: RecordVote, PersistTower, BroadcastVote, Crash, Restart.
// -----------------------------------------------------------------------------
#[test]
fn scenario_two_fork_persistence() {
    let harness = Harness::new(2);
    harness.emit_config_line(3);

    let forks = tr(0) / (tr(1) / (tr(2)) / (tr(3)));
    let voter = harness.ordered_pubkeys[0];
    let mut cluster_votes: HashMap<Pubkey, Vec<u64>> = HashMap::new();
    cluster_votes.insert(voter, vec![1, 2]);
    let mut h = harness;
    h.sim.fill_bank_forks(forks, &cluster_votes, true);

    let mut tower = Tower::default();
    tower.node_pubkey = h
        .sim
        .validator_keypairs
        .get(&voter)
        .unwrap()
        .node_keypair
        .pubkey();

    h.record_persist_broadcast(&voter, &mut tower, 1);
    h.record_persist_broadcast(&voter, &mut tower, 2);

    // Validator goes down cleanly, then comes back up and reloads its
    // tower from disk.
    h.emit_crash(&voter);
    let restored = h.restart_and_emit(&voter);
    assert_eq!(restored.last_voted_slot(), Some(2));
}
