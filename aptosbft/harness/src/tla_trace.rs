//! TLA+ Trace emission for Aptos BFT (2-chain HotStuff / Jolteon)
//!
//! Emits NDJSON trace events compatible with Trace.tla.
//! Activated by calling `init()` with a file path and server mapping.
//!
//! Usage:
//!   1. Call `tla_trace::init(path, server_map)` at test setup.
//!   2. At each instrumentation point, call `tla_trace::emit(...)`.
//!   3. Events are written as NDJSON lines to the trace file.

use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs::File;
use std::io::{BufWriter, Write};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

// ---------------------------------------------------------------------------
// Global state
// ---------------------------------------------------------------------------

static WRITER: OnceLock<Mutex<TraceWriter>> = OnceLock::new();

struct TraceWriter {
    file: BufWriter<File>,
    /// Maps hex-encoded PeerId → TLA+ server name (e.g., "s1")
    server_map: HashMap<String, String>,
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Initialize the trace writer. Call once before any `emit` calls.
///
/// * `path`       – output NDJSON file path
/// * `server_map` – maps hex(PeerId) → TLA+ server name ("s1", "s2", …)
pub fn init(path: &str, server_map: HashMap<String, String>) {
    let file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(path)
        .unwrap_or_else(|e| panic!("tla_trace: failed to open {}: {}", path, e));
    let _ = WRITER.set(Mutex::new(TraceWriter {
        file: BufWriter::new(file),
        server_map,
    }));
}

/// Returns `true` if tracing is active.
pub fn is_active() -> bool {
    WRITER.get().is_some()
}

/// Map a hex-encoded PeerId to its TLA+ server name.
/// Returns the hex string itself if no mapping is found.
pub fn nid(author_hex: &str) -> String {
    WRITER
        .get()
        .and_then(|w| {
            w.lock()
                .ok()
                .and_then(|g| g.server_map.get(author_hex).cloned())
        })
        .unwrap_or_else(|| author_hex.to_string())
}

/// Emit a trace event.
///
/// * `name`  – TLA+ action name (e.g., "CastVote")
/// * `nid`   – TLA+ server id (e.g., "s1")
/// * `round` – current or message round
/// * `epoch` – current epoch
/// * `state` – post-action state snapshot (JSON object)
/// * `msg`   – optional message fields (JSON object)
pub fn emit_event(
    name: &str,
    nid: &str,
    round: u64,
    epoch: u64,
    state: Value,
    msg: Option<Value>,
) {
    let mut event = json!({
        "name": name,
        "nid": nid,
        "epoch": epoch,
        "round": round,
        "state": state,
    });
    if let Some(m) = msg {
        event["msg"] = m;
    }
    let line = json!({
        "tag": "trace",
        "timestamp": now_ms(),
        "event": event,
    });
    write_line(&line);
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
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
