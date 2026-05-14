//! TLA+ trace emission for Aptos BFT (round 2).
//!
//! Single-file NDJSON writer used by the round-2 trace harness.  Every
//! emitted line carries `"tag":"trace"` so Trace.tla can filter on it.
//!
//! Lifecycle:
//!   1. Test scenario calls `tla_trace::init(path, server_map)` once.
//!   2. Before driving a particular validator through SafetyRules,
//!      the test calls `set_active_nid("sN")`.  Instrumented code
//!      inside `safety_rules.rs` / `safety_rules_2chain.rs` reads
//!      `active_nid()` so each emit is tagged with the right server.
//!   3. Test driver also calls `emit_event` directly for round-manager
//!      level events (Propose, ReceiveProposal, ReceiveVote, FormQC,
//!      ReceiveOrderVote, FormOrderingCert, ReceiveTimeout, FormTC,
//!      ReceiveCommitVote, ExecuteBlock, AggregateCommitVotes,
//!      PersistBlock, ResetPipeline, EchoTimeout, Recover).
//!
//! Trace envelope (matches `Trace.tla`):
//!   {"tag":"trace","ts":<u64-millis>,
//!    "event":{"name":"<action>","nid":"<sid>","epoch":<e>,"round":<r>,
//!             "state":{...}, "msg":{...}?}}

use aptos_consensus_types::safety_data::SafetyData;
use serde_json::{json, Value};
use std::cell::RefCell;
use std::collections::HashMap;
use std::fs::OpenOptions;
use std::io::{BufWriter, Write};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

static WRITER: OnceLock<Mutex<TraceWriter>> = OnceLock::new();
/// Maps `format!("{:x}", PeerId)` → TLA+ sid ("s1" / "s2" / ...).
static SERVER_MAP: OnceLock<Mutex<HashMap<String, String>>> = OnceLock::new();

thread_local! {
    /// The TLA+ sid the next emit should be tagged with.  Set by the
    /// test driver before each SafetyRules call.
    static ACTIVE_NID: RefCell<Option<String>> = const { RefCell::new(None) };
}

struct TraceWriter {
    file: BufWriter<std::fs::File>,
}

/// Open the trace file.  Idempotent after the first successful call.
pub fn init(path: &str, server_map: HashMap<String, String>) {
    let file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(path)
        .unwrap_or_else(|e| panic!("tla_trace: cannot open {}: {}", path, e));
    let _ = WRITER.set(Mutex::new(TraceWriter {
        file: BufWriter::new(file),
    }));
    let _ = SERVER_MAP.set(Mutex::new(server_map));
}

pub fn is_active() -> bool {
    WRITER.get().is_some()
}

/// Look up the sid for a PeerId hex string.  Returns the hex unchanged
/// if no mapping is registered.
pub fn nid(author_hex: &str) -> String {
    SERVER_MAP
        .get()
        .and_then(|m| m.lock().ok().and_then(|g| g.get(author_hex).cloned()))
        .unwrap_or_else(|| author_hex.to_string())
}

/// Set the active nid for this thread.  The next `safety_rules`
/// instrumentation point that fires will tag its emit with this sid.
pub fn set_active_nid<S: Into<String>>(sid: S) {
    ACTIVE_NID.with(|c| *c.borrow_mut() = Some(sid.into()));
}

/// Clear the active nid.  Call after the SafetyRules call returns so
/// no stray events get misattributed.
pub fn clear_active_nid() {
    ACTIVE_NID.with(|c| *c.borrow_mut() = None);
}

/// Read the active nid (returns `"unknown"` if unset).
pub fn active_nid() -> String {
    ACTIVE_NID.with(|c| c.borrow().clone().unwrap_or_else(|| "unknown".to_string()))
}

/// Build the `state` JSON object for safety-data-driven events.
///
/// We deliberately do NOT emit a JSON null for the missing-lastVote
/// case — the TLC Json deserializer rejects raw nulls.  We emit the
/// sentinel string "" instead (the spec's `TraceValue` normalises both
/// "" and "null" to `Nil`).
pub fn safety_state(sd: &SafetyData) -> Value {
    let lv = sd
        .last_vote
        .as_ref()
        .map(|v| {
            json!({
                "round": v.vote_data().proposed().round(),
                "value": format!("{}", v.vote_data().proposed().id()),
            })
        })
        .unwrap_or_else(|| json!(""));
    json!({
        "epoch":               sd.epoch,
        "lastVotedRound":      sd.last_voted_round,
        "preferredRound":      sd.preferred_round,
        "oneChainRound":       sd.one_chain_round,
        "highestTimeoutRound": sd.highest_timeout_round,
        "lastVote":            lv,
    })
}

/// Merge extra fields into a state object.
pub fn merge_state(mut base: Value, extra: Value) -> Value {
    if let (Some(b), Some(e)) = (base.as_object_mut(), extra.as_object()) {
        for (k, v) in e {
            b.insert(k.clone(), v.clone());
        }
    }
    base
}

/// Emit one event line.  The envelope adds `"tag":"trace"`.
pub fn emit_event(
    name: &str,
    nid: &str,
    round: u64,
    epoch: u64,
    state: Value,
    msg: Option<Value>,
) {
    let mut ev = json!({
        "name":  name,
        "nid":   nid,
        "epoch": epoch,
        "round": round,
        "state": state,
    });
    if let Some(m) = msg {
        ev["msg"] = m;
    }
    let line = json!({
        "tag":   "trace",
        "ts":    now_ms(),
        "event": ev,
    });
    write_line(&line);
}

/// Emit a config line (`"tag":"config"`).  Trace.tla ignores it because
/// the tag filter only matches "trace"; useful as a header for humans.
pub fn emit_config(servers: &[String]) {
    let line = json!({
        "tag": "config",
        "ts":  now_ms(),
        "config": {
            "servers": servers,
            "round2":  true,
        },
    });
    write_line(&line);
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn write_line(value: &Value) {
    if let Some(w) = WRITER.get() {
        if let Ok(mut guard) = w.lock() {
            let _ = serde_json::to_writer(&mut guard.file, value);
            let _ = guard.file.write_all(b"\n");
            let _ = guard.file.flush();
        }
    }
}
