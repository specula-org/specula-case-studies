//! TLA+ trace emission helper for the Alpenglow migration harness.
//!
//! This module is unconditionally compiled into the instrumented crate.
//! Set `TLA_TRACE_FILE=<path>` before the process starts to enable writing.
//! When the env var is unset, every `emit_*` call is a cheap no-op.

#![allow(missing_docs)]

use std::fs::{File, OpenOptions};
use std::io::Write;
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

static WRITER: OnceLock<Option<Mutex<File>>> = OnceLock::new();

fn writer() -> Option<&'static Mutex<File>> {
    let opt = WRITER.get_or_init(|| {
        let path = match std::env::var("TLA_TRACE_FILE") {
            Ok(p) if !p.is_empty() => p,
            _ => return None,
        };
        let f = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .ok()?;
        Some(Mutex::new(f))
    });
    opt.as_ref()
}

fn now_nanos() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0)
}

/// Write one JSON trace line to the configured trace file (if enabled).
///
/// `inner_json` is the inner `event` object encoded as JSON, without the outer braces.
pub fn emit(inner_json: &str) {
    let Some(w) = writer() else {
        return;
    };
    let ts = now_nanos();
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"event":{{{inner_json}}}}}{nl}"#,
        ts = ts,
        inner_json = inner_json,
        nl = "\n"
    );
    if let Ok(mut g) = w.lock() {
        let _ = g.write_all(line.as_bytes());
        let _ = g.flush();
    }
}

/// Emit a `{"tag":"config", ...}` line. Used at scenario start to declare topology.
pub fn emit_config(inner_json: &str) {
    let Some(w) = writer() else {
        return;
    };
    let ts = now_nanos();
    let line = format!(
        r#"{{"tag":"config","ts":{ts},"config":{{{inner_json}}}}}{nl}"#,
        ts = ts,
        inner_json = inner_json,
        nl = "\n"
    );
    if let Ok(mut g) = w.lock() {
        let _ = g.write_all(line.as_bytes());
        let _ = g.flush();
    }
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

/// Builder for assembling the `event` JSON object incrementally.
pub struct EventBuilder {
    parts: Vec<String>,
}

impl EventBuilder {
    /// Start a new event with the required `name` and `nid` fields.
    pub fn new(name: &str, nid: &str) -> Self {
        Self {
            parts: vec![
                format!(r#""name":"{}""#, json_escape(name)),
                format!(r#""nid":"{}""#, json_escape(nid)),
            ],
        }
    }

    /// Append a string field, JSON-escaping the value.
    pub fn field_str(mut self, k: &str, v: &str) -> Self {
        self.parts
            .push(format!(r#""{}":"{}""#, k, json_escape(v)));
        self
    }

    /// Append an integer field.
    pub fn field_int(mut self, k: &str, v: i64) -> Self {
        self.parts.push(format!(r#""{}":{}"#, k, v));
        self
    }

    /// Append a boolean field.
    pub fn field_bool(mut self, k: &str, v: bool) -> Self {
        self.parts.push(format!(r#""{}":{}"#, k, v));
        self
    }

    /// Append a pre-rendered JSON value (e.g. an object literal).
    pub fn field_raw(mut self, k: &str, v: &str) -> Self {
        self.parts.push(format!(r#""{}":{}"#, k, v));
        self
    }

    /// Render the inner event body as JSON (no outer braces).
    pub fn build(self) -> String {
        self.parts.join(",")
    }

    /// Render and emit in one step.
    pub fn emit(self) {
        emit(&self.build());
    }
}

/// State snapshot of MigrationStatus, serialised into the `state` field of each event.
pub struct StateSnapshot {
    pub phase: &'static str,
    pub ff_activation_slot: Option<u64>,
    pub migration_slot: Option<u64>,
    pub genesis_block: Option<(u64, String)>,
    pub genesis_cert: Option<(u64, String)>,
    pub poh_service_started: bool,
    pub shutdown_poh: bool,
    pub panicked: bool,
}

impl StateSnapshot {
    /// Render this snapshot as a JSON object literal (with surrounding braces).
    ///
    /// Slot-or-NoSlot fields are emitted as INTEGERS — `NoSlot` maps to 999,
    /// which the Trace.cfg pins as the spec sentinel. Keeping the type uniform
    /// (always `Nat`) lets TLC compare slot fields without tripping its strict
    /// type guard.
    pub fn to_json(&self) -> String {
        let mut parts: Vec<String> = Vec::new();
        parts.push(format!(r#""phase":"{}""#, self.phase));
        let ff = self.ff_activation_slot.unwrap_or(999);
        parts.push(format!(r#""ff_activation_slot":{}"#, ff));
        let ms = self.migration_slot.unwrap_or(999);
        parts.push(format!(r#""migration_slot":{}"#, ms));
        // Always emit a record for genesis_block / genesis_cert; the spec
        // recognises slot=999 / block_id="NoBlock"|"NoCert" as the sentinel.
        match &self.genesis_block {
            Some((slot, bid)) => parts.push(format!(
                r#""genesis_block":{{"slot":{},"bid":"{}"}}"#,
                slot,
                json_escape(bid)
            )),
            None => parts.push(r#""genesis_block":{"slot":999,"bid":"NoBlock"}"#.to_string()),
        }
        match &self.genesis_cert {
            Some((slot, bid)) => parts.push(format!(
                r#""genesis_cert":{{"cert_type":"CertGenesis","slot":{},"block_id":"{}"}}"#,
                slot,
                json_escape(bid)
            )),
            None => parts.push(
                r#""genesis_cert":{"cert_type":"CertGenesis","slot":999,"block_id":"NoCert"}"#
                    .to_string(),
            ),
        }
        parts.push(format!(
            r#""poh_service_started":{}"#,
            self.poh_service_started
        ));
        parts.push(format!(r#""shutdown_poh":{}"#, self.shutdown_poh));
        parts.push(format!(r#""panicked":{}"#, self.panicked));
        format!("{{{}}}", parts.join(","))
    }
}
