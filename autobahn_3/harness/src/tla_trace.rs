//! TLA+ Trace emission for Autobahn BFT consensus.
//!
//! Emits NDJSON trace events compatible with Trace.tla.
//! Activated by setting the `TLA_TRACE_FILE` environment variable.
//!
//! Output format (flat, matching Trace.tla's logline access pattern):
//!   {"tag":"consensus","event":"SendPrepare","node":"n1","slot":1,"view":1,"val":"v1","state":{...}}
//!
//! Thread safety: Uses OnceLock<Mutex<TraceWriter>>. All emit calls
//! are serialized through the mutex.

use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs::File;
use std::io::{BufWriter, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

use crypto::PublicKey;

// ---------------------------------------------------------------------------
// Global state
// ---------------------------------------------------------------------------

static WRITER: OnceLock<Mutex<TraceWriter>> = OnceLock::new();
static SERVER_MAP: OnceLock<Mutex<ServerMap>> = OnceLock::new();
static FIRST_EVENT: AtomicBool = AtomicBool::new(true);

struct TraceWriter {
    file: BufWriter<File>,
}

struct ServerMap {
    /// Maps PublicKey hex string → TLA+ server name ("n1", "n2", ...)
    map: HashMap<String, String>,
    next_id: usize,
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Try to initialize tracing from the `TLA_TRACE_FILE` environment variable.
/// Call once at startup. No-op if env var is not set or already initialized.
pub fn try_init() {
    if WRITER.get().is_some() {
        return;
    }
    if let Ok(path) = std::env::var("TLA_TRACE_FILE") {
        if let Some(parent) = std::path::Path::new(&path).parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let file = std::fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .open(&path)
            .unwrap_or_else(|e| panic!("tla_trace: failed to open {}: {}", path, e));
        let _ = WRITER.set(Mutex::new(TraceWriter {
            file: BufWriter::new(file),
        }));
        let _ = SERVER_MAP.set(Mutex::new(ServerMap {
            map: HashMap::new(),
            next_id: 1,
        }));
        FIRST_EVENT.store(true, Ordering::SeqCst);
        eprintln!("[tla_trace] Tracing to: {}", path);
    }
}

/// Returns true if tracing is active.
pub fn is_active() -> bool {
    WRITER.get().is_some()
}

/// Map a PublicKey to its TLA+ server name ("n1", "n2", ...).
/// Assigns names in order of first encounter.
pub fn nid(pk: &PublicKey) -> String {
    if let Some(sm) = SERVER_MAP.get() {
        if let Ok(mut guard) = sm.lock() {
            let key = pk_hex(pk);
            if let Some(name) = guard.map.get(&key) {
                return name.clone();
            }
            let name = format!("n{}", guard.next_id);
            guard.next_id += 1;
            guard.map.insert(key, name.clone());
            return name;
        }
    }
    format!("{:?}", pk)
}

/// Register all server public keys upfront so node_map is complete on the first event.
pub fn register_servers(keys: &[PublicKey]) {
    for pk in keys {
        nid(pk);
    }
}

/// Map a proposal value to an abstract TLA+ value name.
/// Uses a global counter: first distinct value → "v1", second → "v2", etc.
static VALUE_MAP: OnceLock<Mutex<(HashMap<Vec<u8>, String>, usize)>> = OnceLock::new();

pub fn abstract_value(digest_bytes: &[u8]) -> String {
    let vm = VALUE_MAP.get_or_init(|| Mutex::new((HashMap::new(), 1)));
    if let Ok(mut guard) = vm.lock() {
        let key = digest_bytes.to_vec();
        if let Some(name) = guard.0.get(&key) {
            return name.clone();
        }
        let name = format!("v{}", guard.1);
        guard.1 += 1;
        guard.0.insert(key, name.clone());
        return name;
    }
    "v?".to_string()
}

// ---------------------------------------------------------------------------
// State snapshot builder
// ---------------------------------------------------------------------------

/// Build a state snapshot JSON object for the given slot.
/// Field names match Trace.tla's ValidateNodeState access pattern.
pub fn make_state(view: u64, committed: bool) -> Value {
    json!({
        "view": view,
        "committed": if committed { "true" } else { "false" },
    })
}

/// Build a state snapshot with confirm_voted_value (for ReceiveConfirm events).
pub fn make_state_with_confirm(view: u64, committed: bool, confirm_voted_value: &str) -> Value {
    json!({
        "view": view,
        "committed": if committed { "true" } else { "false" },
        "confirm_voted_value": confirm_voted_value,
    })
}

// ---------------------------------------------------------------------------
// Core emit function
// ---------------------------------------------------------------------------

/// Emit a trace event in the flat NDJSON format expected by Trace.tla.
///
/// Every line has: event, node, slot, view, state, ts.
/// The value field is included when present (required by Trace.tla for most events).
/// The first event also includes node_map.
pub fn emit_event(
    event: &str,
    node: &str,
    slot: u64,
    view: u64,
    value: Option<&str>,
    state: Value,
) {
    let mut line = json!({
        "event": event,
        "node": node,
        "slot": slot,
        "view": view,
        "state": state,
        "ts": now_ns().to_string(),
    });
    if let Some(v) = value {
        line["value"] = json!(v);
    }
    // Include node_map on the first event
    if FIRST_EVENT.swap(false, Ordering::SeqCst) {
        if let Some(sm) = SERVER_MAP.get() {
            if let Ok(guard) = sm.lock() {
                let node_map: serde_json::Map<String, Value> = guard
                    .map
                    .iter()
                    .map(|(hex_pk, name)| (hex_pk.clone(), json!(name)))
                    .collect();
                line["node_map"] = Value::Object(node_map);
            }
        }
    }
    write_line(&line);
}

// ---------------------------------------------------------------------------
// Convenience emit wrappers (match Trace.tla event names)
// ---------------------------------------------------------------------------

pub fn emit_send_prepare(nid_str: &str, slot: u64, view: u64, value: &str, state: Value) {
    emit_event("SendPrepare", nid_str, slot, view, Some(value), state);
}

pub fn emit_receive_prepare(nid_str: &str, slot: u64, view: u64, value: &str, state: Value) {
    emit_event("ReceivePrepare", nid_str, slot, view, Some(value), state);
}

pub fn emit_send_confirm(nid_str: &str, slot: u64, view: u64, value: &str, state: Value) {
    emit_event("SendConfirm", nid_str, slot, view, Some(value), state);
}

pub fn emit_receive_confirm(nid_str: &str, slot: u64, view: u64, value: &str, state: Value) {
    emit_event("ReceiveConfirm", nid_str, slot, view, Some(value), state);
}

pub fn emit_send_commit_slow(nid_str: &str, slot: u64, view: u64, value: &str, state: Value) {
    emit_event("SendCommitSlow", nid_str, slot, view, Some(value), state);
}

pub fn emit_send_commit_fast(nid_str: &str, slot: u64, view: u64, value: &str, state: Value) {
    emit_event("SendCommitFast", nid_str, slot, view, Some(value), state);
}

pub fn emit_receive_commit(nid_str: &str, slot: u64, view: u64, value: &str, state: Value) {
    emit_event("ReceiveCommit", nid_str, slot, view, Some(value), state);
}

pub fn emit_send_timeout(nid_str: &str, slot: u64, view: u64, state: Value) {
    emit_event("SendTimeout", nid_str, slot, view, None, state);
}

pub fn emit_advance_view(nid_str: &str, slot: u64, old_view: u64, state: Value) {
    emit_event("AdvanceView", nid_str, slot, old_view, None, state);
}

pub fn emit_generate_prepare_from_tc(nid_str: &str, slot: u64, view: u64, value: &str, state: Value) {
    emit_event("GeneratePrepareFromTC", nid_str, slot, view, Some(value), state);
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

/// Get the hex-encoded string representation of a PublicKey.
/// Used as the `node` field in trace events so that NodeMap can resolve it.
pub fn pk_hex(pk: &PublicKey) -> String {
    pk.0.iter().map(|b| format!("{:02x}", b)).collect()
}

fn now_ns() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
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
