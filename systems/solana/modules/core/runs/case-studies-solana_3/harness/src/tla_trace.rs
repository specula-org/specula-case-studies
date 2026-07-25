//! TLA+ trace emission module for Solana Tower BFT (solana_3 spec).
//!
//! Activated by setting `TLA_TRACE_FILE=<path>` before running. When the env
//! var is unset, all emit calls are cheap no-ops.
//!
//! Every line is a JSON object with `tag = "trace"` so Trace.tla's
//! `ndJsonDeserialize` consumer keeps it. The spec wrappers access:
//!   - `logline.event`  — the spec action name (e.g. "RecordBankVote")
//!   - `logline.node`   — validator id ("v1", "v2", "v3")
//!   - `logline.slot`, `logline.hash`, `logline.voter`, ...
//!   - `logline.state`  — nested object with `last_voted_slot`, `tower_root`,
//!                        `stray`, `pc_tower`, `adopt_pc`, `online`, ...
//!
//! Validator pubkeys map to spec names via `register_validator()` at the start
//! of each scenario. Hashes map to "hA"/"hB" via `intern_hash()`; the spec
//! only has two block-hashes per slot.

#![allow(dead_code)]

use {
    serde_json::{Value, json},
    solana_pubkey::Pubkey,
    std::{
        collections::HashMap,
        fs::{File, OpenOptions},
        io::Write,
        sync::{Mutex, OnceLock, atomic::{AtomicU64, Ordering}},
        time::{SystemTime, UNIX_EPOCH},
    },
};

struct TraceWriter {
    file: Mutex<File>,
    map: Mutex<HashMap<Pubkey, String>>,
    hash_map: Mutex<HashMap<solana_hash::Hash, String>>,
    seq: AtomicU64,
}

static WRITER: OnceLock<Option<TraceWriter>> = OnceLock::new();

fn writer() -> Option<&'static TraceWriter> {
    WRITER
        .get_or_init(|| match std::env::var("TLA_TRACE_FILE") {
            Ok(path) if !path.is_empty() => {
                let file = OpenOptions::new()
                    .create(true)
                    .write(true)
                    .truncate(true)
                    .open(&path)
                    .unwrap_or_else(|e| panic!("TLA_TRACE_FILE={path}: {e}"));
                Some(TraceWriter {
                    file: Mutex::new(file),
                    map: Mutex::new(HashMap::new()),
                    hash_map: Mutex::new(HashMap::new()),
                    seq: AtomicU64::new(0),
                })
            }
            _ => None,
        })
        .as_ref()
}

/// Spec name sentinels. Must match Trace.cfg's CONSTANTS.
/// Sentinel slot value for None — must NOT collide with any real slot
/// emitted in any scenario (we use only slots 0..=4). Spec configures
/// `NullSlot = 99` to match.
pub const NULL_SLOT_INT: i64 = 99;
pub const NULL_HASH: &str = "nullhash";

/// Map an implementation `Pubkey` to a spec-side validator name (e.g. "v1").
pub fn register_validator(pk: Pubkey, name: &str) {
    if let Some(w) = writer() {
        w.map.lock().unwrap().insert(pk, name.to_string());
    }
}

/// Look up the mapped name for a validator. Falls back to base58 pubkey when
/// not registered (makes the gap visible in the trace rather than silent).
pub fn nid(pk: &Pubkey) -> String {
    if let Some(w) = writer() {
        if let Some(name) = w.map.lock().unwrap().get(pk) {
            return name.clone();
        }
    }
    pk.to_string()
}

fn now_ns() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0)
}

/// Intern a Solana hash to a spec name. Pre-register the canonical hashes
/// you want to use as "hA"/"hB" with `register_hash()`; everything else
/// auto-interns to "hA","hB","hC",... but the spec only declares hA/hB so
/// out-of-range hashes will fail validation.
pub fn register_hash(h: solana_hash::Hash, name: &str) {
    if let Some(w) = writer() {
        w.hash_map.lock().unwrap().insert(h, name.to_string());
    }
}

/// Map a hash to its spec name. `Hash::default()` maps to NULL_HASH.
pub fn hash_str(h: &solana_hash::Hash) -> String {
    if h == &solana_hash::Hash::default() {
        return NULL_HASH.to_string();
    }
    if let Some(w) = writer() {
        let mut map = w.hash_map.lock().unwrap();
        if let Some(name) = map.get(h) {
            return name.clone();
        }
        // Fall through: auto-intern unmapped hashes. This indicates the
        // scenario forgot to pre-register a hash and should be fixed.
        let next = match map.len() {
            0 => "hA",
            1 => "hB",
            n => Box::leak(format!("h{n}").into_boxed_str()),
        };
        map.insert(*h, next.to_string());
        return next.to_string();
    }
    h.to_string()
}

/// Serialize Option<Slot> with the NULL_SLOT_INT sentinel for None.
pub fn slot_opt(slot: Option<u64>) -> Value {
    match slot {
        Some(s) => json!(s as i64),
        None => json!(NULL_SLOT_INT),
    }
}

/// Test whether tracing is active. Cheap no-op check for the hot path.
pub fn enabled() -> bool {
    writer().is_some()
}

/// Emit a config line declaring cluster topology + tuning. Should be the
/// first line per scenario.
pub fn emit_config(servers: &[&str], stakes: &[(&str, u64)]) {
    if let Some(w) = writer() {
        let stakes_obj: serde_json::Map<String, Value> = stakes
            .iter()
            .map(|(name, stake)| ((*name).to_string(), json!(stake)))
            .collect();
        let line = json!({
            "tag": "config",
            "ts": now_ns(),
            "config": {
                "servers": servers,
                "stakes": stakes_obj,
            }
        });
        let mut f = w.file.lock().unwrap();
        let _ = writeln!(f, "{line}");
        let _ = f.flush();
    }
}

/// Emit one spec event. `event` MUST be a flat JSON object whose keys merge
/// into the top-level envelope (tag, ts, seq prepended automatically).
pub fn emit(event: Value) {
    if let Some(w) = writer() {
        let seq = w.seq.fetch_add(1, Ordering::Relaxed);
        let mut envelope = serde_json::Map::new();
        envelope.insert("tag".to_string(), json!("trace"));
        envelope.insert("ts".to_string(), json!(now_ns()));
        envelope.insert("seq".to_string(), json!(seq));
        if let Value::Object(map) = event {
            for (k, v) in map {
                envelope.insert(k, v);
            }
        }
        let line = Value::Object(envelope);
        let mut f = w.file.lock().unwrap();
        let _ = writeln!(f, "{line}");
        let _ = f.flush();
    }
}

// =====================================================================
// Per-thread shadow state.
//
// The spec's `pcTower` and `adoptPc` shadow variables don't exist in the
// implementation — they track which phase of the vote/adopt pipeline a
// validator is in. We model them as thread-local state and let the test
// scenarios advance them at the right call boundaries.
//
// For OC accounting (AccumulateOCVote) the test must set the (slot, hash)
// bucket via `set_oc_context()` before driving VoteStakeTracker since the
// tracker itself doesn't know which bucket it belongs to.
//
// For gossip/replay ingest (GossipLatestFrozen) the test sets the observer
// pubkey so the instrumented LatestValidatorVotesForFrozenBanks can emit
// with the correct `receiver` field.
// =====================================================================

thread_local! {
    static CURRENT_OBSERVER: std::cell::Cell<Option<Pubkey>> = const { std::cell::Cell::new(None) };
    static OC_CONTEXT: std::cell::Cell<Option<(u64, solana_hash::Hash)>> =
        const { std::cell::Cell::new(None) };
    static PC_TOWER: std::cell::RefCell<HashMap<Pubkey, &'static str>> =
        std::cell::RefCell::new(HashMap::new());
    static ADOPT_PC: std::cell::RefCell<HashMap<Pubkey, &'static str>> =
        std::cell::RefCell::new(HashMap::new());
    static STRAY_FLAG: std::cell::RefCell<HashMap<Pubkey, bool>> =
        std::cell::RefCell::new(HashMap::new());
    static ONLINE_FLAG: std::cell::RefCell<HashMap<Pubkey, bool>> =
        std::cell::RefCell::new(HashMap::new());
}

pub fn set_current_observer(pk: Option<Pubkey>) {
    CURRENT_OBSERVER.with(|c| c.set(pk));
}

pub fn current_observer() -> Option<Pubkey> {
    CURRENT_OBSERVER.with(|c| c.get())
}

pub fn set_oc_context(ctx: Option<(u64, solana_hash::Hash)>) {
    OC_CONTEXT.with(|c| c.set(ctx));
}

pub fn oc_context() -> Option<(u64, solana_hash::Hash)> {
    OC_CONTEXT.with(|c| c.get())
}

/// Set the spec's `pcTower[v]` shadow value: one of "idle", "recorded",
/// "saved", "broadcast".
pub fn set_pc_tower(pk: Pubkey, value: &'static str) {
    PC_TOWER.with(|c| {
        c.borrow_mut().insert(pk, value);
    });
}

pub fn get_pc_tower(pk: &Pubkey) -> &'static str {
    PC_TOWER.with(|c| *c.borrow().get(pk).unwrap_or(&"idle"))
}

/// Set the spec's `adoptPc[v]` shadow value: one of "none", "vote_state_set",
/// "last_vote_set".
pub fn set_adopt_pc(pk: Pubkey, value: &'static str) {
    ADOPT_PC.with(|c| {
        c.borrow_mut().insert(pk, value);
    });
}

pub fn get_adopt_pc(pk: &Pubkey) -> &'static str {
    ADOPT_PC.with(|c| *c.borrow().get(pk).unwrap_or(&"none"))
}

/// Set `liveTower[v].stray` shadow. Test code maintains this since it crosses
/// Tower::adjust_lockouts_after_replay (which sets stray_restored_slot but
/// not a public boolean we can sample cheaply post-call).
pub fn set_stray(pk: Pubkey, value: bool) {
    STRAY_FLAG.with(|c| {
        c.borrow_mut().insert(pk, value);
    });
}

pub fn get_stray(pk: &Pubkey) -> bool {
    STRAY_FLAG.with(|c| *c.borrow().get(pk).unwrap_or(&false))
}

/// Set `online[v]` shadow.
pub fn set_online(pk: Pubkey, value: bool) {
    ONLINE_FLAG.with(|c| {
        c.borrow_mut().insert(pk, value);
    });
}

pub fn get_online(pk: &Pubkey) -> bool {
    ONLINE_FLAG.with(|c| *c.borrow().get(pk).unwrap_or(&true))
}

/// Build the common "state" object that goes into every event under
/// `logline.state`. Spec Trace.tla `ValidateTowerState(v)` reads these.
pub fn tower_state_obj(
    pk: &Pubkey,
    last_voted_slot: Option<u64>,
    last_voted_hash: Option<&solana_hash::Hash>,
    tower_root: u64,
) -> Value {
    json!({
        "last_voted_slot": slot_opt(last_voted_slot),
        "last_voted_hash": last_voted_hash.map(hash_str).unwrap_or_else(|| NULL_HASH.to_string()),
        "tower_root": tower_root as i64,
        "stray": get_stray(pk),
        "pc_tower": get_pc_tower(pk),
        "adopt_pc": get_adopt_pc(pk),
        "online": get_online(pk),
    })
}

/// State object specifically for `StoreTower` events — includes the
/// persisted-tower fields.
pub fn store_tower_state_obj(
    pk: &Pubkey,
    last_voted_slot: Option<u64>,
    last_voted_hash: Option<&solana_hash::Hash>,
    tower_root: u64,
    persisted_last_voted_slot: Option<u64>,
    persisted_root: u64,
) -> Value {
    let mut obj = match tower_state_obj(pk, last_voted_slot, last_voted_hash, tower_root) {
        Value::Object(m) => m,
        _ => unreachable!(),
    };
    obj.insert(
        "persisted_last_voted_slot".to_string(),
        slot_opt(persisted_last_voted_slot),
    );
    obj.insert("persisted_root".to_string(), json!(persisted_root as i64));
    Value::Object(obj)
}

/// OC state object — populated by `AccumulateOCVote` events.
pub fn oc_state_obj(
    oc_stake: u64,
    oc_voters_size: u64,
    oc_reached: bool,
    dc_reached: bool,
) -> Value {
    json!({
        "oc_stake": oc_stake as i64,
        "oc_voters_size": oc_voters_size as i64,
        "oc_reached": oc_reached,
        "dc_reached": dc_reached,
    })
}
