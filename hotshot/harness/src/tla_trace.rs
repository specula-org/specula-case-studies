// Copyright (c) 2024 Espresso Systems
// Trace harness for TLA+ validation — produced by Specula harness-generation.
//
// This module is added to `hotshot-task-impls` and provides a thread-safe NDJSON
// trace writer. Each emitted line has the envelope:
//
//   {"tag": "trace",
//    "ts": <epoch_ns>,
//    "event": {"name": "<ActionName>",
//              "nid":  "<server_id>",
//              "view": <Nat>,
//              "epoch": <Nat>,
//              "state": { ... },
//              "msg":   { ... }}}
//
// The writer is opened once on first `emit()` call, taking the path from the
// `TLA_TRACE_FILE` env var. If the env var is unset, traces are silently
// dropped (so production builds with the trace module compiled in still work).
//
// Node IDs are integers (`task_state.id: u64`) inside HotShot. We map them
// 0 -> s1, 1 -> s2, etc.

use std::fs::{File, OpenOptions};
use std::io::Write;
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

static WRITER: OnceLock<Mutex<Option<File>>> = OnceLock::new();

fn writer() -> &'static Mutex<Option<File>> {
    WRITER.get_or_init(|| {
        let file = std::env::var("TLA_TRACE_FILE")
            .ok()
            .and_then(|p| {
                if p.is_empty() {
                    None
                } else {
                    OpenOptions::new()
                        .create(true)
                        .append(true)
                        .open(&p)
                        .ok()
                }
            });
        Mutex::new(file)
    })
}

/// Returns true if trace emission is active (TLA_TRACE_FILE set & opened).
pub fn is_enabled() -> bool {
    writer().lock().map(|g| g.is_some()).unwrap_or(false)
}

/// Re-open the trace file at `path`, truncating any prior content. Used by
/// tests to ensure each scenario writes to its own file. Pass empty string
/// to disable tracing.
pub fn set_path(path: &str) {
    let mut guard = match writer().lock() {
        Ok(g) => g,
        Err(_) => return,
    };
    if path.is_empty() {
        *guard = None;
        return;
    }
    *guard = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(path)
        .ok();
}

/// Map a u64 HotShot node id to the TLA+ server name (s1, s2, ...).
pub fn nid(id: u64) -> String {
    format!("s{}", id + 1)
}

/// Current epoch-nanos timestamp.
pub fn now_ns() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0)
}

/// Build a leaf-commit string from a Commitment by Debug-printing.
/// HotShot's `Commitment<Leaf2<TYPES>>` implements `Display` as a tagged-base64
/// string, but we use `format!("{:?}", c)` so that callers can pass any
/// representable type (Display may not be impl'd on every wrapper).
pub fn fmt_leaf<T: std::fmt::Display>(c: T) -> String {
    format!("{}", c)
}

/// Emit a single trace event. Cheap no-op if `TLA_TRACE_FILE` is unset.
pub fn emit(
    name: &str,
    nid: &str,
    view: u64,
    epoch: u64,
    state: serde_json::Value,
    msg: serde_json::Value,
) {
    let mut guard = match writer().lock() {
        Ok(g) => g,
        Err(_) => return,
    };
    let Some(file) = guard.as_mut() else {
        return;
    };
    let line = serde_json::json!({
        "tag": "trace",
        "ts": format!("{}", now_ns()),
        "event": {
            "name": name,
            "nid": nid,
            "view": view,
            "epoch": epoch,
            "state": state,
            "msg": msg,
        }
    });
    let _ = writeln!(file, "{line}");
    let _ = file.flush();
}

/// Emit a config event (cluster topology). Should be called once before
/// trace events start. Currently a stub; Trace.cfg defines Server = {s1,s2,s3}.
#[allow(dead_code)]
pub fn emit_config(servers: &[&str]) {
    let mut guard = match writer().lock() {
        Ok(g) => g,
        Err(_) => return,
    };
    let Some(file) = guard.as_mut() else {
        return;
    };
    let line = serde_json::json!({
        "tag": "config",
        "ts": format!("{}", now_ns()),
        "config": { "servers": servers }
    });
    let _ = writeln!(file, "{line}");
    let _ = file.flush();
}

/// Build a state-snapshot JSON object from the 8 fields the spec expects.
/// Callers should populate from `consensus.read().await` and pass into `emit`.
#[allow(clippy::too_many_arguments)]
pub fn state_obj(
    cur_view: u64,
    cur_epoch: u64,
    locked_view: u64,
    latest_voted_view: u64,
    highest_block: u64,
    high_qc_in_mem_view: u64,
    high_qc_persisted_view: u64,
    crashed: bool,
) -> serde_json::Value {
    serde_json::json!({
        "curView": cur_view,
        "curEpoch": cur_epoch,
        "lockedView": locked_view,
        "latestVotedView": latest_voted_view,
        "highestBlock": highest_block,
        "highQcInMemView": high_qc_in_mem_view,
        "highQcPersistedView": high_qc_persisted_view,
        "crashed": crashed,
    })
}
