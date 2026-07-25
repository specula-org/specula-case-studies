//! TLA+ Trace emission for Autobahn BFT consensus.
//!
//! Emits NDJSON trace events compatible with Trace.tla.
//! Activated by setting the `TLA_TRACE_FILE` environment variable.
//!
//! Usage (automatic in instrumented core.rs):
//!   - On startup, `try_init()` checks `TLA_TRACE_FILE` env var
//!   - If set, initializes the trace writer with the given path
//!   - At each instrumentation point, `emit_*()` writes an NDJSON line
//!
//! Thread safety: Uses OnceLock<Mutex<TraceWriter>>. All emit calls
//! are serialized through the mutex.

use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs::File;
use std::io::{BufWriter, Write};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

use crypto::PublicKey;

// ---------------------------------------------------------------------------
// Global state
// ---------------------------------------------------------------------------

static WRITER: OnceLock<Mutex<TraceWriter>> = OnceLock::new();
static SERVER_MAP: OnceLock<Mutex<ServerMap>> = OnceLock::new();

struct TraceWriter {
    file: BufWriter<File>,
}

struct ServerMap {
    /// Maps PublicKey bytes → TLA+ server name ("s1", "s2", ...)
    map: HashMap<Vec<u8>, String>,
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
        eprintln!("[tla_trace] Tracing to: {}", path);
    }
}

/// Returns true if tracing is active.
pub fn is_active() -> bool {
    WRITER.get().is_some()
}

/// Map a PublicKey to its TLA+ server name ("s1", "s2", ...).
/// Assigns names in order of first encounter.
pub fn nid(pk: &PublicKey) -> String {
    if let Some(sm) = SERVER_MAP.get() {
        if let Ok(mut guard) = sm.lock() {
            let key = pk.0.to_vec();
            if let Some(name) = guard.map.get(&key) {
                return name.clone();
            }
            let name = format!("s{}", guard.next_id);
            guard.next_id += 1;
            guard.map.insert(key, name.clone());
            return name;
        }
    }
    format!("{:?}", pk)
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
// Emit functions (one per spec action)
// ---------------------------------------------------------------------------

/// Emit a consensus state snapshot for the given node and slot.
pub fn make_state(
    slot: u64,
    view: u64,
    voted_prepare: u64,
    voted_confirm: u64,
    committed: &str,
    high_qc_view: u64,
    high_qc_value: &str,
    high_prop_view: u64,
    high_prop_value: &str,
) -> Value {
    json!({
        "slot": slot,
        "view": view,
        "votedPrepare": voted_prepare,
        "votedConfirm": voted_confirm,
        "committed": committed,
        "highQCView": high_qc_view,
        "highQCValue": high_qc_value,
        "highPropView": high_prop_view,
        "highPropValue": high_prop_value,
    })
}

/// Emit a generic trace event.
pub fn emit(name: &str, nid_str: &str, state: Value, msg: Option<Value>) {
    let mut event = json!({
        "name": name,
        "nid": nid_str,
        "state": state,
    });
    if let Some(m) = msg {
        event["msg"] = m;
    }
    let line = json!({
        "tag": "trace",
        "ts": now_ns(),
        "event": event,
    });
    write_line(&line);
}

/// Emit SendPrepare event.
pub fn emit_send_prepare(
    nid_str: &str,
    slot: u64,
    view: u64,
    value: &str,
    state: Value,
) {
    emit(
        "SendPrepare",
        nid_str,
        state,
        Some(json!({
            "slot": slot,
            "view": view,
            "value": value,
            "author": nid_str,
        })),
    );
}

/// Emit ReceivePrepare event.
pub fn emit_receive_prepare(
    nid_str: &str,
    author_str: &str,
    slot: u64,
    view: u64,
    value: &str,
    state: Value,
) {
    emit(
        "ReceivePrepare",
        nid_str,
        state,
        Some(json!({
            "slot": slot,
            "view": view,
            "value": value,
            "author": author_str,
        })),
    );
}

/// Emit SendConfirm event.
pub fn emit_send_confirm(
    nid_str: &str,
    slot: u64,
    view: u64,
    value: &str,
    state: Value,
) {
    emit(
        "SendConfirm",
        nid_str,
        state,
        Some(json!({
            "slot": slot,
            "view": view,
            "value": value,
        })),
    );
}

/// Emit ReceiveConfirm event.
pub fn emit_receive_confirm(
    nid_str: &str,
    slot: u64,
    view: u64,
    value: &str,
    state: Value,
) {
    emit(
        "ReceiveConfirm",
        nid_str,
        state,
        Some(json!({
            "slot": slot,
            "view": view,
            "value": value,
        })),
    );
}

/// Emit SendCommit event (slow path, from ConfirmQC).
pub fn emit_send_commit(
    nid_str: &str,
    slot: u64,
    view: u64,
    value: &str,
    state: Value,
) {
    emit(
        "SendCommit",
        nid_str,
        state,
        Some(json!({
            "slot": slot,
            "view": view,
            "value": value,
        })),
    );
}

/// Emit SendFastCommit event (fast path, from PrepareQC with N votes).
pub fn emit_send_fast_commit(
    nid_str: &str,
    slot: u64,
    view: u64,
    value: &str,
    state: Value,
) {
    emit(
        "SendFastCommit",
        nid_str,
        state,
        Some(json!({
            "slot": slot,
            "view": view,
            "value": value,
        })),
    );
}

/// Emit ReceiveCommit event.
pub fn emit_receive_commit(
    nid_str: &str,
    slot: u64,
    view: u64,
    value: &str,
    state: Value,
) {
    emit(
        "ReceiveCommit",
        nid_str,
        state,
        Some(json!({
            "slot": slot,
            "view": view,
            "value": value,
        })),
    );
}

/// Emit SendTimeout event.
pub fn emit_send_timeout(nid_str: &str, state: Value) {
    emit("SendTimeout", nid_str, state, None);
}

/// Emit AdvanceView event.
pub fn emit_advance_view(nid_str: &str, slot: u64, prev_view: u64, state: Value) {
    let mut s = state;
    s["prevView"] = json!(prev_view);
    emit("AdvanceView", nid_str, s, None);
}

/// Emit GeneratePrepareFromTC event.
pub fn emit_generate_prepare_from_tc(
    nid_str: &str,
    slot: u64,
    view: u64,
    value: &str,
    state: Value,
) {
    emit(
        "GeneratePrepareFromTC",
        nid_str,
        state,
        Some(json!({
            "slot": slot,
            "view": view,
            "value": value,
        })),
    );
}

/// Emit EnterSlot event.
pub fn emit_enter_slot(nid_str: &str, slot: u64, state: Value) {
    emit("EnterSlot", nid_str, state, None);
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

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
